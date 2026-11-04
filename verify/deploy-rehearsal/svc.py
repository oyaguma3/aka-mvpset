#!/usr/bin/env python3
"""リハーサルの受け口と試し。
  svc.py serve <tcp|udp>:<ポート> ...   受けたものをそのまま返す
  svc.py try <tcp|udp> <アドレス> <ポート>  届いて返事があれば 0、なければ 1
"""
import socket, sys, threading

def serve_tcp(port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port)); s.listen(16)
    while True:
        c, _ = s.accept()
        try:
            d = c.recv(64); c.sendall(d or b"ok")
        finally:
            c.close()

def serve_udp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", port))
    while True:
        d, a = s.recvfrom(64); s.sendto(d, a)

def main():
    if sys.argv[1] == "serve":
        ts = []
        for spec in sys.argv[2:]:
            proto, port = spec.split(":")
            t = threading.Thread(target=serve_tcp if proto == "tcp" else serve_udp, args=(int(port),), daemon=True)
            t.start(); ts.append(t)
        for t in ts:
            t.join()
    proto, host, port = sys.argv[2], sys.argv[3], int(sys.argv[4])
    try:
        if proto == "tcp":
            s = socket.create_connection((host, port), timeout=3); s.sendall(b"x"); ok = s.recv(8) != b""
        else:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3); s.sendto(b"x", (host, port)); ok = s.recv(8) != b""
    except OSError:
        ok = False
    sys.exit(0 if ok else 1)

main()
