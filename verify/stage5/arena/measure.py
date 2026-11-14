#!/usr/bin/env python3
"""radsecproxy のメモリーの測定（確認事項 T5-20 の実験）。--pid=host --privileged --cgroupns=host のコンテナの中で動かす。
  measure.py <作業ディレクトリ> <間隔の秒>
<作業>/ids.txt（コンテナの ID 名前 変種）にある radsecproxy ごとに、PSS・RSS、ヒープ、名前のない領域の PSS とその数、
64 MiB 級の予約（glibc の malloc の arena）の数、スレッド、2083 番の ESTABLISHED の数を、間隔ごとに samples.jsonl に 1 行足す。
"""
import json
import os
import sys
import time

work, every = sys.argv[1], int(sys.argv[2])
out = f"{work}/samples.jsonl"
owner = os.stat(work)


def measure(pid):
    d = {"pss_kb": 0, "rss_kb": 0, "heap_kb": 0, "anon_kb": 0, "anon_n": 0, "arenas": 0}
    cur = None
    with open(f"/proc/{pid}/smaps", encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if "-" in p[0] and len(p) >= 5 and ":" not in p[0]:
                a, b = p[0].split("-")
                cur = p[5] if len(p) > 5 else ""
                if cur == "":
                    d["anon_n"] += 1
                    # glibc の malloc のスレッドごとの arena は 64 MiB の予約（HEAP_MAX_SIZE）
                    d["arenas"] += (int(b, 16) - int(a, 16)) >= 60 * 1024 * 1024
            elif p[0] == "Pss:":
                v = int(p[1])
                d["pss_kb"] += v
                if cur == "[heap]":
                    d["heap_kb"] += v
                elif cur == "":
                    d["anon_kb"] += v
            elif p[0] == "Rss:":
                d["rss_kb"] += int(p[1])
    d["threads"] = int(next(l for l in open(f"/proc/{pid}/status") if l.startswith("Threads:")).split()[1])
    conns = 0
    for fam in ("tcp", "tcp6"):
        with open(f"/proc/{pid}/net/{fam}") as f:
            next(f)
            conns += sum(1 for l in f if l.split()[3] == "01" and l.split()[1].endswith(":0823"))
    d["conns"] = conns
    return d


while True:
    ids = {}
    for l in open(f"{work}/ids.txt", encoding="utf-8"):
        cid, name, variant = l.split()
        ids[cid] = (name, variant)
    doc = {"t": int(time.time()), "procs": {}}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if open(f"/proc/{p}/comm").read().strip() != "radsecproxy":
                continue
            cg = open(f"/proc/{p}/cgroup").read().strip().split("/")[-1]
            cid = cg.removeprefix("docker-").removesuffix(".scope")
            if cid not in ids:
                continue
            name, variant = ids[cid]
            doc["procs"][name] = {"variant": variant, "pid": int(p), **measure(p)}
        except (FileNotFoundError, ProcessLookupError, StopIteration):
            continue
    with open(out, "a", encoding="utf-8") as f:
        f.write(json.dumps(doc, ensure_ascii=False) + "\n")
    os.chown(out, owner.st_uid, owner.st_gid)
    time.sleep(every)
