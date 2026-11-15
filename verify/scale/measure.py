#!/usr/bin/env python3
"""規模の試験のデータ面の測定（確認事項 L6-6）。データ面のノードで root として 10 秒ごとに動かし、1 行 1 回の JSON を足す。
  python3 measure.py <出力の jsonl>          … 止めるまで 10 秒ごと（drive.sh の measure-start が一時の service で動かす）

取るもの: aka-vecgen と aka-radius の Valkey の INFO（persistence・stats・memory の要るもの）と LATENCY LATEST、
各コンテナの cgroup の CPU の累計（マイクロ秒）とメモリー、ノードの MemAvailable。`appendfsync always` の効き方は
aof_delayed_fsync・aof_last_write_status・LATENCY（aof-fsync-always など）と、vecgen の Valkey の CPU で見る。
"""
import json
import os
import subprocess
import sys
import time

VALKEYS = {  # 名前: (コンテナ, .env, パスワードの変数)
    "vecgen": ("aka-vecgen-valkey-1", "/opt/aka-vecgen/.env", "VALKEY_PASSWORD"),
    "radius": ("aka-radius-valkey-1", "/opt/aka-radius/deployments/.env", "VALKEY_PASSWORD"),
}
INFO_KEYS = ("used_memory", "used_memory_rss", "aof_enabled", "aof_rewrite_in_progress", "aof_last_write_status", "aof_delayed_fsync", "aof_current_size",
             "instantaneous_ops_per_sec", "total_commands_processed", "keyspace_hits", "keyspace_misses", "connected_clients", "rdb_bgsave_in_progress")


def env(path, key):
    try:
        for l in open(path, encoding="utf-8"):
            if l.startswith(key + "="):
                return l.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


def cli(container, pw, *args):
    r = subprocess.run(["docker", "exec", container, "valkey-cli", "-a", pw, "--no-auth-warning", *args], capture_output=True, text=True, timeout=10)
    return r.stdout


def info(container, pw):
    out = {}
    for sec in ("persistence", "stats", "memory", "clients", "keyspace"):
        for l in cli(container, pw, "INFO", sec).splitlines():
            if ":" in l and not l.startswith("#"):
                k, v = l.split(":", 1)
                if k in INFO_KEYS or k.startswith("db"):
                    out[k] = v.strip()
    lat = cli(container, pw, "LATENCY", "LATEST").split()
    out["latency_latest"] = lat[:40]
    return out


def cgroups():
    out = {}
    r = subprocess.run(["docker", "ps", "--format", "{{.ID}} {{.Names}}", "--no-trunc"], capture_output=True, text=True, timeout=10)
    for l in r.stdout.splitlines():
        cid, name = l.split(" ", 1)
        base = f"/sys/fs/cgroup/system.slice/docker-{cid}.scope"
        try:
            cpu = dict(x.split() for x in open(base + "/cpu.stat"))
            out[name] = {"cpu_usec": int(cpu["usage_usec"]), "mem": int(open(base + "/memory.current").read())}
        except OSError:
            continue
    return out


def meminfo():
    m = {}
    for l in open("/proc/meminfo"):
        k, v = l.split(":")
        m[k] = int(v.split()[0]) * 1024
    return {"total": m["MemTotal"], "available": m["MemAvailable"]}


def main(path):
    pws = {k: env(e, var) for k, (c, e, var) in VALKEYS.items()}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    while True:
        t0 = time.time()
        rec = {"t": round(t0, 1), "mem": meminfo(), "load": os.getloadavg(), "cgroups": cgroups()}
        for k, (c, _, _) in VALKEYS.items():
            try:
                rec["valkey_" + k] = info(c, pws[k])
            except Exception as e:  # noqa: BLE001
                rec["valkey_" + k] = {"error": str(e)[:200]}
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        time.sleep(max(0, 10 - (time.time() - t0)))


if __name__ == "__main__":
    main(sys.argv[1])
