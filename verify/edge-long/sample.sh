#!/usr/bin/env bash
# 長い時間の試験の記録（作業ディレクトリ <間隔の秒>）。間隔ごとに samples.jsonl に 1 行足す。
W=$1
EVERY=${2:-600}
HERE=$(cd "$(dirname "$0")" && pwd)
DIND=edge-long
while :; do
	pid=$(docker inspect -f '{{.State.Pid}}' "$DIND")
	m=$(docker run --rm --privileged --pid=host --cgroupns=host -v "$HERE:/m:ro" python:3.13.9-slim python -I /m/measure.py "$pid" 2>&1)
	disk=$(docker exec "$DIND" sh -c 'du -sm /var/lib/docker/containers /var/lib/radsec-edge/logs /var/lib/radsec-edge/data /var/lib/radsec-edge/tenants 2> /dev/null' | awk '{printf "%s%s", (NR>1?",":""), $1}')
	running=$(docker exec "$DIND" docker ps -q --filter label=radsec-edge.tenant | wc -l)
	lines=$(docker exec "$DIND" sh -c 'wc -l < /var/lib/radsec-edge/logs/radsecproxy.log' 2> /dev/null)
	up=$(docker exec "$DIND" sh -c "grep -c 'TLS connection from' /var/lib/radsec-edge/logs/radsecproxy.log" 2> /dev/null)
	python3 -I - "$W" "$m" "$disk" "$running" "${lines:-0}" "${up:-0}" >> "$W/samples.jsonl" << 'PY'
import json, os, sys, time
w, m, disk, running, lines, up = sys.argv[1:]
def load(n):
    try:
        return json.load(open(f"{w}/{n}"))
    except Exception:
        return {}
try:
    doc = json.loads(m)
except Exception:
    doc = {"measure_error": m[:200]}
d = (disk.split(",") + ["0"] * 4)[:4]
doc.update(t=int(time.time()), disk_containers_mib=int(d[0]), disk_logs_mib=int(d[1]), disk_data_mib=int(d[2]), disk_tenants_mib=int(d[3]),
           running=int(running), log_lines=int(lines or 0), log_up_lines=int(up or 0), ap=load("ap-status.json"), run=load("run-status.json"), upstream=load("upstream-status.json"))
print(json.dumps(doc, ensure_ascii=False), flush=True)
PY
	sleep "$EVERY"
done
