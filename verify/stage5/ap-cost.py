#!/usr/bin/env python3
"""AP の接続 1 本あたりのメモリーを測る（段階 5 の T5-25）。edge-02 のホストで root として動かす。
  ap-cost.py <出力の jsonl> <間隔（秒）> <回数>
間隔ごとに 1 行: 使用量（MemTotal−MemAvailable）、Slab、TCP のソケットの数と使っているページ、conntrack の数、
radsecproxy と containerd-shim の PSS（smaps_rollup の Pss・Pss_Anon の合計）、radsecproxy のスレッドの数、テナントのポートへの接続の数。
AP の役を止める前・止めた後・戻した後で比べて、接続 1 本あたりの量を求める。
  ap-cost.py report <jsonl> <止めた時刻（秒）> <戻した時刻（秒）>   手元でまとめる（止める前の 10 分、止めて 5 分後から戻すまで、戻して 20〜40 分の平均を比べる）
"""
import json
import os
import statistics
import sys
import time


def report(path, stop, start):
    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]

    def f(d):
        p = d["procs"]
        return {"使用量": d["used_kb"] / 1024, "radsecproxy": p["radsecproxy"]["pss_kb"] / 1024, "radsecproxy のスレッド": p["radsecproxy"]["threads"],
                "containerd-shim": p["containerd-shim"]["pss_kb"] / 1024, "Slab": d["slab_kb"] / 1024, "接続": d["tenant_conns"]}

    def mean(a, b):
        xs = [f(d) for d in rows if a <= d["t"] < b]
        return {k: statistics.mean(x[k] for x in xs) for k in xs[0]}, len(xs)

    a, na = mean(stop - 600, stop)
    b, nb = mean(stop + 300, start)
    c, nc = mean(start + 1200, start + 2400)
    print(f"平均（MiB。件数は止める前 {na}・止めた後 {nb}・戻した後 {nc}）")
    for k in a:
        print(f"  {k:22s} 止める前 {a[k]:8.1f}  止めた後 {b[k]:8.1f}  戻した後 {c[k]:8.1f}  止めて {b[k] - a[k]:+7.1f}  戻して {c[k] - b[k]:+7.1f}")
    for k in ("使用量", "radsecproxy", "Slab"):
        print(f"接続 1 本あたりの{k}: 止めたとき {(a[k] - b[k]) / (a['接続'] - b['接続']) * 1024:.0f} KiB、戻したとき {(c[k] - b[k]) / (c['接続'] - b['接続']) * 1024:.0f} KiB")
    print(f"止めた後の使用量の揺れ（標準偏差）: {statistics.pstdev([f(d)['使用量'] for d in rows if stop + 300 <= d['t'] < start]):.1f} MiB")


if sys.argv[1] == "report":
    report(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    sys.exit(0)

out, every, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])


def meminfo():
    m = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":")
        m[k] = int(v.split()[0])
    return m


def rollup(pid):
    d = {}
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            p = line.split()
            if p[0] in ("Pss:", "Pss_Anon:"):
                d[p[0][:-1]] = int(p[1])
    except OSError:
        pass
    return d


def procs():
    agg = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            comm = open(f"/proc/{pid}/comm").read().strip()
        except OSError:
            continue
        if comm not in ("radsecproxy", "containerd-shim"):
            continue
        r = rollup(pid)
        a = agg.setdefault(comm, {"n": 0, "pss_kb": 0, "pss_anon_kb": 0, "threads": 0})
        a["n"] += 1
        a["pss_kb"] += r.get("Pss", 0)
        a["pss_anon_kb"] += r.get("Pss_Anon", 0)
        try:
            a["threads"] += len(os.listdir(f"/proc/{pid}/task"))
        except OSError:
            pass
    return agg


def sockstat():
    d = {}
    for line in open("/proc/net/sockstat"):
        if line.startswith("TCP:"):
            p = line.split()[1:]
            d = {p[i]: int(p[i + 1]) for i in range(0, len(p), 2)}
    return d


def tenant_conns():
    # conntrack の表で、テナントのポート（20000〜21999）宛ての確立済みの接続を数える
    n = 0
    try:
        with open("/proc/net/nf_conntrack") as f:
            for line in f:
                if " ESTABLISHED " not in line:
                    continue
                for tok in line.split():
                    if tok.startswith("dport="):
                        if 20000 <= int(tok[6:]) <= 21999:
                            n += 1
                        break
    except OSError:
        n = -1
    return n


for i in range(count):
    t = int(time.time())
    m = meminfo()
    row = {
        "t": t,
        "used_kb": m["MemTotal"] - m["MemAvailable"],
        "slab_kb": m.get("Slab", 0),
        "sunreclaim_kb": m.get("SUnreclaim", 0),
        "tcp": sockstat(),
        "conntrack": int(open("/proc/sys/net/netfilter/nf_conntrack_count").read()),
        "tenant_conns": tenant_conns(),
        "procs": procs(),
    }
    with open(out, "a") as f:
        f.write(json.dumps(row) + "\n")
    if i < count - 1:
        time.sleep(max(1, every - (time.time() - t)))
