#!/usr/bin/env bash
# エッジのテナントのコンテナのログの読み方を比べる（aka-mvpset の概要 §18.9 の S4-4、radsec-edge の段階 4-1b）。
# 起動したばかりの dockerd（docker:dind。userland-proxy オフ、live-restore オン。決定事項 27）で、150 テナント（AP 5 台ずつ）を動かし、
# 次の 4 つを比べる。
#   json    json-file だけ（Fluent Bit なし。比べる基準）
#   fluentd fluentd のログドライバーで Fluent Bit に送る（dual logging のキャッシュで docker logs も読む）。値はデータ面のノードと同じ
#   fluentd2 同じ方式で、ドライバーの待ち行列（fluentd-buffer-limit）と Fluent Bit の forward の受信バッファーを絞る
#   tail    json-file のまま、Fluent Bit が /var/lib/docker/containers の JSON のログのファイルを tail で読む
#
# 使い方: run.sh <作業ディレクトリ>（<作業ディレクトリ>/image.tar.gz に radsecproxy のイメージを置く）。
# 結果は <作業ディレクトリ>/result-<モード>.jsonl と notes-<モード>.txt。ホストの Docker の設定は変えない。
set -uo pipefail
ulimit -n 8192
W=$1
HERE=$(cd "$(dirname "$0")" && pwd)
N=${N:-150}
K=5
UPSTREAM=172.31.91.1
DIND_IMAGE=docker:29.9.2-dind
RS_IMAGE=radsec-edge/radsecproxy:1.11.4-pc1
FB_IMAGE=fluent/fluent-bit:4.2.8
trap 'echo "== 失敗（行 $LINENO）"' ERR

echo "== イメージ"
docker load -q -i "$W/image.tar.gz" >/dev/null
docker pull -q "$DIND_IMAGE" >/dev/null
docker pull -q "$FB_IMAGE" >/dev/null
docker save "$RS_IMAGE" "$FB_IMAGE" -o "$W/images.tar"

echo "== PKI と設定"
[ -d "$W/tenants/t001" ] || bash "$HERE/gen.sh" "$W" "$N" "$K" 1 "$UPSTREAM"
mkdir -p "$W/fb"
for t in $(seq 1 "$N"); do
	s=t$(printf %03d "$t")
	for i in $(seq 1 $K); do echo "$((20000 + t)) $W/pki/$s/ap-$i.pem $W/pki/$s/ap-$i.key"; done
done >"$W/spec.txt"

cat >"$W/fb/forward.yaml" <<'EOF'
service:
  flush: 1
  daemon: false
  log_level: info
pipeline:
  inputs:
    - name: forward
      listen: 0.0.0.0
      port: 24224
      mem_buf_limit: 5MB
  outputs:
    - name: file
      match: "tenant.*"
      path: /out
      file: tenants.log
      format: plain
EOF
cat >"$W/fb/forward2.yaml" <<'EOF'
service:
  flush: 1
  daemon: false
  log_level: info
pipeline:
  inputs:
    - name: forward
      listen: 0.0.0.0
      port: 24224
      mem_buf_limit: 5MB
      buffer_chunk_size: 32K
      buffer_max_size: 512K
  outputs:
    - name: file
      match: "tenant.*"
      path: /out
      file: tenants.log
      format: plain
EOF
cat >"$W/fb/tail.yaml" <<'EOF'
service:
  flush: 1
  daemon: false
  log_level: info
pipeline:
  inputs:
    - name: tail
      path: /var/lib/docker/containers/*/*-json.log
      tag: tenant.tail
      read_from_head: true
      refresh_interval: 5
      mem_buf_limit: 5MB
      db: /out/tail.db
  outputs:
    - name: file
      match: "tenant.*"
      path: /out
      file: tenants.log
      format: plain
EOF

run_mode() {
	local MODE=$1
	local DIND=edgelog-$MODE VOL=edgelog-$MODE OUT=$W/result-$MODE.jsonl NOTES=$W/notes-$MODE.txt FBOUT=$W/out-$MODE
	D() { docker exec "$DIND" docker "$@"; }
	note() { echo "$*" | tee -a "$NOTES"; }
	: >"$OUT"
	: >"$NOTES"
	docker run --rm -v "$W:/w" busybox:1.37.0 rm -rf "/w/out-$MODE"
	mkdir -p "$FBOUT"
	chmod 777 "$FBOUT"
	echo "== モード $MODE"
	docker rm -f "$DIND" >/dev/null 2>&1 || true
	docker volume rm "$VOL" >/dev/null 2>&1 || true
	# dockerd を再起動できるよう、sh のループの中で動かす（live-restore の確かめ）。
	docker run -d --name "$DIND" --privileged --entrypoint sh -v "$VOL:/var/lib/docker" -v "$W:$W" "$DIND_IMAGE" \
		-c 'while :; do dind dockerd --host=unix:///var/run/docker.sock --userland-proxy=false --live-restore >>/var/log/dockerd.log 2>&1; sleep 1; done' >/dev/null
	for _ in $(seq 60); do D info >/dev/null 2>&1 && break; sleep 2; done
	note "dind=$(D info --format '{{.ServerVersion}} live_restore={{.LiveRestoreEnabled}} cgroup=v{{.CgroupVersion}}')"
	local DPID DIP CID
	DPID=$(docker inspect -f '{{.State.Pid}}' "$DIND")
	DIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DIND")
	CID=$(docker inspect -f '{{.Id}}' "$DIND")

	m() {
		sleep "${SETTLE:-20}"
		sudo python3 "$HERE/measure.py" "$DPID" "$MODE" "$1" "$2" "$3" | tee -a "$OUT"
	}
	cpu() { sudo awk '/^usage_usec/{print $2}' "/sys/fs/cgroup/system.slice/docker-$CID.scope/cpu.stat"; }
	logopts() {
		case $MODE in
		fluentd | fluentd2)
			local limit=1048576
			[ "$MODE" = fluentd2 ] && limit=8192
			printf '%s ' --log-driver fluentd --log-opt fluentd-address=localhost:24224 --log-opt fluentd-async=true \
				--log-opt "fluentd-buffer-limit=$limit" --log-opt "tag=tenant.$1" --log-opt cache-max-size=10m --log-opt cache-max-file=2
			;;
		*) printf '%s ' --log-opt max-size=10m --log-opt max-file=5 ;;
		esac
	}
	start_tenant() {
		# shellcheck disable=SC2046
		D run -d --name "radsecproxy-$1" --user 10083:10083 --init --read-only --cap-drop ALL \
			--security-opt no-new-privileges:true $(logopts "$1") \
			--network radsec-edge-tenants -p "$DIP:$2:2083" -v "$W/tenants/$1:/conf:ro" --restart unless-stopped \
			"$RS_IMAGE" radsecproxy -f -c /conf/current/radsecproxy.conf >/dev/null
	}
	start_fb() {
		case $MODE in
		fluentd | fluentd2)
			local conf=forward.yaml
			[ "$MODE" = fluentd2 ] && conf=forward2.yaml
			D run -d --name fluent-bit -p 127.0.0.1:24224:24224 -v "$W/fb/$conf:/fb.yaml:ro" -v "$FBOUT:/out" \
			"$FB_IMAGE" /fluent-bit/bin/fluent-bit -c /fb.yaml >/dev/null ;;
		tail) D run -d --name fluent-bit -v "$W/fb/tail.yaml:/fb.yaml:ro" -v "$FBOUT:/out" \
			-v /var/lib/docker/containers:/var/lib/docker/containers:ro \
			"$FB_IMAGE" /fluent-bit/bin/fluent-bit -c /fb.yaml >/dev/null ;;
		esac
	}
	docker_lines() {
		local total=0 t n
		for t in $(seq 1 "$N"); do
			n=$(D logs "radsecproxy-t$(printf %03d "$t")" 2>&1 | wc -l)
			total=$((total + n))
		done
		echo "$total"
	}
	fb_all() { if [ -f "$FBOUT/tenants.log" ]; then wc -l <"$FBOUT/tenants.log"; else echo 0; fi; }

	D load -q -i "$W/images.tar" >/dev/null
	D network create --subnet 172.31.91.0/24 --gateway "$UPSTREAM" radsec-edge-tenants >/dev/null
	m baseline 0 0
	if [ "$MODE" != json ]; then
		start_fb
		m fluent-bit-only 0 0
	fi

	local start_at t
	start_at=$(date +%s)
	for t in $(seq 1 "$N"); do start_tenant "t$(printf %03d "$t")" $((20000 + t)); done
	note "start_seconds=$(($(date +%s) - start_at)) running=$(D ps -q | wc -l)"
	m idle "$N" 0

	python3 "$HERE/clients.py" "$DIP" "$W/pki/sca.pem" "$W/spec.txt" >"$W/clients-$MODE.log" 2>&1 &
	local CPID=$!
	for _ in $(seq 300); do [ -s "$W/clients-$MODE.log" ] && break; sleep 1; done
	note "clients=$(cat "$W/clients-$MODE.log")"
	m conns "$N" $((N * K))

	# ログの行を出させる（毎秒 20 接続を 60 秒）。CPU は dind 全体の増分（TLS の分を含むので、モードの間の差を見る）。
	local c0 c1
	c0=$(cpu)
	note "burst=$(python3 "$HERE/cycle.py" "$DIP" "$W/pki/sca.pem" "$W/spec.txt" 20 60)"
	c1=$(cpu)
	note "burst_cpu_seconds=$(((c1 - c0) / 1000000))"
	c0=$(cpu)
	sleep 60
	c1=$(cpu)
	note "idle60s_cpu_seconds=$(((c1 - c0) / 1000000))"
	m after-burst "$N" $((N * K))

	# 行の数の突き合わせ（tail のモードでは Fluent Bit のログも同じ JSON のファイルに入るので、Fluent Bit の出力は目安になる）。
	sleep 15
	note "lines_docker_logs=$(docker_lines) lines_fluent_bit=$(fb_all)"
	note "disk_containers=$(D run --rm -v /var/lib/docker/containers:/c:ro busybox:1.37.0 du -sm /c 2>/dev/null | cut -f1)MiB"

	# docker logs の読み方（radsec-edge の LogsSince と同じ形）と、150 テナントを順に読む時間。
	local since t0 t1
	since=$(date -u -d '-5 min' +%Y-%m-%dT%H:%M:%SZ)
	D logs --timestamps --since "$since" radsecproxy-t001 2>&1 | head -4 | cut -c1-200 | sed 's/^/sample: /' | tee -a "$NOTES"
	note "sample_up_lines=$(D logs --timestamps --since "$since" radsecproxy-t001 2>&1 | grep -c 'TLS connection from .*client .* up')"
	t0=$(date +%s.%N)
	for t in $(seq 1 "$N"); do D logs --timestamps --since "$since" "radsecproxy-t$(printf %03d "$t")" >/dev/null 2>&1; done
	t1=$(date +%s.%N)
	note "read_all_seconds=$(echo "$t1 $t0" | awk '{printf "%.1f", $1-$2}')"

	if [ "$MODE" = fluentd ] || [ "$MODE" = fluentd2 ]; then
		# Fluent Bit が止まっている間: コンテナは動き続けるか、docker logs は読めるか、作り直せるか、戻った後に行が届くか。
		local before after
		before=$(fb_all)
		D stop fluent-bit >/dev/null
		note "fb_down_burst=$(python3 "$HERE/cycle.py" "$DIP" "$W/pki/sca.pem" "$W/spec.txt" 20 30)"
		note "fb_down_running=$(D ps -q --filter name=radsecproxy- | wc -l)"
		note "fb_down_up_lines_t001=$(D logs --timestamps --since 1m radsecproxy-t001 2>&1 | grep -c 'TLS connection from .*client .* up')"
		D rm -f radsecproxy-t002 >/dev/null
		if start_tenant t002 20002; then note "fb_down_recreate=ok"; else note "fb_down_recreate=failed"; fi
		D restart radsecproxy-t003 >/dev/null && note "fb_down_restart=ok" || note "fb_down_restart=failed"
		sleep 2
		note "fb_down_t002_state=$(D inspect -f '{{.State.Status}}' radsecproxy-t002)"
		SETTLE=5 m fb-down "$N" $((N * K))
		local e0
		e0=$(D logs radsecproxy-t004 2>&1 | wc -l)
		D start fluent-bit >/dev/null
		sleep 60
		after=$(fb_all)
		note "fb_lines_before_down=$before fb_lines_after_recover=$after docker_lines_now=$(docker_lines) t004_lines=$e0"
		m fb-recovered "$N" $((N * K))
	fi

	# dockerd の再起動（live-restore）: コンテナと AP の接続が続くか、その後のログが届くか。
	local started est0 est1 fb0 fb1
	started=$(D inspect -f '{{.State.StartedAt}}' radsecproxy-t010)
	est0=$(ss -tn state established "dst $DIP" 2>/dev/null | tail -n +2 | wc -l)
	docker exec "$DIND" pkill -TERM -x dockerd || true
	sleep 3
	for _ in $(seq 60); do D info >/dev/null 2>&1 && break; sleep 2; done
	sleep 5
	est1=$(ss -tn state established "dst $DIP" 2>/dev/null | tail -n +2 | wc -l)
	note "restart_started_same=$([ "$started" = "$(D inspect -f '{{.State.StartedAt}}' radsecproxy-t010)" ] && echo yes || echo no) established_before=$est0 established_after=$est1 running=$(D ps -q --filter name=radsecproxy- | wc -l)"
	fb0=$(fb_all)
	note "after_restart_burst=$(python3 "$HERE/cycle.py" "$DIP" "$W/pki/sca.pem" "$W/spec.txt" 20 20)"
	sleep 15
	fb1=$(fb_all)
	note "after_restart_fb_lines=$fb0->$fb1 up_lines_t011=$(D logs --timestamps --since 1m radsecproxy-t011 2>&1 | grep -c 'TLS connection from .*client .* up')"
	m after-restart "$N" $((N * K))

	kill "$CPID" 2>/dev/null || true
	wait "$CPID" 2>/dev/null || true
	docker logs --tail 5 "$DIND" >>"$NOTES" 2>&1 || true
	docker exec "$DIND" sh -c 'tail -n 3 /var/log/dockerd.log' | cut -c1-300 >>"$NOTES" 2>&1 || true
	docker rm -f "$DIND" >/dev/null
	docker volume rm "$VOL" >/dev/null
	trap 'echo "== 失敗（行 $LINENO）"' ERR
}

for mode in ${MODES:-json fluentd fluentd2 tail}; do run_mode "$mode"; done
echo "== 終わり"
