#!/usr/bin/env bash
# 配置のリハーサル（確認事項 D16）。検証機の 2 台目で、Debian 13 のコンテナを VPS の代わりにして deploy/ を通す。
#   rehearsal.sh all | up | boot | apply | test | close | pull | monitor | teardown
# 置き場所: <W>/repo に aka-mvpset の deploy/ と verify/deploy-rehearsal/、作業は <W>/work（WORK で変えられる）。
# ホストの設定は変えない。WireGuard はコンテナの中の wireguard-go、nftables はコンテナの名前空間の中だけ。
# 結果は <作業>/results.tsv（番号、内容、PASS/FAIL）。
set -uo pipefail

H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
W=${WORK:-$(cd "$H/../../.." && pwd)/work}
mkdir -p "$W"
RES=$W/results.tsv
NODES="mon data mgmt edge-01 edge-02"
declare -A IP=([data]=172.30.0.10 [mgmt]=172.30.0.11 [mon]=172.30.0.12 [edge-01]=172.30.0.21 [edge-02]=172.30.0.22 [ap]=172.30.0.30 [pc]=172.30.0.100)
declare -A K=([data]=1 [mgmt]=2 [mon]=3 [edge-01]=4 [edge-02]=5)
# Docker が公開するポートの代わり（ノードの中で DNAT し、別のネットワークの受け口のコンテナへ送る）
declare -A PUBL=([data]="udp:1812 udp:1813 tcp:9443 tcp:9444" [mgmt]="tcp:8449" [edge-01]="tcp:9447 tcp:20000" [edge-02]="tcp:9447 tcp:20000" [mon]="tcp:3000 tcp:9090 tcp:9093")
SSHCFG=$W/ssh_config

check() { # <番号> <内容> <0 なら PASS>
	local r=FAIL
	[ "$3" = 0 ] && r=PASS
	printf '%s\t%s\t%s\n' "$1" "$2" "$r" | tee -a "$RES"
}
expect_ok() { "${@:3}" > /dev/null 2>&1; check "$1" "$2" $?; }
expect_ng() { if "${@:3}" > /dev/null 2>&1; then check "$1" "$2" 1; else check "$1" "$2" 0; fi; }
ex() { docker exec "rh-$1" "${@:2}"; }
try() { ex "$1" python3 /usr/local/bin/svc.py try "$2" "$3" "$4"; } # <元> <tcp|udp> <宛先> <ポート>
rssh() { ssh -F "$SSHCFG" -o ConnectTimeout=8 "$@"; }

up() {
	echo "== イメージ"
	docker build -q -f "$H/Dockerfile.node" -t rh-node:dev "$H" > /dev/null || exit 1
	docker build -q -t aka-ops-pc:dev "$R/deploy/ops-pc" > /dev/null || exit 1
	echo "== ネットワークとコンテナ"
	docker network create --subnet 172.30.0.0/24 rh-inet > /dev/null
	local n k
	for n in $NODES; do
		k=${K[$n]}
		docker network create --subnet "172.31.$k.0/24" "rh-int-$n" > /dev/null
		docker run -d --name "rh-$n" --hostname "aka-$n" --network rh-inet --ip "${IP[$n]}" \
			--cap-add NET_ADMIN --device /dev/net/tun --sysctl net.ipv4.ip_forward=1 rh-node:dev > /dev/null
		docker network connect --ip "172.31.$k.2" "rh-int-$n" "rh-$n"
		# shellcheck disable=SC2086
		docker run -d --name "rh-$n-svc" --network "rh-int-$n" --ip "172.31.$k.3" --entrypoint python3 rh-node:dev \
			/usr/local/bin/svc.py serve ${PUBL[$n]} > /dev/null
		dnat "$n"
	done
	docker run -d --name rh-ap --network rh-inet --ip "${IP[ap]}" rh-node:dev > /dev/null
	mkdir -p "$W/ops-pc/state" "$W/ops-pc/data"
	docker run -d --name ops-pc --network rh-inet --ip "${IP[pc]}" --cap-add NET_ADMIN --device /dev/net/tun \
		-v "$W/ops-pc/state:/state" -v "$W/ops-pc/data:/data" aka-ops-pc:dev > /dev/null
	docker ps --format '{{.Names}} {{.Status}}' | grep -E 'rh-|ops-pc'
}

dnat() { # Docker の公開の代わりの DNAT（リハーサルだけ）。Docker と同じく prerouting で DNAT し、forward を通す
	local n=$1 side="172.31.${K[$1]}.3" tcp="" udp="" s
	for s in ${PUBL[$n]}; do
		case $s in tcp:*) tcp="$tcp${tcp:+, }${s#tcp:}" ;; udp:*) udp="$udp${udp:+, }${s#udp:}" ;; esac
	done
	{
		echo "table ip rhnat {"
		echo "  chain pre {"
		echo "    type nat hook prerouting priority dstnat;"
		[ -n "$tcp" ] && echo "    fib daddr type local tcp dport { $tcp } dnat to $side"
		[ -n "$udp" ] && echo "    fib daddr type local udp dport { $udp } dnat to $side"
		echo "  }"
		echo "  chain post {"
		echo "    type nat hook postrouting priority srcnat;"
		echo "    ip daddr $side masquerade"
		echo "  }"
		echo "}"
	} | docker exec -i "rh-$n" nft -f -
}

boot() {
	echo "== 鍵と inventory"
	mkdir -p "$W/keys"
	[ -s "$W/keys/admin" ] || ssh-keygen -q -t ed25519 -N '' -C aka-mvp-rehearsal -f "$W/keys/admin"
	sleep 2
	local pc_pub pull
	pc_pub=$(docker logs ops-pc 2>&1 | grep '^WGOPS_PUB_pc=' | tail -1)
	pull=$(docker logs ops-pc 2>&1 | grep '^PULL_SSH_KEY=' | tail -1)
	sed -e "s|^PUB_data=.*|PUB_data=${IP[data]}|" -e "s|^PUB_mgmt=.*|PUB_mgmt=${IP[mgmt]}|" -e "s|^PUB_mon=.*|PUB_mon=${IP[mon]}|" \
		-e "s|^PUB_edge_01=.*|PUB_edge_01=${IP[edge-01]}|" -e "s|^PUB_edge_02=.*|PUB_edge_02=${IP[edge-02]}|" \
		-e 's|^BOOTSTRAP_SSH_FROM=.*|BOOTSTRAP_SSH_FROM="172.30.0.1"|' \
		-e "s|^ADMIN_SSH_KEY=.*|ADMIN_SSH_KEY=\"$(cat "$W/keys/admin.pub")\"|" \
		-e "s|^#OPS_PC_PROXY=.*|OPS_PC_PROXY=\"docker exec -i ops-pc nc %h %p\"|" \
		-e "s|^ADMIN_SSH_IDENTITY=.*|ADMIN_SSH_IDENTITY=$W/keys/admin|" \
		-e 's|^OSSBSS_URL=.*|OSSBSS_URL=http://fake-slack:8080/|' \
		"$R/deploy/inventory.env.example" > "$W/inventory.env"
	{
		echo "$pc_pub"
		echo "$pull"
	} >> "$W/inventory.env"
	echo "== bootstrap.sh（docker exec で root として。VPS では KAGOYA の鍵で SSH）"
	local n
	for n in $NODES; do
		docker exec -i -e AKA_NO_SYSTEMD=1 "rh-$n" bash -s -- "$n" "$(cat "$W/keys/admin.pub")" \
			< "$R/deploy/host/bootstrap.sh" > "$W/boot-$n.log" 2>&1
		check "B-$n" "bootstrap.sh が $n で終わる" $?
		grep -E '^WG(SVC|OPS)_PUB_' "$W/boot-$n.log" >> "$W/inventory.env"
	done
	expect_ok B-root "sshd が root を断る設定（PermitRootLogin no）" sh -c "docker exec rh-data sshd -T | grep -qx 'permitrootlogin no'"
	render
	cp "$W/out/ops-pc/"{wg-ops.conf,ssh_config,nodes.list} "$W/ops-pc/state/"
	docker restart ops-pc > /dev/null
	{
		echo "Include $W/out/ssh_config"
		echo "Host *"
		echo "    StrictHostKeyChecking no"
		echo "    UserKnownHostsFile /dev/null"
		echo "    LogLevel ERROR"
	} > "$SSHCFG"
	expect_ok B-ssh "作業ユーザー aka で公開のアドレスに SSH で入れる（最初の導入の間）" rssh aka-data-pub true
}

render() {
	python3 "$R/deploy/bin/render" "$W/inventory.env" "$W/out" > "$W/render.log" 2>&1
	check "R-render" "描き出し" $?
}

push() { # <ノード> <段 ...>: 公開のアドレスで送る。nft の段の後は 60 秒の内に確かめる
	local n=$1 how=${PUSH_VIA:-pub}
	shift
	local host="aka-$n-pub"
	[ "$how" = wg ] && host="aka-$n"
	AKA_NO_SYSTEMD=1 AKA_SSH=$host AKA_SSH_CONFIG=$SSHCFG "$R/deploy/bin/push-host" "$W/out" "$n" "$@" > "$W/push-$n.log" 2>&1
	local r=$?
	if [ $r = 0 ] && [[ " $* " == *" nft "* ]] && [ "${NO_CONFIRM:-0}" != 1 ]; then
		rssh "$host" sudo aka-nft-confirm >> "$W/push-$n.log" 2>&1
		r=$?
	fi
	return $r
}

apply() {
	local n
	for n in $NODES; do
		push "$n" files wg nft
		check "A-$n" "apply-host.sh（files wg nft）が $n で終わり、新しい SSH で確かめられる" $?
	done
	sleep 5
	# つなぎに行く側から流して、ハンドシェイクを起こす
	for n in data mgmt edge-01 edge-02; do ex "$n" ping -c1 -W2 10.82.0.1 > /dev/null 2>&1; done
	for n in mgmt edge-01 edge-02; do ex "$n" ping -c1 -W2 10.81.0.1 > /dev/null 2>&1; done
	for n in edge-01 edge-02; do ex "$n" ping -c1 -W2 10.81.0.2 > /dev/null 2>&1; done
	docker exec ops-pc nc -z -w3 10.82.0.1 3000 > /dev/null 2>&1
	sleep 2
}

handshakes() { # <ノード> <インターフェース> <期待するピアの数>
	local c
	c=$(ex "$1" wg show "$2" latest-handshakes | awk '$2 > 0' | wc -l)
	[ "$c" = "$3" ]
}

test_net() {
	echo "== WireGuard"
	expect_ok W1 "データ面の wg-svc が管理面とエッジ 2 台の 3 つとハンドシェイクする" handshakes data wg-svc 3
	expect_ok W2 "管理面の wg-svc がデータ面とエッジ 2 台の 3 つとハンドシェイクする" handshakes mgmt wg-svc 3
	expect_ok W3 "監視ノードの wg-ops が 4 ノードと ops-pc の 5 つとハンドシェイクする" handshakes mon wg-ops 5
	expect_ng W4 "エッジどうしは wg-svc でつながらない（edge-01 → edge-02）" ex edge-01 ping -c1 -W2 10.81.0.12
	expect_ng W5 "監視ノードは中継しない（ops-pc → データ面の wg-ops）" docker exec ops-pc nc -z -w3 10.82.0.2 22
	expect_ng W6 "監視ノードは中継しない（データ面 → エッジの wg-ops）" ex data ping -c1 -W2 10.82.0.11
	echo "== 公開ポート（DNAT の後の forward。表 inet aka の published）"
	expect_ok P1 "エッジ → データ面の RADIUS（UDP 1812）" try edge-01 udp 10.81.0.1 1812
	expect_ok P2 "エッジ → データ面の RADIUS（UDP 1813）" try edge-02 udp 10.81.0.1 1813
	expect_ng P3 "管理面 → データ面の RADIUS は断る" try mgmt udp 10.81.0.1 1812
	expect_ok P4 "管理面 → aka-vecgen の管理API（9443）" try mgmt tcp 10.81.0.1 9443
	expect_ok P5 "管理面 → aka-radius の管理API（9444）" try mgmt tcp 10.81.0.1 9444
	expect_ng P6 "エッジ → データ面の管理API は断る" try edge-01 tcp 10.81.0.1 9443
	expect_ng P7 "インターネット → データ面の RADIUS は断る" try ap udp "${IP[data]}" 1812
	expect_ok P8 "エッジ → 管理面の CRL の配布（8449）" try edge-01 tcp 10.81.0.2 8449
	expect_ng P9 "データ面 → 管理面の 8449 は断る" try data tcp 10.81.0.2 8449
	expect_ok P10 "管理面 → エッジの管理API（9447）" try mgmt tcp 10.81.0.11 9447
	expect_ng P11 "データ面 → エッジの管理API は断る" try data tcp 10.81.0.11 9447
	expect_ok P12 "インターネットの AP → エッジのテナントのポート（20000）" try ap tcp "${IP[edge-01]}" 20000
	expect_ng P13 "インターネット → エッジの管理API は断る" try ap tcp "${IP[edge-01]}" 9447
	expect_ok P14 "ops-pc → 監視の画面（3000）" docker exec ops-pc nc -z -w3 10.82.0.1 3000
	expect_ng P15 "データ面 → 監視の画面は断る" try data tcp 10.82.0.1 3000
	echo "== ホストへの入力（input）"
	local n
	for n in data mon; do docker exec -d "rh-$n" python3 /usr/local/bin/svc.py serve tcp:9100; done
	sleep 1
	expect_ok I1 "監視ノード → データ面の node_exporter（9100、wg-ops）" try mon tcp 10.82.0.2 9100
	expect_ng I2 "インターネット → データ面の 9100 は断る" try ap tcp "${IP[data]}" 9100
	expect_ng I3 "インターネット → データ面の SSH は断る（最初の導入の間も、手元のアドレス以外）" docker exec rh-ap nc -z -w3 "${IP[data]}" 22
	expect_ng I4 "エッジ → データ面の SSH（wg-svc）は断る" docker exec rh-edge-01 nc -z -w3 10.81.0.1 22
	echo "== SSH（ops-pc と監視ノードを踏み台に）"
	expect_ok S1 "手元 → aka-data（ops-pc → 監視ノード → wg-ops）で aka として入れる" sh -c "[ \"\$(ssh -F '$SSHCFG' -o ConnectTimeout=8 aka-data id -un)\" = aka ]"
	expect_ok S2 "手元 → aka-edge-02 も同じ経路で入れる" rssh aka-edge-02 true
}

rollback() {
	echo "== nftables の戻し（確かめがなければ 60 秒で前の規則に戻る）"
	sed -i 's|^BOOTSTRAP_SSH_FROM=.*|BOOTSTRAP_SSH_FROM=""|' "$W/inventory.env"
	render
	NO_CONFIRM=1 push data files nft
	expect_ng N1 "確かめる前は、手元から公開のアドレスへの SSH が断られる" rssh aka-data-pub true
	sleep 65
	expect_ok N2 "確かめがないので 60 秒で前の規則に戻り、また入れる" rssh aka-data-pub true
}

close() {
	echo "== 最初の導入を閉じる（BOOTSTRAP_SSH_FROM を空にして、wg-ops を通して送る）"
	local n
	sed -i 's|^BOOTSTRAP_SSH_FROM=.*|BOOTSTRAP_SSH_FROM=""|' "$W/inventory.env"
	render
	for n in $NODES; do
		PUSH_VIA=wg push "$n" files nft
		check "C-$n" "$n に wg-ops を通して送り、確かめられる" $?
	done
	expect_ng C1 "閉じた後は、公開のアドレスへの SSH が断られる" rssh aka-data-pub true
	expect_ok C2 "閉じた後も、wg-ops を通して入れる" rssh aka-mgmt true
}

pull() {
	echo "== ログとバックアップの取得（pull と rrsync -ro）"
	local n
	for n in $NODES; do
		ex "$n" sh -c 'install -d -o root -g pull -m 750 /srv/aka-pull/logs/x /srv/aka-pull/backups/20261105 &&
			echo log > /srv/aka-pull/logs/x/app.log-20261104.gz && echo bk > /srv/aka-pull/backups/20261105/b.tgz &&
			chgrp -R pull /srv/aka-pull && chmod -R g+rX /srv/aka-pull'
	done
	expect_ok G1 "ops-pc の pull.sh が 5 ノードから取りに行ける" docker exec ops-pc /usr/local/bin/pull.sh
	local miss=0
	for n in $NODES; do [ -s "$W/ops-pc/data/$n/logs/x/app.log-20261104.gz" ] && [ -s "$W/ops-pc/data/$n/backups/20261105/b.tgz" ] || miss=1; done
	check G2 "取ったものが ops-pc の data/<ノード>/ にある" $miss
	expect_ng G3 "pull は書けない（rrsync -ro）" docker exec ops-pc sh -c 'rsync -e "ssh -F /state/ssh_config" /etc/hostname aka-data:./x'
	expect_ng G4 "pull はシェルを動かせない" docker exec ops-pc sh -c '[ "$(ssh -F /state/ssh_config aka-data id -un)" = pull ]'
	expect_ok G5a "pull の踏み台の転送で各ノードの 22 番には届く" docker exec ops-pc sh -c 'timeout 10 ssh -F /state/ssh_config -W 10.82.0.2:22 aka-mon < /dev/null | head -c3 | grep -q SSH'
	expect_ng G5 "pull の踏み台の転送は各ノードの 22 番だけ（9100 は断る）" docker exec ops-pc sh -c 'printf x | timeout 10 ssh -F /state/ssh_config -W 10.82.0.2:9100 aka-mon | head -c1 | grep -q x'
}

monitor() {
	echo "== 監視（設定の確かめと、警告から Slack の形の通知まで。ホストの Docker で動かす）"
	local M=$W/monitor
	rm -rf "$M"
	mkdir -p "$M/fake" "$M/textfile" "$M/secrets"
	cp -r "$R/deploy/monitor/." "$M/"
	cp "$W/out/mon/root/opt/aka-monitor/prometheus/prometheus.yml" "$M/prometheus/prometheus.yml.rendered"
	printf 'http://fake-slack:8080/hook\n' > "$M/secrets/slack-webhook"
	openssl rand -hex 16 > "$M/secrets/grafana-admin"
	chmod 644 "$M/secrets/"* # リハーサルだけ（VPS では apply-host.sh が UID ごとに 600）
	expect_ok M1 "描き出した prometheus.yml と rules.yml が promtool の検査を通る" docker run --rm -v "$M/prometheus:/etc/prometheus:ro" --entrypoint promtool prom/prometheus:v3.15.1 check config /etc/prometheus/prometheus.yml.rendered
	expect_ok M2 "alertmanager.yml が amtool の検査を通る" docker run --rm -v "$M/alertmanager:/a:ro" -v "$M/secrets:/run/secrets:ro" --entrypoint amtool prom/alertmanager:v0.34.2 check-config /a/alertmanager.yml
	# リハーサルの prometheus.yml: ホストの textfile を読む node_exporter だけを見る
	cat > "$M/prometheus/prometheus.yml" << 'EOF'
global: {scrape_interval: 15s, evaluation_interval: 15s}
rule_files: [/etc/prometheus/rules.yml]
alerting: {alertmanagers: [{static_configs: [{targets: [alertmanager:9093]}]}]}
scrape_configs:
  - job_name: node
    static_configs: [{targets: [node-exporter:9100], labels: {node: rehearsal}}]
EOF
	cat > "$M/compose.rehearsal.yaml" << EOF
services:
  node-exporter:
    image: prom/node-exporter:v1.12.1
    command: [--collector.disable-defaults, --collector.textfile, --collector.textfile.directory=/textfile]
    volumes: ["$M/textfile:/textfile:ro"]
  fake-slack:
    image: rh-node:dev
    entrypoint: ["python3", "/fake/fake_slack.py"]
    volumes: ["$M/fake:/fake"]
EOF
	cat > "$M/fake/fake_slack.py" << 'EOF'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open("/fake/received.jsonl", "ab") as f:
            f.write(body.replace(b"\n", b" ") + b"\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
EOF
	printf 'MON_ADDR=127.0.0.1\n' > "$M/.env"
	(cd "$M" && docker compose -p rh-monitor -f compose.yaml -f compose.rehearsal.yaml up -d --wait > "$W/monitor-up.log" 2>&1)
	check M3 "監視の compose が起動し healthy になる" $?
	expect_ok M4 "Grafana が応え、ダッシュボード「aka-mvpset の概要」が置かれる" sh -c "curl -sf -u admin:\$(cat '$M/secrets/grafana-admin') 'http://127.0.0.1:3000/api/search?query=aka' | grep -q aka-overview"
	echo "== textfile.sh から警告まで"
	docker rm -f rh-alert-test > /dev/null 2>&1
	docker run -d --name rh-alert-test --restart unless-stopped busybox:1.37.0 sleep 1d > /dev/null
	AKA_TEXTFILE_DIR=$M/textfile bash "$R/deploy/node/textfile.sh"
	expect_ok M5 "textfile.sh がコンテナの状態を書く" grep -q 'aka_container_running{container="rh-alert-test"} 1' "$M/textfile/aka.prom"
	sleep 40
	expect_ok M6 "Prometheus が textfile の数値を読む" sh -c "curl -sf 'http://127.0.0.1:9090/api/v1/query?query=aka_container_running%7Bcontainer%3D%22rh-alert-test%22%7D' | grep -q '\"1\"'"
	docker stop rh-alert-test > /dev/null
	for _ in $(seq 18); do
		AKA_TEXTFILE_DIR=$M/textfile bash "$R/deploy/node/textfile.sh"
		grep -q ContainerNotRunning "$M/fake/received.jsonl" 2> /dev/null && break
		sleep 15
	done
	expect_ok M7 "止めたコンテナの警告が Slack の形で届く（ContainerNotRunning）" grep -q 'ContainerNotRunning.*rh-alert-test\|rh-alert-test.*ContainerNotRunning' "$M/fake/received.jsonl"
	cp "$M/fake/received.jsonl" "$W/slack-received.jsonl" 2> /dev/null
	docker rm -f rh-alert-test > /dev/null
}

teardown() {
	(cd "$W/monitor" 2> /dev/null && docker compose -p rh-monitor -f compose.yaml -f compose.rehearsal.yaml down -v > /dev/null 2>&1)
	local n
	for n in $NODES; do docker rm -f "rh-$n" "rh-$n-svc" > /dev/null 2>&1; docker network rm "rh-int-$n" > /dev/null 2>&1; done
	docker rm -f rh-ap ops-pc rh-alert-test > /dev/null 2>&1
	docker network rm rh-inet > /dev/null 2>&1
	docker ps -a --format '{{.Names}}' | grep -E '^(rh-|ops-pc)' || echo "コンテナとネットワークは片付けた"
}

case ${1:-} in
all)
	: > "$RES"
	up && boot && apply && test_net && rollback && close && pull && monitor
	echo "== 結果: PASS $(grep -c 'PASS$' "$RES") / $(wc -l < "$RES")"
	;;
up | boot | apply | close | pull | monitor | teardown | rollback) "$1" ;;
test) test_net ;;
*) echo "使い方: rehearsal.sh all|up|boot|apply|test|rollback|close|pull|monitor|teardown" >&2; exit 2 ;;
esac
