#!/usr/bin/env python3
"""150 テナントの試験（確認事項 T5-7・T5-8）の AP の役。検証機の 1 台目（手元の回線の内側）で動かす。
  load-ap.py <作業ディレクトリ> <エッジの公開のアドレス> <接続のし直し/秒> <RADIUS/秒> [何本だけ]
<作業>/aps.txt の 1 行 1 AP（<ポート> <証明書> <鍵> <テナントのサーバー CA> <slug> <AP の名前>）の RadSec の接続を保ち、切れたら張り直す。
毎秒 1 本の接続を閉じて張り直し、RADIUS の認証（EAP-Response/Identity。登録のない IMSI なので aka-radius は Access-Reject を返す）を流す。
Accounting は送らない。30 秒ごとに ap-status.json、10 分ごとに ap-status.jsonl に状態を書く。
verify/edge-long/ap.py をもとにした（dind ではなくインターネット越しに VPS のエッジへつなぐ）。
"""
import asyncio
import hashlib
import hmac
import json
import os
import random
import resource
import ssl
import struct
import sys
import time

work, host, churn, rps = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
only = int(sys.argv[5]) if len(sys.argv) > 5 else 0
SECRET = b"radsec"
REALM = "wlan.mnc010.mcc440.3gppnetwork.org"
CODES = {2: "accept", 3: "reject", 11: "challenge"}
stats = {"connects": 0, "connect_failed": 0, "lost": 0, "closed_by_churn": 0, "sent": 0, "received": 0,
         "accept": 0, "reject": 0, "challenge": 0, "other": 0}
conns = {}
t0 = time.time()


def attr(t, v):
    return bytes([t, len(v) + 2]) + v


def access_request(rid, slug, ap):
    # 登録のない IMSI（4401099992xxxxx）。両側にない IMSI なので、aka-radius は鍵を取りに行く前に断る
    ident = f"0440109999{200000 + random.randrange(100000):06d}@{REALM}".encode()
    eap = struct.pack("!BBHB", 2, rid, 5 + len(ident), 1) + ident
    attrs = (attr(1, ident) + attr(32, f"load-{slug}-{ap}".encode()) + attr(31, b"02-00-00-00-00-01")
             + attr(79, eap) + bytes([80, 18]) + b"\0" * 16)
    auth = os.urandom(16)
    head = struct.pack("!BBH", 1, rid, 20 + len(attrs))
    mac = hmac.new(SECRET, head + auth + attrs, hashlib.md5).digest()
    return head + auth + attrs[:-16] + mac


async def keep(i, port, cert, key, ca, slug, ap):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False  # IP でつなぐ（T5-7。DNS なし）。証明書はテナントのサーバー CA で確かめる
    ctx.load_verify_locations(ca)
    ctx.load_cert_chain(cert, key)
    await asyncio.sleep(i * 0.05)  # 最初の接続をずらす（740 本を約 37 秒で）
    while True:
        try:
            r, w = await asyncio.wait_for(asyncio.open_connection(host, port, ssl=ctx), 10)
        except Exception:
            stats["connect_failed"] += 1
            await asyncio.sleep(5 + random.random() * 5)
            continue
        stats["connects"] += 1
        conns[i] = (w, slug, ap)
        try:
            while True:
                head = await r.readexactly(4)
                await r.readexactly(struct.unpack("!H", head[2:4])[0] - 4)
                stats["received"] += 1
                stats[CODES.get(head[0], "other")] += 1
        except Exception:
            pass
        if conns.pop(i, None) is not None:
            stats["lost"] += 1
        try:
            w.close()
        except Exception:
            pass
        await asyncio.sleep(1 + random.random() * 3)


async def churner():
    while True:
        await asyncio.sleep(1 / churn)
        if conns:
            i = random.choice(list(conns))
            w, _, _ = conns.pop(i)
            stats["closed_by_churn"] += 1
            w.close()


async def radius():
    rid = 0
    while True:
        await asyncio.sleep(1 / rps)
        if conns:
            w, slug, ap = conns[random.choice(list(conns))]
            rid = (rid + 1) % 256
            w.write(access_request(rid, slug, ap))
            stats["sent"] += 1


async def report():
    n = 0
    while True:
        await asyncio.sleep(30)
        doc = {"t": int(time.time()), "connected": len(conns), **stats}
        tmp = f"{work}/ap-status.json.tmp"
        json.dump(doc, open(tmp, "w"))
        os.replace(tmp, f"{work}/ap-status.json")
        n += 1
        if n % 20 == 0:
            with open(f"{work}/ap-status.jsonl", "a") as f:
                f.write(json.dumps(doc) + "\n")


async def main():
    lines = [l.split() for l in open(f"{work}/aps.txt") if l.strip()]
    if only:
        lines = lines[:only]
    tasks = [asyncio.create_task(keep(i, int(p), c, k, ca, s, a)) for i, (p, c, k, ca, s, a) in enumerate(lines)]
    tasks += [asyncio.create_task(f()) for f in (churner, radius, report)]
    await asyncio.gather(*tasks)


resource.setrlimit(resource.RLIMIT_NOFILE, (4096, resource.getrlimit(resource.RLIMIT_NOFILE)[1]))
asyncio.run(main())
