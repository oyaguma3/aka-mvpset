#!/usr/bin/env python3
"""150 テナントの試験（確認事項 T5-9）の測定。エッジの VPS の上で root として 10 分ごとに動かし、1 行の JSON を足す。
  load-measure.py <記録のファイル（JSONL）>
ホストのメモリー（MemTotal − MemAvailable）、プロセスの種類ごとの PSS・RSS・FD・スレッド、Docker のコンテナの cgroup の合計、
docker.service・containerd.service の cgroup、CPU の時間、ディスク、テナントのコンテナの数と起動の時刻、AP の接続の数（各 radsecproxy の
ネットワークの名前空間の 2083 番の ESTABLISHED）、radsecproxy のログの大きさ。verify/edge-long/measure.py をもとにした（dind ではなくホスト）。
"""
import glob
import json
import os
import subprocess
import sys
import time

out = sys.argv[1]
# 前方一致で先に当たったものにする（containerd-shim を containerd より先に）
KINDS = ("dockerd", "containerd-shim", "containerd", "radsecproxy", "radsec-edge", "fluent-bit", "node_exporter")


def kv(path):
    d = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                k, v = line.split()[:2]
                d[k] = int(v)
    except (FileNotFoundError, ValueError):
        pass
    return d


def num(path):
    try:
        return int(open(path, encoding="utf-8").read().split()[0])
    except (FileNotFoundError, ValueError, IndexError):
        return 0


def mib(b):
    return round(b / 2**20, 1)


def cg(path):
    st = kv(path + "/memory.stat")
    return {"current_mib": mib(num(path + "/memory.current")), "anon_mib": mib(st.get("anon", 0)), "file_mib": mib(st.get("file", 0)),
            "kernel_mib": mib(st.get("kernel", 0)), "sock_mib": mib(st.get("sock", 0)), "cpu_usec": kv(path + "/cpu.stat").get("usage_usec", 0)}


doc = {"t": int(time.time())}
mi = {}
with open("/proc/meminfo", encoding="utf-8") as f:
    for line in f:
        k, v = line.split(":")
        mi[k] = int(v.split()[0])
doc["mem_total_mib"] = mi["MemTotal"] // 1024
doc["mem_avail_mib"] = mi["MemAvailable"] // 1024
doc["mem_used_mib"] = (mi["MemTotal"] - mi["MemAvailable"]) // 1024
doc["load1"] = float(open("/proc/loadavg").read().split()[0])
cpu = open("/proc/stat").readline().split()[1:]
doc["cpu_jiffies"] = {"total": sum(int(x) for x in cpu), "idle": int(cpu[3]) + int(cpu[4])}

procs, conns = {}, 0
for p in os.listdir("/proc"):
    if not p.isdigit():
        continue
    try:
        comm = open(f"/proc/{p}/comm", encoding="utf-8").read().strip()
        kind = next((k for k in KINDS if comm.startswith(k)), None)
        if kind is None:
            continue
        rss = pss = 0
        with open(f"/proc/{p}/smaps_rollup", encoding="utf-8") as f:
            for line in f:
                if line.startswith("Rss:"):
                    rss = int(line.split()[1])
                elif line.startswith("Pss:"):
                    pss = int(line.split()[1])
        fds = len(os.listdir(f"/proc/{p}/fd"))
        threads = int(next(l for l in open(f"/proc/{p}/status", encoding="utf-8") if l.startswith("Threads:")).split()[1])
        if kind == "radsecproxy":
            for fam in ("tcp", "tcp6"):
                with open(f"/proc/{p}/net/{fam}", encoding="utf-8") as f:
                    next(f)
                    conns += sum(1 for l in f if l.split()[3] == "01" and l.split()[1].endswith(":0823"))
    except (FileNotFoundError, ProcessLookupError, PermissionError, StopIteration):
        continue
    e = procs.setdefault(kind, {"n": 0, "rss_kb": 0, "pss_kb": 0, "fds": 0, "threads": 0})
    e["n"] += 1
    e["rss_kb"] += rss
    e["pss_kb"] += pss
    e["fds"] += fds
    e["threads"] += threads
doc["procs"] = dict(sorted(procs.items()))
doc["ap_conns"] = conns

base = "/sys/fs/cgroup/system.slice"
doc["cg_docker_service"] = cg(base + "/docker.service")
doc["cg_containerd_service"] = cg(base + "/containerd.service")
scopes = [cg(s) for s in glob.glob(base + "/docker-*.scope")]
doc["cg_containers"] = {"n": len(scopes), **{k: round(sum(s[k] for s in scopes), 1) for k in ("current_mib", "anon_mib", "file_mib", "kernel_mib", "sock_mib", "cpu_usec")}}


def du(path):
    r = subprocess.run(["du", "-sm", path], capture_output=True, text=True)
    return int(r.stdout.split()[0]) if r.returncode == 0 and r.stdout else -1


doc["disk_mib"] = {p.rsplit("/", 1)[-1] or p: du(p) for p in ("/var/lib/docker/containers", "/var/lib/radsec-edge/logs", "/var/lib/radsec-edge/data", "/var/lib/radsec-edge/tenants")}
st = os.statvfs("/")
doc["disk_root_used_gib"] = round((st.f_blocks - st.f_bfree) * st.f_frsize / 2**30, 2)
try:
    doc["log_bytes"] = os.path.getsize("/var/lib/radsec-edge/logs/radsecproxy.log")
except FileNotFoundError:
    doc["log_bytes"] = -1
r = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}"], capture_output=True, text=True)
names = [l.split("\t") for l in r.stdout.splitlines() if l]
ids = [n for n, _ in names]
doc["containers"] = {"all": len(names), "running": sum(1 for _, s in names if s == "running"), "tenants_running": sum(1 for n, s in names if n.startswith("radsecproxy-") and s == "running")}
if ids:
    r = subprocess.run(["docker", "inspect", "-f", "{{.Name}} {{.RestartCount}} {{.State.StartedAt}}"] + ids, capture_output=True, text=True)
    doc["started"] = {l.split()[0].lstrip("/"): [int(l.split()[1]), l.split()[2]] for l in r.stdout.splitlines() if l}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(doc, ensure_ascii=False) + "\n")
