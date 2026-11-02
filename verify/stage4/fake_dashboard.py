#!/usr/bin/env python3
# 偽の Dashboard API（段階 4 の通し）。Meraki の API の形だけをまねて、組織の RadSec の CRL の一覧を返す。実物の API の確かめではない（確認事項 S9-6）。
# /fake/crl.pem をその場で読むので、ファイルを置き換えると次の取得から新しい CRL を返す。キーはログに出さない。
import http.server
import json
import os
import re
import ssl

KEY = os.environ["FAKE_API_KEY"]
PATH = re.compile(r"^/api/v1/organizations/([0-9]+)/wireless/devices/radsec/certificates/authorities/crls$")


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not PATH.match(self.path):
            return self.reply(404, {"errors": ["not found"]})
        if self.headers.get("Authorization") != "Bearer " + KEY:
            return self.reply(401, {"errors": ["Invalid API key"]})
        crl = open("/fake/crl.pem", encoding="ascii").read()
        self.reply(200, {"items": [{"crl": crl}], "meta": {"counts": {"items": {"total": 1, "remaining": 0}}}})

    def reply(self, status, doc):
        b = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, fmt, *args):
        print("%s %s" % (self.requestline, args[1] if len(args) > 1 else ""), flush=True)


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/fake/server.pem", "/fake/server.key")
s = http.server.ThreadingHTTPServer(("0.0.0.0", 8443), H)
s.socket = ctx.wrap_socket(s.socket, server_side=True)
s.serve_forever()
