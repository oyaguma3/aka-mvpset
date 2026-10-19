"""dind のコンテナの cgroup の合計と、プロセスの種類ごとのメモリーを JSON で 1 行出す（root で動かす）。

使い方: sudo python3 measure.py <dind のコンテナの PID> <モード> <段の名前> <テナント数> <接続数>
"""

import json
import os
import sys

pid, mode, label, tenants, conns = sys.argv[1:6]


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


scope = cgroup_of(pid)
# dind の entrypoint は自分を子の cgroup に移すことがあるので、docker-<id>.scope の階層まで上がる。
parts = scope.split("/")
for i, part in enumerate(parts):
    if part.startswith("docker-") and part.endswith(".scope"):
        scope = "/".join(parts[: i + 1])
        break
base = "/sys/fs/cgroup" + scope
stat = kv(base + "/memory.stat")
current = int(open(base + "/memory.current", encoding="utf-8").read())

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
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        continue
    e = procs.setdefault(comm, {"n": 0, "rss_kb": 0, "pss_kb": 0})
    e["n"] += 1
    e["rss_kb"] += rss
    e["pss_kb"] += pss

mi = {}
with open("/proc/meminfo", encoding="utf-8") as f:
    for line in f:
        k, v = line.split(":")
        mi[k] = int(v.split()[0])

print(
    json.dumps(
        {
            "mode": mode,
            "label": label,
            "tenants": int(tenants),
            "conns": int(conns),
            "cg_current_mib": round(current / 2**20, 1),
            "cg_anon_mib": round(stat["anon"] / 2**20, 1),
            "cg_file_mib": round(stat["file"] / 2**20, 1),
            "cg_kernel_mib": round(stat.get("kernel", 0) / 2**20, 1),
            "cg_sock_mib": round(stat.get("sock", 0) / 2**20, 1),
            "host_avail_mib": mi["MemAvailable"] // 1024,
            "procs": dict(sorted(procs.items())),
        },
        ensure_ascii=False,
    ),
    flush=True,
)
