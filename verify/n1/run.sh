#!/usr/bin/env bash
# N1 の計測（aka-mvpset の要件と構成の概要 §20.1、決定事項 25 の根拠）。エッジの 1 テナントあたりのメモリーを、
# 起動したばかりの dockerd（docker:dind）で、userland-proxy のオフ（noproxy）とオン（proxy）で測る。
# テナントのコンテナは radsec-edge の agent のひな形（internal/agent の tenantSpec）と同じ引数で作る。
#
# 使い方: run.sh <作業ディレクトリ>（~/aka-work/n1）。結果は <作業ディレクトリ>/result-<モード>.jsonl。
# ホストの Docker の設定は変えない。ホストに残るのは n1/radsecproxy のイメージと docker:dind のイメージだけ（片付けは手で行う）。
set -euo pipefail
ulimit -n 4096
W=$1
HERE=$(cd "$(dirname "$0")" && pwd)
K=5   # テナントあたりの AP（client ブロックと接続）
H=200 # 重いテナントの AP
NMAX=160
UPSTREAM=172.31.90.1 # テナントのネットワークのゲートウェイ（上流の RADIUS の宛先。応答はなくてよい）
DIND_IMAGE=docker:29.8.2-dind

echo "== イメージ（ホストでビルドし、docker save で渡す。決定事項 24 と同じ形）"
docker build -q -t n1/radsecproxy "$W/image" >/dev/null
docker save n1/radsecproxy -o "$W/radsecproxy.tar"
docker pull -q "$DIND_IMAGE" >/dev/null

echo "== PKI と設定"
bash "$HERE/gen.sh" "$W" "$NMAX" "$K" "$H" "$UPSTREAM"

run_mode() {
	local MODE=$1 UPX=$2
	local DIND=n1-dind-$MODE VOL=n1-dind-$MODE OUT=$W/result-$MODE.jsonl
	D() { docker exec "$DIND" docker "$@"; }
	: >"$OUT"
	echo "== モード $MODE（userland-proxy=$UPX）"
	docker rm -f "$DIND" >/dev/null 2>&1 || true
	docker volume rm "$VOL" >/dev/null 2>&1 || true
	docker run -d --name "$DIND" --privileged -v "$VOL:/var/lib/docker" -v "$W:$W" "$DIND_IMAGE" --userland-proxy="$UPX" >/dev/null
	for _ in $(seq 60); do D info >/dev/null 2>&1 && break; sleep 2; done
	D info --format 'dind: {{.ServerVersion}} cgroup v{{.CgroupVersion}} driver={{.CgroupDriver}}'
	local DPID DIP
	DPID=$(docker inspect -f '{{.State.Pid}}' "$DIND")
	DIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DIND")

	m() {
		sleep 20
		sudo python3 "$HERE/measure.py" "$DPID" "$MODE" "$1" "$2" "$3" | tee -a "$OUT"
	}
	start_tenant() {
		D run -d --name "radsecproxy-$1" --user 10083:10083 --init --read-only --cap-drop ALL \
			--security-opt no-new-privileges:true --log-opt max-size=10m --log-opt max-file=5 \
			--network radsec-edge-tenants -p "$DIP:$2:2083" -v "$W/tenants/$1:/conf:ro" --restart unless-stopped \
			n1/radsecproxy radsecproxy -f -c /conf/current/radsecproxy.conf >/dev/null
	}
	CPID=
	clients() { # <名前> <一覧のファイル>
		python3 "$HERE/clients.py" "$DIP" "$W/pki/sca.pem" "$2" >"$W/clients-$MODE-$1.log" 2>&1 &
		CPID=$!
		for _ in $(seq 300); do [ -s "$W/clients-$MODE-$1.log" ] && break; sleep 1; done
		echo "clients $1: $(cat "$W/clients-$MODE-$1.log")"
	}
	stop_clients() { kill "$CPID" 2>/dev/null || true; wait "$CPID" 2>/dev/null || true; }

	m fresh 0 0
	D load -q -i "$W/radsecproxy.tar" >/dev/null
	D network create --subnet 172.31.90.0/24 --gateway "$UPSTREAM" radsec-edge-tenants >/dev/null
	m baseline 0 0

	local prev=0 n t s i
	for n in 10 20 40 80 160; do
		for t in $(seq $((prev + 1)) "$n"); do start_tenant "t$(printf %03d "$t")" $((20830 + t)); done
		prev=$n
		echo "running=$(D ps -q | wc -l) exited=$(D ps -q --filter status=exited | wc -l)"
		m idle "$n" 0
		for t in $(seq 1 "$n"); do
			s=t$(printf %03d "$t")
			for i in $(seq 1 $K); do echo "$((20830 + t)) $W/pki/$s/ap-$i.pem $W/pki/$s/ap-$i.key"; done
		done >"$W/spec-$n.txt"
		clients "$n" "$W/spec-$n.txt"
		m conns "$n" $((n * K))
		stop_clients
	done

	start_tenant heavy 20999
	m heavy-idle $((NMAX + 1)) 0
	for i in $(seq 1 $H); do echo "20999 $W/pki/heavy/ap-$i.pem $W/pki/heavy/ap-$i.key"; done >"$W/spec-heavy.txt"
	clients heavy "$W/spec-heavy.txt"
	m heavy-conns $((NMAX + 1)) $H
	stop_clients

	echo "radsecproxy のログ（t001 と heavy の末尾）:"
	D logs --tail 3 radsecproxy-t001 2>&1 || true
	D logs --tail 3 radsecproxy-heavy 2>&1 || true
	docker rm -f "$DIND" >/dev/null
	docker volume rm "$VOL" >/dev/null
}

run_mode noproxy false
run_mode proxy true
echo "== 終わり"
