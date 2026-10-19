"""AP の役: 指定のテナントのポートへ、AP の証明書で TLS の接続を張ったまま待つ（N1 の計測用）。

使い方: python3 clients.py <エッジの IP> <サーバーCA> <一覧のファイル（行: ポート 証明書 鍵）>
接続の結果を JSON で 1 行出し、その後は終了させられるまで接続を保つ。
"""

import json
import socket
import ssl
import sys
import time

host, sca, spec = sys.argv[1:4]
socks = []
ng = 0
for line in open(spec, encoding="utf-8"):
    port, cert, key = line.split()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.load_verify_locations(sca)
    ctx.load_cert_chain(cert, key)
    try:
        s = socket.create_connection((host, int(port)), timeout=5)
        socks.append(ctx.wrap_socket(s))
    except Exception:
        ng += 1

# TLS 1.3 では、クライアント証明書の拒否はハンドシェイクの後の読み出しで分かるので、少し待ってから確かめる。
time.sleep(3)
alive = 0
for t in socks:
    t.settimeout(0.05)
    try:
        if t.recv(1):
            alive += 1
    except (TimeoutError, ssl.SSLWantReadError):
        alive += 1
    except Exception:
        pass
print(json.dumps({"connected": len(socks), "failed": ng, "alive": alive}), flush=True)
while True:
    time.sleep(3600)
