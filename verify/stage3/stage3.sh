#!/bin/bash
# 段階 3 の終わりの通し（概要 §18.7 の Q8）の、検証機の側の部品。手元の drive.sh が ssh で呼ぶ。
# 検証機の作業場所（README の「配置」）の tools/ で動かす。確かめの結果は「<場面>\t<PASS|FAIL>\t<内容>」の行で標準出力に出す。
#
#   ./stage3.sh <サブコマンド> [引数]
#
# 公開のリポジトリに置くので、ドメイン・AUD・メールアドレスは書かない（作業場所の site.env から読む）。
set -uo pipefail

T=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$T/.." && pwd)
V=$W/vecgen
R=$W/radius/deployments
P=$W/prov
O=$W/ossbss
K=$W/pki
OUT=$W/out
mkdir -p "$K" "$OUT"
# site.env: OSSBSS_ACCESS_TEAM_DOMAIN、OSSBSS_ACCESS_AUD、ADMIN_EMAIL、TOKEN_FILE
. "$W/site.env"

# どのノードも .env の COMPOSE_PROJECT_NAME・COMPOSE_FILE を使い、運用ガイドと同じ素の docker compose で動かす
vc() { (cd "$V" && docker compose "$@"); }
rc() { (cd "$R" && docker compose "$@"); }
pc() { (cd "$P" && docker compose "$@"); }
oc() { (cd "$O" && docker compose "$@"); }
check() { # <場面> <内容> <0 なら PASS>
	local r=FAIL
	[ "$3" = 0 ] && r=PASS
	printf '%s\t%s\t%s\n' "$1" "$r" "$2"
}
step() { echo "== $*"; }
ok() { if [ "$@" ]; then echo 0; else echo 1; fi; }
sql() { oc exec -T postgres psql -U ossbss -d ossbss -At -c "$1"; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
# dapi <vecgen|radius> <メソッド> <パス> [本文]: 下流の管理API を直接呼ぶ（aka-provisioner のクライアント証明書で）
dapi() {
	local port=9444 ca=$K/radius-admin.pem
	[ "$1" = vecgen ] && port=9443 ca=$K/vecgen-admin.pem
	curl -sS --cacert "$ca" --cert "$K/prov-client.pem" --key "$K/prov-client.key" -H X-Operator-Id:stage3 \
		-H Content-Type:application/json -X "$2" "https://localhost:$port/admin/v2$3" ${4:+-d "$4"}
}
ossbss_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$(oc ps -q aka-ossbss)" | cut -d' ' -f1; }
healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$(${1} ps -q "$2")" 2> /dev/null)" = healthy ]; }

KI=465b5ce8b199b49faa5f0a2ee238a6bc
OPC=cd63cb71954a9f4e48a5994e37a02baf
REALM=wlan.mnc010.mcc440.3gppnetwork.org

# ---------------------------------------------------------------- 導入（各ノードの運用ガイドの 2 章のとおり）
setup() {
	step "aka-vecgen"
	cd "$V" || exit 1
	cp .env.example .env && chmod 600 .env
	sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD='"$(openssl rand -hex 24)"'|' .env
	printf 'COMPOSE_PROJECT_NAME=s3vecgen\nCOMPOSE_FILE=compose.yaml:compose.fluent-bit.yaml\n' >> .env
	mkdir -p secrets audit
	openssl rand -hex 32 > secrets/kek
	touch secrets/admin-clients
	sudo chown 65532 secrets/kek secrets/admin-clients audit
	sudo chmod 600 secrets/kek secrets/admin-clients
	sudo chmod 750 audit
	vc up -d --no-build --wait --wait-timeout 120 || exit 1
	vc exec -T aka-vecgen /aka-vecgen admin-cert > "$K/vecgen-admin.pem"

	step "aka-provisioner のクライアント証明書（下流のピンに要る）"
	cd "$P" || exit 1
	cp .env.example .env && chmod 600 .env
	sed -i -e 's|^PROVISIONER_VALKEY_PASSWORD=.*|PROVISIONER_VALKEY_PASSWORD='"$(openssl rand -hex 24)"'|' \
		-e 's|^PROVISIONER_FLUENT_BIT_PORT=.*|PROVISIONER_FLUENT_BIT_PORT=24225|' \
		-e 's|^COMPOSE_FILE=.*|COMPOSE_FILE=compose.yaml:compose.aka-radius-admin.yaml:compose.aka-av.yaml|' .env
	echo 'COMPOSE_PROJECT_NAME=s3prov' >> .env
	mkdir -p secrets audit certs
	touch secrets/admin-clients
	# 下流の共有ネットワークがまだないので、この 1 回だけ重ね合わせを外す
	COMPOSE_FILE=compose.yaml docker compose run --rm --no-deps -T aka-provisioner gen-client-cert -name provisioner > downstreams/client.pem 2> "$OUT/prov-gen.txt"
	PIN=$(grep -E '^provisioner=[0-9a-f]{64}$' "$OUT/prov-gen.txt") || exit 1
	cp downstreams/client.pem "$K/prov-client.pem"
	openssl pkey -in "$K/prov-client.pem" -out "$K/prov-client.key"

	step "aka-vecgen にピンを足す"
	echo "$PIN" | sudo tee -a "$V/secrets/admin-clients" > /dev/null
	vc kill -s HUP aka-vecgen

	step "aka-radius"
	cd "$R" || exit 1
	cp .env.example .env && chmod 600 .env
	sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD='"$(openssl rand -hex 24)"'|' .env
	printf 'COMPOSE_PROJECT_NAME=s3radius\nCOMPOSE_FILE=docker-compose.yml:docker-compose.aka-av.yml:%s/compose.radius.yaml\n' "$T" >> .env
	mkdir -p sources certs/admin secrets audit backups
	cp sources/sources.example.json sources/sources.json
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=aka-radius \
		-addext extendedKeyUsage=clientAuth -keyout sources/vecgen-client.key -out sources/vecgen-client.pem 2> /dev/null
	VCLIENT=$(vc exec -T aka-vecgen /aka-vecgen client add -name aka-radius -cert - < sources/vecgen-client.pem)
	echo "$VCLIENT"
	vc exec -T aka-vecgen /aka-vecgen av-cert > sources/vecgen-av-server.pem
	echo "$PIN" > secrets/admin-clients
	sudo chown -R 65532:65532 sources certs/admin secrets/admin-clients audit
	sudo chmod 600 sources/vecgen-client.key secrets/admin-clients
	rc run --rm --no-deps -v ./certs/admin:/out admin admin-cert create -hosts aka-radius-admin,localhost,127.0.0.1 -out /out -operator stage3 2>&1 | tail -1
	sudo cat certs/admin/server.pem > "$K/radius-admin.pem"
	rc up -d --no-build --wait --wait-timeout 180 || exit 1
	# run は決まった IP の auth とぶつかるので、動いている auth で確かめる
	rc exec -T auth aka-radius sources check 2>&1 | tee "$OUT/sources-check.txt"
	check I1 "aka-radius の sources check が aka-vecgen につながる" "$(grep -q 'connection: OK' "$OUT/sources-check.txt"; echo $?)"
	for e in "edge-t1 172.30.250.101" "edge-t2 172.30.250.102" "ap-direct 172.30.250.100"; do
		set -- $e
		echo "$1-secret-0123456789" | rc exec -T admin aka-radius client add -ip "$2" -name "$1" -trust-stamp true -operator stage3 > /dev/null
	done

	step "aka-provisioner の登録簿"
	cd "$P" || exit 1
	cp "$K/vecgen-admin.pem" downstreams/vecgen-admin.pem
	cp "$K/radius-admin.pem" downstreams/radius-admin.pem
	cat > downstreams/downstreams.json << EOF
{
  "clientCert": "client.pem",
  "clientKey": "client.pem",
  "vecgen": { "url": "https://aka-vecgen:9443/admin/v2", "serverCert": "vecgen-admin.pem" },
  "radius": { "url": "https://aka-radius-admin:9444/admin/v2", "serverCert": "radius-admin.pem" }
}
EOF

	step "aka-ossbss の準備"
	cd "$O" || exit 1
	cp .env.example .env && chmod 600 .env
	sed -i -e 's|^OSSBSS_DB_PASSWORD=.*|OSSBSS_DB_PASSWORD='"$(openssl rand -hex 24)"'|' \
		-e "s|^OSSBSS_ACCESS_TEAM_DOMAIN=.*|OSSBSS_ACCESS_TEAM_DOMAIN=$OSSBSS_ACCESS_TEAM_DOMAIN|" \
		-e "s|^OSSBSS_ACCESS_AUD=.*|OSSBSS_ACCESS_AUD=$OSSBSS_ACCESS_AUD|" \
		-e "s|^OSSBSS_INITIAL_ADMIN_EMAIL=.*|OSSBSS_INITIAL_ADMIN_EMAIL=$ADMIN_EMAIL|" \
		-e 's|^PROVISIONER_FLUENT_BIT_PORT=.*|PROVISIONER_FLUENT_BIT_PORT=24225|' \
		-e 's|^OSSBSS_RECONCILE_AT=.*|OSSBSS_RECONCILE_AT=23:50|' \
		-e 's|^OSSBSS_USAGE_IMPORT_AT=.*|OSSBSS_USAGE_IMPORT_AT=23:55|' .env
	echo 'COMPOSE_PROJECT_NAME=s3ossbss' >> .env
	mkdir -p secrets certs audit backups
	(umask 077; openssl rand -hex 32 > secrets/kek)
	install -m 600 "$TOKEN_FILE" secrets/tunnel-token
	# aka-provisioner の共有ネットワークは上の run で作られている
	oc run --rm --no-deps -T aka-ossbss gen-client-cert -name ossbss > certs/provisioner-client.pem 2> "$OUT/ossbss-gen.txt"
	PIN2=$(grep -E '^ossbss=[0-9a-f]{64}$' "$OUT/ossbss-gen.txt") || exit 1

	step "aka-provisioner を起動する"
	cd "$P" || exit 1
	echo "$PIN2" > secrets/admin-clients
	sudo chown -R 65532:65532 downstreams secrets/admin-clients audit
	sudo chmod 600 downstreams/client.pem secrets/admin-clients
	pc up -d --no-build --wait --wait-timeout 120 || exit 1
	pc exec -T aka-provisioner /aka-provisioner check-downstream | tee "$OUT/check-downstream.txt"
	check I2 "aka-provisioner の check-downstream が 2 つの下流につながる" "$(ok "$(grep -c '接続できました' "$OUT/check-downstream.txt")" = 2)"

	step "aka-ossbss を起動する"
	cd "$O" || exit 1
	pc exec -T aka-provisioner /aka-provisioner server-cert > certs/provisioner-server.pem
	sudo chown -R 65532:65532 secrets certs audit
	sudo chmod 600 secrets/kek secrets/tunnel-token certs/provisioner-client.pem certs/provisioner-server.pem
	oc run --rm --no-deps aka-ossbss check-provisioner 2>&1 | grep -v -E 'Container|Network|Volume' | tee "$OUT/check-provisioner.txt"
	check I3 "aka-ossbss の check-provisioner がつながる" "$(grep -q '接続できました' "$OUT/check-provisioner.txt"; echo $?)"
	oc up -d --no-build --wait --wait-timeout 180 || exit 1
	oc up -d --no-build cloudflared
	for s in vc:aka-vecgen rc:auth rc:acct rc:admin pc:aka-provisioner oc:aka-ossbss oc:postgres; do
		healthy "${s%%:*}" "${s##*:}" || echo "unhealthy: $s"
	done
	n=$(for f in vc rc pc oc; do $f ps --format '{{.Service}} {{.Status}}'; done | tee "$OUT/ps.txt" | grep -c -E 'unhealthy|Restarting')
	cat "$OUT/ps.txt"
	check I4 "全部のコンテナが動き、unhealthy がない" "$(ok "$n" = 0)"
	check I5 "aka-ossbss と PostgreSQL と cloudflared はホストにポートを公開しない" "$(ok -z "$(oc ps --format '{{.Publishers}}' | grep -E '0\.0\.0\.0|127\.0\.0\.1')")"
	check I6 "PIN のファイルと KEK が UID 65532 の 600（ガイドのとおり）" "$(ok "$(sudo stat -c '%u %a' "$O/secrets/kek") $(sudo stat -c '%u %a' "$P/secrets/admin-clients")" = "65532 600 65532 600")"
	for i in $(seq 1 30); do
		c=$(oc logs cloudflared 2>&1 | grep -c 'Registered tunnel connection')
		[ "$c" -ge 4 ] && break
		sleep 2
	done
	check C1 "Tunnel の接続が 4 本（$c）" "$(ok "$c" -ge 4)"
	IP=$(ossbss_ip)
	check C2 "JWT なしの直接の要求は 401" "$(ok "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:8446/")" = 401)"
	check C3 "/healthz は JWT なしで 200" "$(ok "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP:8446/healthz")" = 200)"
}

# ---------------------------------------------------------------- EAP
cfg() { # <IMSI> <ポート> <SQN の初期値> <SQN の保存ファイル> <SSID>
	local f=$OUT/cfg-$1-$2-$3-$5.yaml
	cat > "$f" << EOF
radius:
  server_addr: "127.0.0.1:$2"
  secret: "ap-secret-0123456789"
  timeout_ms: 6000
  retries: 1
radius_attrs:
  nas_ip_address: "192.0.2.10"
  nas_identifier: "ap-01"
  called_station_id: "00-11-22-33-44-55:$5"
  calling_station_id: "02-00-00-00-00-01"
eap:
  method_mismatch_policy: "warn"
  outer_identity_update_on_permanent_req: true
  permanent_id_policy: "always"
  aka_prime:
    net_name: "WLAN"
identity:
  realm: "$REALM"
sim:
  imsi: "$1"
  ki: "$KI"
  opc: "$OPC"
  amf: "8000"
  sqn_initial_hex: "$3"
sqn_store:
  mode: "file"
  path: "$4"
EOF
	echo "$f"
}
# eapcheck <場面> <内容> <IMSI> <aka|prime> <accept|reject> [event_id] [ポート] [SQN の初期値] [SSID]
eapcheck() {
	local id=$1 text=$2 imsi=$3 method=$4 expect=$5 ev=${6:-} port=${7:-11812} sqn=${8:-000000000000} ssid=${9:-ssid1} prefix=0
	[ "$method" = prime ] && prefix=6
	local name=$id-$imsi
	cat > "$OUT/case-$name.yaml" << EOF
version: 1
name: $name
identity: "$prefix$imsi@$REALM"
expect:
  result: $expect
trace:
  level: verbose
EOF
	local before=0 after=0 r
	[ -n "$ev" ] && before=$(rc logs --no-color auth 2> /dev/null | grep -c "\"event_id\":\"$ev\".*$imsi")
	"$T/eapaka_test" -c "$(cfg "$imsi" "$port" "$sqn" "$OUT/sqn-$imsi-$sqn.json" "$ssid")" --trace-radius-attrs run "$OUT/case-$name.yaml" > "$OUT/eap-$name.log" 2>&1
	r=$?
	if [ -n "$ev" ]; then
		sleep 1
		after=$(rc logs --no-color auth 2> /dev/null | grep -c "\"event_id\":\"$ev\".*$imsi")
		[ $r = 0 ] && [ "$after" -gt "$before" ]
		r=$?
	fi
	check "$id" "$text" "$r"
}

# ---------------------------------------------------------------- Accounting（エッジの代わりを通す）
acct_send() { # <種類> <時間> <受信> <受信の Gigawords> <送信> <IMSI> <Class>
	printf 'Acct-Status-Type = %s\nAcct-Session-Id = "s3-acct-1"\nUser-Name = "0%s@%s"\nNAS-Identifier = "ap-01"\nClass = "%s"\nAcct-Session-Time = %s\nAcct-Input-Octets = %s\nAcct-Input-Gigawords = %s\nAcct-Output-Octets = %s\n' \
		"$1" "$6" $REALM "$7" "$2" "$3" "$4" "$5" |
		rc exec -T ap radclient -r 1 -t 5 172.30.250.101:1813 acct ap-secret-0123456789 2>&1
}
acct_start() { # <IMSI>
	local sid
	sid=$(dapi radius GET "/sessions?imsi=$1" | json '" ".join(i["id"] for i in d["items"])')
	sid=${sid%% *}
	echo "$sid" > "$OUT/acct-sid"
	acct_send Start 0 0 0 0 "$1" "$sid" > "$OUT/acct.log"
	acct_send Interim-Update 60 1000 1 500 "$1" "$sid" >> "$OUT/acct.log"
	check A1 "Accounting の Start と Interim に応答がある" "$(ok "$(grep -c 'Accounting-Response' "$OUT/acct.log")" = 2)"
}
acct_stop() { # <IMSI>
	local sid u today
	sid=$(cat "$OUT/acct-sid")
	acct_send Stop 90 1500 1 800 "$1" "$sid" >> "$OUT/acct.log"
	today=$(TZ=Asia/Tokyo date +%F)
	u=$(dapi radius GET "/usage?date=$today" | json "[ (i['sessions'],i['seconds'],i['inOctets'],i['outOctets']) for i in d['items'] if i['imsi']=='$1' and i['tenantId']==1 ]")
	echo "usage: $u"
	check A2 "利用の集計がテナント 1 の刻印で手の計算と合う（$u）" "$(ok "$u" = "[(1, 90, 4294968796, 800)]")"
}

# ---------------------------------------------------------------- 一括投入
gen_csv() { # <vecgen|radius> <最初の番号> <件数> <ファイル>: IMSI は 44010 + 10 桁
	python3 -I - "$@" << 'EOF'
import sys
kind, start, n, path = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with open(path, "w") as f:
    if kind == "vecgen":
        f.write("imsi,ki,opc,amf,sqn\n")
        for i in range(n):
            f.write("44010%010d,465b5ce8b199b49faa5f0a2ee238a6bc,cd63cb71954a9f4e48a5994e37a02baf,,\n" % (start + i))
    else:
        f.write("imsi\n")
        for i in range(n):
            f.write("44010%010d\n" % (start + i))
EOF
}
jobs_wait() { # 待ちと実行中のジョブがなくなるまで待つ（上限 40 分）。動いている間に 1 回だけメモリーを記録する
	local i=0 sampled=0
	while [ $i -lt 480 ]; do
		n=$(sql "SELECT count(*) FROM bulk_jobs WHERE state IN ('queued','running')")
		[ "$n" = 0 ] && break
		if [ $sampled = 0 ] && [ $i -ge 3 ]; then
			docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' | grep -E '^s3' > "$OUT/stats-$1.txt"
			sampled=1
		fi
		sleep 5
		i=$((i + 1))
	done
	sql "SELECT id, kind, state, total, ok_count, exists_count, failed_count, unprocessed_count, round(extract(epoch FROM finished_at - started_at)) FROM bulk_jobs ORDER BY id"
}
bulk_check() { # <vecgen の job> <radius の job>
	local a b
	a=$(sql "SELECT state, ok_count, round(extract(epoch FROM finished_at - started_at)) FROM bulk_jobs WHERE id=$1")
	b=$(sql "SELECT state, ok_count, round(extract(epoch FROM finished_at - started_at)) FROM bulk_jobs WHERE id=$2")
	echo "vecgen: $a / radius: $b"
	check B1 "vecgen 側の 1 万件が完了（$a 秒）" "$(echo "$a" | awk -F'|' '{exit !($1=="completed" && $2==10000 && $3<=1800)}'; echo $?)"
	check B2 "radius 側の 1 万件が完了（$b 秒）" "$(echo "$b" | awk -F'|' '{exit !($1=="completed" && $2==10000 && $3<=1800)}'; echo $?)"
	cat "$OUT/stats-bulk.txt" 2> /dev/null
}

# ---------------------------------------------------------------- 突き合わせ（下流を直接変えてずれを作る）
drift_state() { # <件数>: 一括投入の IMSI の radius 側を直接 inactive にする
	sql "SELECT imsi FROM subscribers WHERE imsi BETWEEN '440100001000000' AND '440100001999999' AND radius_state='active' ORDER BY imsi LIMIT $1" > "$OUT/drift.txt"
	export -f dapi
	export K
	xargs -P 8 -I{} bash -c "dapi radius PUT /subscribers/{}/state '{\"state\":\"inactive\",\"reason\":\"stage3\"}' > /dev/null" < "$OUT/drift.txt"
	wc -l < "$OUT/drift.txt"
}
drift_new() { # <IMSI>...: 台帳にない IMSI を radius 側に直接登録する
	for i in "$@"; do
		dapi radius POST /subscribers "{\"imsi\":\"$i\",\"state\":\"inactive\",\"sourceId\":\"vecgen\",\"rules\":[{\"tenantId\":1,\"nasId\":\"*\",\"ssids\":[\"*\"]}]}" > /dev/null
	done
}
run_state() { sql "SELECT state, fixable_count, fixed_count, findings_total, round(extract(epoch FROM finished_at - started_at)::numeric, 1) FROM reconcile_runs ORDER BY id DESC LIMIT 1"; }

# ---------------------------------------------------------------- 課金（事実と利用を固定の過去の月に動かす）
# 取り込みは前の日までを読む（その日は途中の値なので）。今日の集計のキーを昨日に移して、取り込めるようにする
usage_yesterday() {
	local today yesterday k
	today=$(TZ=Asia/Tokyo date +%Y%m%d)
	yesterday=$(TZ=Asia/Tokyo date -d yesterday +%Y%m%d)
	for k in $(rc exec -T valkey valkey-cli --scan --pattern "usage:*$today*" | tr -d '\r'); do
		rc exec -T valkey valkey-cli RENAME "$k" "${k/$today/$yesterday}" > /dev/null
	done
	rc exec -T valkey valkey-cli --scan --pattern "usage:*$yesterday*" | wc -l
}
shift_month() {
	sql "CREATE TABLE IF NOT EXISTS usage_daily_202609 PARTITION OF usage_daily FOR VALUES FROM ('2026-09-01') TO ('2026-10-01')"
	sql "UPDATE usage_daily SET date='2026-09-15' WHERE date >= '2026-10-01'"
	sql "UPDATE charging_events SET time='2026-09-15 12:00:00+09'"
	# 本番では毎日取り込むので、9 月は全部の日を取り込めたものとして記録する（なければ usage_complete が false になる）
	sql "INSERT INTO usage_import_days (date, attempted_at, imported_at, last_error) SELECT d::date, now(), now(), '' FROM generate_series('2026-09-01'::date, '2026-09-30'::date, '1 day') d ON CONFLICT (date) DO NOTHING"
	sql "SELECT count(*) FROM charging_events; SELECT count(*) FROM usage_daily"
}

# ---------------------------------------------------------------- 運用
# sg <パターン> <ファイルの並び>: root の持ち物を読む（グロブも root で展開する）
sg() { sudo sh -c "grep -q -F -- '$1' $2 2> /dev/null"; }
trace_check() { # <場面>: 最後の状態の変更をトレースID で全ノードたどる
	local tid rows
	tid=$(sql "SELECT trace_id FROM audit_log WHERE action='subscriber.state' ORDER BY id DESC LIMIT 1")
	sleep 2
	rows=$(
		sg "\"traceId\":\"$tid\"" "$O/audit/audit-*.jsonl" && echo ossbss-audit
		sg "\"traceId\":\"$tid\"" "$P/audit/audit-*.jsonl" && echo prov-audit
		sg "\"trace_id\":\"$tid\"" "$P/logs_on_host/ossbss.log" && echo ossbss-log
		sg "\"trace_id\":\"$tid\"" "$P/logs_on_host/provisioner.log" && echo prov-log
		sg "\"traceId\":\"$tid\"" "$R/audit/audit-*.jsonl $V/audit/audit-*.jsonl" && echo downstream-audit
		sg "\"trace_id\":\"$tid\"" "$R/logs_on_host/admin.log $R/logs_on_host/vecgen.log" && echo downstream-log
	)
	echo "$rows" | tr '\n' ' '
	echo
	check "$1" "1 つの操作をトレースID で全ノードの記録からたどれる" "$(ok "$(echo "$rows" | wc -l)" = 6)"
}
logs_check() { # <場面>
	local missing=""
	for f in provisioner provisioner-valkey ossbss ossbss-postgres ossbss-cloudflared; do
		sudo test -s "$P/logs_on_host/$f.log" || missing="$missing $f"
	done
	for f in auth acct admin valkey vecgen vecgen-valkey; do
		sudo test -s "$R/logs_on_host/$f.log" || missing="$missing $f"
	done
	check "$1" "Fluent Bit のファイル（管理面 5・データ面 6）に書かれる${missing:+ ない:$missing}" "$(ok -z "$missing")"
	missing=""
	for d in "$O" "$P" "$R" "$V"; do
		sudo sh -c "ls $d/audit/audit-*.jsonl > /dev/null 2>&1" || missing="$missing $d"
	done
	check "$2" "監査ログの日ごとのファイル（4 ノード）がある${missing:+ ない:$missing}" "$(ok -z "$missing")"
	check "$3" "aka-ossbss の監査ログのファイルに鍵が出ていない" "$(if sudo sh -c "grep -q -e $KI -e $OPC $O/audit/audit-*.jsonl $P/audit/audit-*.jsonl $P/logs_on_host/*.log"; then echo 1; else echo 0; fi)"
}
remote_check() { # <場面>: 監査ログの接続元が cloudflared の付けた Cf-Connecting-IP か（Docker のアドレスでない）
	local r
	r=$(sql "SELECT remote FROM audit_log WHERE remote <> '' ORDER BY id DESC LIMIT 1")
	check "$1" "監査ログの接続元が Docker のアドレスでない" "$(echo "$r" | grep -qv -E '^(172\.|10\.|127\.)'; echo $?)"
}
# site_env <AUD> <TEAM>: Access の設定を変えて作り直す（401 と 503 の確かめ）
site_env() {
	(cd "$O" && sed -i -e "s|^OSSBSS_ACCESS_AUD=.*|OSSBSS_ACCESS_AUD=$1|" -e "s|^OSSBSS_ACCESS_TEAM_DOMAIN=.*|OSSBSS_ACCESS_TEAM_DOMAIN=$2|" .env)
	oc up -d --no-build --wait --wait-timeout 180 aka-ossbss 2>&1 | tail -1
}

cmd=${1:?usage: stage3.sh <サブコマンド>}
shift
case $cmd in
setup) setup ;;
eap) eapcheck "$@" ;;
acct-start) acct_start "$@" ;;
acct-stop) acct_stop "$@" ;;
gen-csv) gen_csv "$@" ;;
csv-get) cat "$1" ;;
jobs-wait) jobs_wait "$@" ;;
bulk-check) bulk_check "$@" ;;
drift-state) drift_state "$@" ;;
drift-new) drift_new "$@" ;;
run-state) run_state ;;
shift-month) shift_month ;;
usage-yesterday) usage_yesterday ;;
sql) sql "$1" ;;
trace-check) trace_check "$@" ;;
logs-check) logs_check "$@" ;;
remote-check) remote_check "$@" ;;
site-env) site_env "$@" ;;
stop) "$1" stop "${@:2}" ;;
start) "$1" up -d --no-build "${@:2}" ;;
backup-db) (cd "$O" && scripts/backup-db.sh "$1") ;;
restore-db) (cd "$O" && scripts/restore-db.sh "$1") ;;
up-ossbss) oc up -d --no-build --wait --wait-timeout 180 ;;
backup-valkey-prov) (cd "$P" && mkdir -p backups && scripts/backup-valkey.sh backups/valkey.rdb && scripts/restore-valkey.sh backups/valkey.rdb && docker compose up -d --no-build --wait --wait-timeout 120) ;;
check-downstream) pc exec -T aka-provisioner /aka-provisioner check-downstream ;;
dapi) dapi "$@" ;;
mark) check "$@" ;;
role) sql "UPDATE accounts SET role='$1', tenant_id=$2, disabled=${3:-false} WHERE email='$ADMIN_EMAIL'" ;;
restore-access) site_env "$OSSBSS_ACCESS_AUD" "$OSSBSS_ACCESS_TEAM_DOMAIN" ;;
bad-aud) site_env wrong-aud "$OSSBSS_ACCESS_TEAM_DOMAIN" ;;
bad-team) site_env "$OSSBSS_ACCESS_AUD" stage3-no-such-team.cloudflareaccess.com ;;
ps) for f in vc rc pc oc; do $f ps --format '{{.Service}} {{.Status}}'; done ;;
teardown)
	for f in oc pc rc vc; do $f down -v --remove-orphans 2>&1 | tail -1; done
	docker network ls --format '{{.Name}}' | grep -E '^aka-' | xargs -r docker network rm
	;;
*)
	echo "unknown: $cmd" >&2
	exit 2
	;;
esac
