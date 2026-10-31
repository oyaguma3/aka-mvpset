"""AP の役: テナントのポートへ AP の証明書で接続しては閉じることを繰り返し、radsecproxy のログの行を出させる（ログの計測用）。

使い方: python3 cycle.py <エッジの IP> <サーバーCA> <一覧のファイル（行: ポート 証明書 鍵）> <毎秒の接続数> <秒>
結果を JSON で 1 行出す。
"""

import json
import socket
import ssl
import sys
import time

host, sca, spec, rate, seconds = sys.argv[1:6]
rate, seconds = float(rate), float(seconds)
targets = []
for line in open(spec, encoding="utf-8"):
    port, cert, key = line.split()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.load_verify_locations(sca)
    ctx.load_cert_chain(cert, key)
    targets.append((int(port), ctx))

ok = ng = 0
start = time.monotonic()
i = 0
while (now := time.monotonic()) - start < seconds:
    port, ctx = targets[i % len(targets)]
    i += 1
    try:
        s = socket.create_connection((host, port), timeout=3)
        t = ctx.wrap_socket(s)
        t.settimeout(0.02)
        try:
            t.recv(1)
        except (TimeoutError, ssl.SSLWantReadError):
            pass
        t.close()
        ok += 1
    except Exception:
        ng += 1
    wait = start + i / rate - time.monotonic()
    if wait > 0:
        time.sleep(wait)
print(json.dumps({"ok": ok, "failed": ng, "seconds": round(time.monotonic() - start, 1)}), flush=True)
