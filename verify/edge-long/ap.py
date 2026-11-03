#!/usr/bin/env python3
"""長い時間の試験の AP の役（作業ディレクトリ <エッジのアドレス> <接続のし直し/秒> <RADIUS/秒>）。
aps.txt の全 AP の RadSec の接続を保ち、切れたら張り直す。毎秒 1 本の接続を閉じて張り直し、RADIUS を流す。
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
SECRET = b"radsec"
stats = {"connects": 0, "connect_failed": 0, "lost": 0, "closed_by_churn": 0, "sent": 0, "received": 0}
conns = {}


def attr(t, v):
    return bytes([t, len(v) + 2]) + v


def access_request(rid, slug):
    attrs = attr(1, f"0{slug}@long.test".encode()) + attr(32, b"ap-long") + bytes([80, 18]) + b"\0" * 16
    auth = os.urandom(16)
    head = struct.pack("!BBH", 1, rid, 20 + len(attrs))
    mac = hmac.new(SECRET, head + auth + attrs, hashlib.md5).digest()
    return head + auth + attrs[:-16] + mac


def accounting(rid, slug):
    attrs = attr(40, struct.pack("!I", 3)) + attr(44, os.urandom(8).hex().encode()) + attr(1, f"0{slug}@long.test".encode())
    head = struct.pack("!BBH", 4, rid, 20 + len(attrs))
    auth = hashlib.md5(head + b"\0" * 16 + attrs + SECRET).digest()
    return head + auth + attrs


async def keep(i, port, cert, key, slug):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.load_verify_locations(f"{work}/pki/shared/sca.pem")
    ctx.load_cert_chain(cert, key)
    rid = 0
    while True:
        try:
            r, w = await asyncio.wait_for(asyncio.open_connection(host, port, ssl=ctx), 10)
        except Exception:
            stats["connect_failed"] += 1
            await asyncio.sleep(5 + random.random() * 5)
            continue
        stats["connects"] += 1
        conns[i] = (w, slug)
        try:
            while True:
                head = await r.readexactly(4)
                await r.readexactly(struct.unpack("!H", head[2:4])[0] - 4)
                stats["received"] += 1
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
            w, _ = conns.pop(i)
            stats["closed_by_churn"] += 1
            w.close()


async def radius():
    rid = 0
    while True:
        await asyncio.sleep(1 / rps)
        if conns:
            w, slug = conns[random.choice(list(conns))]
            rid = (rid + 1) % 256
            w.write(access_request(rid, slug) if rid % 2 else accounting(rid, slug))
            stats["sent"] += 1


async def report():
    while True:
        await asyncio.sleep(30)
        tmp = f"{work}/ap-status.json.tmp"
        json.dump({"t": int(time.time()), "connected": len(conns), **stats}, open(tmp, "w"))
        os.replace(tmp, f"{work}/ap-status.json")


async def main():
    lines = [l.split() for l in open(f"{work}/aps.txt")]
    tasks = [asyncio.create_task(keep(i, int(p), c, k, s)) for i, (p, c, k, s) in enumerate(lines)]
    tasks += [asyncio.create_task(f()) for f in (churner, radius, report)]
    await asyncio.gather(*tasks)


resource.setrlimit(resource.RLIMIT_NOFILE, (4096, resource.getrlimit(resource.RLIMIT_NOFILE)[1]))
asyncio.run(main())
