"""ラボ用の RADIUS の道具（標準ライブラリだけ）。

  radtool.py send --kind auth|acct --port P --secret S --user U [--nas N] [--spoof] [--other-vsa]
      AP の役の radsecproxy（UDP）へ Access-Request か Accounting-Request を 1 つ送る（応答は待たない）。
      --spoof: 偽の刻印（Vendor-Id 32473、Vendor-Type 1、値 "999"）を付ける。
      --other-vsa: 別の業者の VSA（Vendor-Id 9、Vendor-Type 1）を付ける（取り除かれないことを確かめる）。
  radtool.py dump --out FILE
      上流の役。127.0.0.1:11812（認証）と 11813（Accounting）で受け、届いたパケットの属性を JSON で 1 行ずつ書く。
"""

import argparse
import hashlib
import hmac
import json
import os
import select
import socket
import struct


def attr(t, v):
    return struct.pack("!BB", t, len(v) + 2) + v


def vsa(vendor, vtype, value):
    sub = struct.pack("!BB", vtype, len(value) + 2) + value
    return attr(26, struct.pack("!I", vendor) + sub)


def build(kind, secret, user, nas, spoof, other):
    secret = secret.encode()
    attrs = attr(1, user.encode())
    if nas is not None:
        attrs += attr(32, nas.encode())
    if spoof:
        attrs += vsa(32473, 1, b"999")
    if other:
        attrs += vsa(9, 1, b"cisco-avpair=keep")
    ident = os.urandom(1)[0]
    if kind == "auth":
        auth = os.urandom(16)
        attrs_ma = attrs + attr(80, b"\x00" * 16)
        length = 20 + len(attrs_ma)
        pkt = struct.pack("!BBH", 1, ident, length) + auth + attrs_ma
        ma = hmac.new(secret, pkt, hashlib.md5).digest()
        return pkt[:-16] + ma
    attrs += attr(40, struct.pack("!I", 1)) + attr(44, user.encode())
    length = 20 + len(attrs)
    head = struct.pack("!BBH", 4, ident, length)
    auth = hashlib.md5(head + b"\x00" * 16 + attrs + secret).digest()
    return head + auth + attrs


def parse(pkt):
    code = pkt[0]
    out = {"code": code, "user": None, "nas": None, "stamp": [], "vsa": []}
    i = 20
    while i + 2 <= len(pkt):
        t, ln = pkt[i], pkt[i + 1]
        if ln < 2:
            break
        v = pkt[i + 2 : i + ln]
        if t == 1:
            out["user"] = v.decode(errors="replace")
        elif t == 32:
            out["nas"] = v.decode(errors="replace")
        elif t == 26 and len(v) >= 6:
            vendor = struct.unpack("!I", v[:4])[0]
            vt, vl = v[4], v[5]
            val = v[6 : 4 + vl].decode(errors="replace")
            if vendor == 32473:
                out["stamp"].append({"type": vt, "value": val})
            else:
                out["vsa"].append({"vendor": vendor, "type": vt, "value": val})
        i += ln
    return out


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send")
    s.add_argument("--kind", choices=["auth", "acct"], default="auth")
    s.add_argument("--port", type=int, default=1812)
    s.add_argument("--secret", required=True)
    s.add_argument("--user", required=True)
    s.add_argument("--nas")
    s.add_argument("--spoof", action="store_true")
    s.add_argument("--other-vsa", action="store_true")
    d = sub.add_parser("dump")
    d.add_argument("--out", required=True)
    a = ap.parse_args()

    if a.cmd == "send":
        pkt = build(a.kind, a.secret, a.user, a.nas, a.spoof, a.other_vsa)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as so:
            so.sendto(pkt, ("127.0.0.1", a.port))
        return

    socks = []
    for port in (11812, 11813):
        so = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        so.bind(("127.0.0.1", port))
        socks.append(so)
    with open(a.out, "a", encoding="utf-8") as f:
        while True:
            r, _, _ = select.select(socks, [], [])
            for so in r:
                pkt, _ = so.recvfrom(4096)
                f.write(json.dumps(parse(pkt), ensure_ascii=False) + "\n")
                f.flush()


if __name__ == "__main__":
    main()
