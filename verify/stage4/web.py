#!/usr/bin/env python3
# 画面の要求（ui/http.js）の組み立てと、応答の保存。
#   web.py build <METHOD> <パス> [名前=値 | 名前=@ファイル]...  → 要求の JSON の base64 を出す
#   web.py save <作業ディレクトリ>  → 標準入力の応答を last.html・last.txt に書き、状態の番号を出す
import base64
import html
import json
import re
import sys


def build(argv):
    m, p, *kv = argv
    f = {}
    for a in kv:
        k, v = a.split("=", 1)
        if v.startswith("@"):
            v = open(v[1:], encoding="utf-8").read()
        f[k] = v
    print(base64.b64encode(json.dumps([{"m": m, "p": p, "f": f}]).encode()).decode())


def save(work):
    raw = sys.stdin.read()
    try:
        r = json.loads(raw)[0]
    except Exception:
        open(work + "/last.html", "w", encoding="utf-8").write(raw)
        open(work + "/last.txt", "w", encoding="utf-8").write(raw)
        print("000")
        return
    open(work + "/last.html", "w", encoding="utf-8").write(r["b"])
    t = re.sub(r"(?s)<(script|style).*?</\1>", " ", r["b"])
    t = re.sub(r"<[^>]+>", " ", t)
    t = re.sub(r"[ \t\r\f]+", " ", html.unescape(t))
    t = re.sub(r"\n\s*\n+", "\n", t)
    open(work + "/last.txt", "w", encoding="utf-8").write(t)
    print(r["s"])


if __name__ == "__main__":
    if sys.argv[1] == "build":
        build(sys.argv[2:])
    else:
        save(sys.argv[2])
