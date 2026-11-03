#!/usr/bin/env python3
"""dind の cgroup の合計と、プロセスの種類ごとのメモリーと FD の数を JSON で 1 行出す（verify/edge-logs の measure.py に FD と CPU を足した）。
--privileged --pid=host --cgroupns=host のコンテナの中で動かす。  使い方: measure.py <dind のコンテナの PID>
"""
import json
import os
import sys

pid = sys.argv[1]


def cgroup_of(p):
    with open(f"/proc/{p}/cgroup", encoding="utf-8") as f:
        for line in f:
            if line.startswith("0::"):
                return line.strip()[3:]
    return ""


def kv(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            k, v = line.split()[:2]
            out[k] = int(v)
    return out


parts = cgroup_of(pid).split("/")
scope = "/".join(parts)
for i, part in enumerate(parts):
    if part.startswith("docker-") and part.endswith(".scope"):
        scope = "/".join(parts[: i + 1])
        break
base = "/sys/fs/cgroup" + scope
stat = kv(base + "/memory.stat")
current = int(open(base + "/memory.current", encoding="utf-8").read())
cpu = kv(base + "/cpu.stat")

procs = {}
for p in os.listdir("/proc"):
    if not p.isdigit():
        continue
    try:
        if not cgroup_of(p).startswith(scope):
            continue
        comm = open(f"/proc/{p}/comm", encoding="utf-8").read().strip()
        rss = pss = 0
        with open(f"/proc/{p}/smaps_rollup", encoding="utf-8") as f:
            for line in f:
                if line.startswith("Rss:"):
                    rss = int(line.split()[1])
                elif line.startswith("Pss:"):
                    pss = int(line.split()[1])
        fds = len(os.listdir(f"/proc/{p}/fd"))
        threads = int(next(l for l in open(f"/proc/{p}/status", encoding="utf-8") if l.startswith("Threads:")).split()[1])
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        continue
    e = procs.setdefault(comm, {"n": 0, "rss_kb": 0, "pss_kb": 0, "fds": 0, "threads": 0})
    e["n"] += 1
    e["rss_kb"] += rss
    e["pss_kb"] += pss
    e["fds"] += fds
    e["threads"] += threads

mi = {}
with open("/proc/meminfo", encoding="utf-8") as f:
    for line in f:
        k, v = line.split(":")
        mi[k] = int(v.split()[0])
print(json.dumps({
    "cg_current_mib": round(current / 2**20, 1), "cg_anon_mib": round(stat["anon"] / 2**20, 1), "cg_file_mib": round(stat["file"] / 2**20, 1),
    "cg_kernel_mib": round(stat.get("kernel", 0) / 2**20, 1), "cg_sock_mib": round(stat.get("sock", 0) / 2**20, 1),
    "cpu_usec": cpu["usage_usec"], "host_avail_mib": mi["MemAvailable"] // 1024, "procs": dict(sorted(procs.items())),
}, ensure_ascii=False), flush=True)
