#!/usr/bin/env python3
"""長い時間の試験の上流の代わりと CRL の配布の口（作業ディレクトリ <シークレット> <待ち受けるアドレス>）。
RADIUS は Status-Server と Access-Request に応答し（認証の中身は見ず Access-Reject）、Accounting-Request に Accounting-Response を返す。
応答しないと radsecproxy が 1 分に 4 行ほどログを出し、実際のログの量と変わる（verify/edge-logs）。
CRL は radsec-ca と同じ /crl/<CA の ID>.pem を ETag つきで出す。
"""
import hashlib
import hmac
import http.server
import json
import os
import socket
import struct
import sys
import threading
import time

work, secret, addr = sys.argv[1], sys.argv[2].encode(), sys.argv[3]
stats = {"status": 0, "access": 0, "acct": 0, "crl_200": 0, "crl_304": 0, "crl_404": 0, "bad": 0}


def reply(req, code, port):
    rid, rauth = req[1], req[4:20]
    attrs = bytes([80, 18]) + b"\0" * 16
    length = 20 + len(attrs)
    head = struct.pack("!BBH", code, rid, length)
    mac = hmac.new(secret, head + rauth + attrs, hashlib.md5).digest()
    attrs = bytes([80, 18]) + mac
    auth = hashlib.md5(head + rauth + attrs + secret).digest()
    return head + auth + attrs


def serve(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((addr, port))
    while True:
        data, peer = s.recvfrom(4096)
        if len(data) < 20:
            stats["bad"] += 1
            continue
        code = data[0]
        if code == 12:
            stats["status"] += 1
            out = 5 if port == 1813 else 2
        elif code == 1:
            stats["access"] += 1
            out = 3
        elif code == 4:
            stats["acct"] += 1
            out = 5
        else:
            stats["bad"] += 1
            continue
        s.sendto(reply(data, out, port), peer)


class CRL(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = os.path.basename(self.path)
        path = f"{work}/crl/crl/{name}"
        if not self.path.startswith("/crl/") or not os.path.exists(path):
            stats["crl_404"] += 1
            self.send_error(404)
            return
        body = open(path, "rb").read()
        etag = '"' + hashlib.sha256(body).hexdigest()[:32] + '"'
        if self.headers.get("If-None-Match") == etag:
            stats["crl_304"] += 1
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return
        stats["crl_200"] += 1
        self.send_response(200)
        self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


for p in (1812, 1813):
    threading.Thread(target=serve, args=(p,), daemon=True).start()
threading.Thread(target=http.server.ThreadingHTTPServer((addr, 8449), CRL).serve_forever, daemon=True).start()
while True:
    time.sleep(30)
    tmp = f"{work}/upstream-status.json.tmp"
    json.dump({"t": int(time.time()), **stats}, open(tmp, "w"))
    os.replace(tmp, f"{work}/upstream-status.json")
