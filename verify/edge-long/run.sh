#!/usr/bin/env bash
# 長い時間の試験の検証機の側（simwifi2 の作業場所で動かす。nohup で裏に置く）。
#   run.sh start <テナント数> [記録の間隔の秒]   dind とエッジの導入、PKI、最初の反映、自走する道具の起動
#   run.sh restart                              dockerd の再起動の確かめ（live-restore）
#   run.sh stop                                 自走する道具を止める
#   run.sh teardown                             片付け
# ホストの Docker の設定は変えない。dind の dockerd に userland-proxy オフと live-restore オンを渡す（決定事項 27）。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$HERE/.." && pwd)
DIND=edge-long
DIND_IMAGE=docker:29.9.2-dind
GW=172.31.95.1
EDGE=172.31.95.2
D() { docker exec -i "$DIND" "$@"; }
say() { echo "== $(date '+%F %T') $*"; }
pidfile() { echo "$W/$1.pid"; }
bg() { # <名前> <コマンド...>: 自走の道具を起動する
	local n=$1
	shift
	nohup "$@" > "$W/$n.log" 2>&1 < /dev/null &
	echo $! > "$(pidfile "$n")"
}

start() {
	local n=$1 every=${2:-600}
	say "dind"
	docker network inspect elong > /dev/null 2>&1 || docker network create --subnet 172.31.95.0/24 elong > /dev/null
	docker rm -fv "$DIND" > /dev/null 2>&1
	docker run -d --privileged --name "$DIND" --hostname "$DIND" --network elong --ip "$EDGE" -e DOCKER_TLS_CERTDIR= --entrypoint sh "$DIND_IMAGE" \
		-c 'while :; do dind dockerd --host=unix:///var/run/docker.sock --userland-proxy=false --live-restore >>/var/log/dockerd.log 2>&1; sleep 1; done' > /dev/null
	for _ in $(seq 60); do D docker info > /dev/null 2>&1 && break; sleep 1; done
	D docker load -q < "$W/edge-images.tar"
	D mkdir -p /edge
	tar -C "$W/edge" -cf - . | D tar -xf - -C /edge

	say "PKI（$n テナント）"
	stop
	rm -rf "${W:?}/run"
	mkdir -p "$W/run"
	python3 -I "$HERE/long.py" gen "$W/run" "$n" || exit 1
	local pin secret gid
	pin=$(openssl x509 -in "$W/run/pki/shared/client.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')
	secret=$(openssl rand -hex 24)
	gid=$(D stat -c %g /var/run/docker.sock)

	say "上流と CRL の配布の口"
	bg upstream python3 -I "$HERE/upstream.py" "$W/run" "$secret" "$GW"

	say "エッジの導入（radsec-edge の運用ガイド 10 章）"
	D sh -s << SH || exit 1
set -e
cd /edge
cp .env.example .env
chmod 600 .env
sed -i -e 's|^EDGE_DOCKER_GID=.*|EDGE_DOCKER_GID=$gid|' -e 's|^EDGE_URN_PREFIX=.*|EDGE_URN_PREFIX=example|' -e 's|^EDGE_DNS_DOMAIN=.*|EDGE_DNS_DOMAIN=radsec.test|' \
  -e 's|^EDGE_UPSTREAM_SECRET=.*|EDGE_UPSTREAM_SECRET=$secret|' -e 's|^EDGE_CRL_BASE_URL=.*|EDGE_CRL_BASE_URL=http://$GW:8449|' \
  -e 's|^EDGE_ACCESS_TEAM_DOMAIN=.*|EDGE_ACCESS_TEAM_DOMAIN=edge-long.cloudflareaccess.com|' -e 's|^EDGE_ACCESS_AUD=.*|EDGE_ACCESS_AUD=edge-long|' .env
cat >> .env << ENV
COMPOSE_PROJECT_NAME=radsec-edge
COMPOSE_FILE=compose.yaml:compose.managed.yaml:compose.fluent-bit.yaml
EDGE_VERSION=long
EDGE_BIND_ADDR=0.0.0.0
EDGE_TLS_HOSTS=$EDGE
EDGE_FLUENT_BIT_PORT=24224
ENV
install -d -o 10084 -g 10083 -m 0750 /var/lib/radsec-edge/data /var/lib/radsec-edge/tenants /var/lib/radsec-edge/audit
install -d -m 0755 /var/lib/radsec-edge/logs
mkdir -p secrets
: > secrets/tunnel-token
chmod 644 secrets/tunnel-token
echo 'provisioner=$pin' > secrets/admin-clients
chown 10084 secrets/admin-clients
chmod 400 secrets/admin-clients
docker compose up -d --no-build --wait --wait-timeout 120 radsec-edge radsec-edge-agent fluent-bit
SH
	say "宣言・証明書・最初の反映"
	python3 -I "$HERE/long.py" setup "$W/run" "$n" > "$W/setup.log" 2>&1 || { say "最初の反映に失敗しました"; tail -3 "$W/setup.log"; exit 1; }
	tail -1 "$W/setup.log"
	say "自走する道具"
	bg ap python3 -I "$HERE/ap.py" "$W/run" "$EDGE" 1 10
	bg drive python3 -I "$HERE/long.py" run "$W/run" "$n"
	bg sample bash "$HERE/sample.sh" "$W/run" "$every"
	say "始めました"
	date +%s > "$W/run/started-at"
}

restart() {
	local out=$W/run/restart.txt names t0 s0 s1 n
	: > "$out"
	note() { echo "$*" | tee -a "$out"; }
	note "== dockerd の再起動（live-restore）$(date '+%F %T')"
	names=$(D docker ps --filter label=radsec-edge.tenant --format '{{.Names}}' | sort)
	# 反映の途中で起動の時刻が変わるものを除くため、中央の代わりを止めてから比べる
	kill "$(cat "$(pidfile drive)")" 2> /dev/null
	sleep 200
	s0=$(for x in $names; do echo "$x $(D docker inspect -f '{{.State.StartedAt}}' "$x")"; done)
	note "tenants_before=$(echo "$names" | wc -l) connected_before=$(python3 -I -c "import json; print(json.load(open('$W/run/ap-status.json'))['connected'])") dockerd_rss_kb_before=$(D sh -c 'grep VmRSS /proc/$(pidof dockerd)/status' | awk '{print $2}')"
	lines0=$(D sh -c 'wc -l < /var/lib/radsec-edge/logs/radsecproxy.log')
	lost0=$(python3 -I -c "import json; print(json.load(open('$W/run/ap-status.json'))['lost'])")
	t0=$(date +%s)
	D pkill -TERM -x dockerd
	sleep 3
	for _ in $(seq 120); do D docker info > /dev/null 2>&1 && break; sleep 1; done
	note "dockerd_back_seconds=$(($(date +%s) - t0)) dockerd_rss_kb_after=$(D sh -c 'grep VmRSS /proc/$(pidof dockerd)/status' | awk '{print $2}')"
	# agent が Docker に届くまで待つ（docker.sock を作り直したときは、agent が 60 秒で終了して作り直される。radsec-edge の運用ガイド 10.1）
	local ok=no i
	for i in $(seq 1 60); do
		if python3 -I - "$HERE" "$W/run" << 'PY'
import sys
sys.path.insert(0, sys.argv[1])
import long
s, d = long.API(sys.argv[2]).call("GET", "/status")
sys.exit(0 if s == 200 and d.get("agent", {}).get("dockerOk") else 1)
PY
		then
			ok=yes
			break
		fi
		sleep 5
	done
	note "agent_docker_ok=$ok after_seconds=$(($(date +%s) - t0)) agent_restart_count=$(D docker inspect -f '{{.RestartCount}}' radsec-edge-radsec-edge-agent-1) agent_exit_log=$(D sh -c 'cd /edge && docker compose logs --no-color --since 10m radsec-edge-agent' | grep -c 'has been unreachable')"
	sleep 60
	s1=$(for x in $names; do echo "$x $(D docker inspect -f '{{.State.StartedAt}}' "$x")"; done)
	if [ "$s0" = "$s1" ]; then note "started_same=yes"; else note "started_same=no"; diff <(echo "$s0") <(echo "$s1") | head -20 | tee -a "$out"; fi
	note "running_after=$(D docker ps -q --filter label=radsec-edge.tenant | wc -l)"
	note "connected_after=$(python3 -I -c "import json; print(json.load(open('$W/run/ap-status.json'))['connected'])") lost_delta=$(($(python3 -I -c "import json; print(json.load(open('$W/run/ap-status.json'))['lost'])") - lost0))（接続のし直しの分は closed_by_churn に数え、ここには入らない）"
	note "fluent_bit_lines_delta=$(($(D sh -c 'wc -l < /var/lib/radsec-edge/logs/radsecproxy.log') - lines0))"
	# agent がつなぎ直し、API と反映が動く
	bg drive python3 -I "$HERE/long.py" run "$W/run" "$(python3 -I -c "print(len(set(l.split()[3] for l in open('$W/run/aps.txt'))))")"
	sleep 150
	note "after_restart_applied=$(tail -5 "$W/run/events.jsonl" | grep -c '"result": "ok"') run_status=$(cat "$W/run/run-status.json")"
	note "agent_ok=$(D sh -c 'cd /edge && docker compose ps --format "{{.Service}} {{.Status}}"' | tr '\n' ';')"
	note "== 終わり"
}

stop() {
	local p
	for p in sample drive ap upstream; do
		[ -f "$(pidfile "$p")" ] && kill "$(cat "$(pidfile "$p")")" 2> /dev/null
	done
}

teardown() {
	stop
	docker rm -fv "$DIND" > /dev/null 2>&1
	docker network rm elong > /dev/null 2>&1
	docker image prune -af > /dev/null
	docker builder prune -af > /dev/null
	cd ~ && rm -rf "${W:?}"
	docker ps -aq | wc -l
	docker images -q | wc -l
	docker volume ls -q | wc -l
}

cmd=${1:?}
shift
case $cmd in
start) start "$@" ;;
restart) restart ;;
stop) stop ;;
teardown) teardown ;;
*) exit 2 ;;
esac
