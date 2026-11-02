#!/bin/bash
# 段階 4 の検証機の通し（概要 §18.9 の S4-9）の、検証機の側の部品。手元の drive.sh が ssh で呼ぶ。
# 検証機の作業場所の tools/ で動かす。確かめの結果は「<場面>\t<PASS|FAIL>\t<内容>」の行で標準出力に出す。
#
#   ./stage4.sh <サブコマンド> [引数]
#
# 公開のリポジトリに置くので、ドメイン・AUD・メールアドレス・検証機のアドレスは書かない（作業場所の site.env から読む）。
set -uo pipefail

T=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$T/.." && pwd)
V=$W/vecgen
R=$W/radius/deployments
P=$W/prov
O=$W/ossbss
CA=$W/ca
K=$W/pki
OUT=$W/out
AP=$W/ap
mkdir -p "$K" "$OUT" "$AP"
# site.env: OSSBSS_ACCESS_TEAM_DOMAIN、OSSBSS_ACCESS_AUD、ADMIN_EMAIL、TOKEN_FILE、DNS_DOMAIN、URN_PREFIX、C_ADDR、E_ADDR
. "$W/site.env"

vc() { (cd "$V" && docker compose "$@"); }
rc() { (cd "$R" && docker compose "$@"); }
pc() { (cd "$P" && docker compose "$@"); }
oc() { (cd "$O" && docker compose "$@"); }
cc() { (cd "$CA" && docker compose "$@"); }
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
	local port=9443 ca=$K/vecgen-admin.pem host=localhost
	if [ "$1" = radius ]; then port=9444 ca=$K/radius-admin.pem; fi
	curl -sS --cacert "$ca" --cert "$K/prov-client.pem" --key "$K/prov-client.key" -H X-Operator-Id:stage4 \
		-H Content-Type:application/json -X "$2" "https://$host:$port/admin/v2$3" ${4:+-d "$4"}
}
# eapi <エッジのアドレス> <メソッド> <パス> [本文]: エッジの管理API を直接呼ぶ（ずれを作るときだけ）
eapi() {
	curl -sS -k --max-time 30 --cert "$K/prov-client.pem" --key "$K/prov-client.key" -H X-Operator-Id:stage4 -H "Idempotency-Key: s4-$(date +%s%N)" \
		-H Content-Type:application/json -X "$2" "https://$1:9447$3" ${4:+-d "$4"}
}
ossbss_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$(oc ps -q aka-ossbss)" | cut -d' ' -f1; }
healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$(${1} ps -q "$2")" 2> /dev/null)" = healthy ]; }

KI=465b5ce8b199b49faa5f0a2ee238a6bc
OPC=cd63cb71954a9f4e48a5994e37a02baf
REALM=wlan.mnc010.mcc440.3gppnetwork.org
DIND_IMAGE=docker:29.9.2-dind

# ---------------------------------------------------------------- 中央とデータ面（各ノードの運用ガイドの 2 章のとおり。段階 3 の通しと同じ）
setup_central() {
	step "aka-vecgen"
	cd "$V" || exit 1
	cp .env.example .env && chmod 600 .env
	sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD='"$(openssl rand -hex 24)"'|' .env
	printf 'COMPOSE_PROJECT_NAME=s4vecgen\nCOMPOSE_FILE=compose.yaml:compose.fluent-bit.yaml\n' >> .env
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
	echo 'COMPOSE_PROJECT_NAME=s4prov' >> .env
	mkdir -p secrets audit certs
	touch secrets/admin-clients
	# 下流の共有ネットワークがまだないので、この 1 回だけ重ね合わせを外す
	COMPOSE_FILE=compose.yaml docker compose run --rm --no-deps -T aka-provisioner gen-client-cert -name provisioner > downstreams/client.pem 2> "$OUT/prov-gen.txt"
	PIN=$(grep -E '^provisioner=[0-9a-f]{64}$' "$OUT/prov-gen.txt") || exit 1
	echo "$PIN" > "$OUT/prov-pin"
	cp downstreams/client.pem "$K/prov-client.pem"
	openssl pkey -in "$K/prov-client.pem" -out "$K/prov-client.key"

	step "aka-vecgen にピンを足す"
	echo "$PIN" | sudo tee -a "$V/secrets/admin-clients" > /dev/null
	vc kill -s HUP aka-vecgen

	step "aka-radius（RADIUS は Tailscale のアドレスで受ける。本番はサービス用の WireGuard のアドレス）"
	cd "$R" || exit 1
	cp .env.example .env && chmod 600 .env
	sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD='"$(openssl rand -hex 24)"'|' .env
	printf 'COMPOSE_PROJECT_NAME=s4radius\nCOMPOSE_FILE=docker-compose.yml:docker-compose.aka-av.yml\nRADIUS_UDP_BIND=%s\n' "$C_ADDR" >> .env
	mkdir -p sources certs/admin secrets audit backups
	cp sources/sources.example.json sources/sources.json
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=aka-radius \
		-addext extendedKeyUsage=clientAuth -keyout sources/vecgen-client.key -out sources/vecgen-client.pem 2> /dev/null
	vc exec -T aka-vecgen /aka-vecgen client add -name aka-radius -cert - < sources/vecgen-client.pem
	vc exec -T aka-vecgen /aka-vecgen av-cert > sources/vecgen-av-server.pem
	echo "$PIN" > secrets/admin-clients
	sudo chown -R 65532:65532 sources certs/admin secrets/admin-clients audit
	sudo chmod 600 sources/vecgen-client.key secrets/admin-clients
	rc run --rm --no-deps -v ./certs/admin:/out admin admin-cert create -hosts aka-radius-admin,localhost,127.0.0.1 -out /out -operator stage4 2>&1 | tail -1
	sudo cat certs/admin/server.pem > "$K/radius-admin.pem"
	rc up -d --no-build --wait --wait-timeout 180 || exit 1
	rc exec -T auth aka-radius sources check 2>&1 | tee "$OUT/sources-check.txt"
	check I1 "aka-radius の sources check が aka-vecgen につながる" "$(grep -q 'connection: OK' "$OUT/sources-check.txt"; echo $?)"

	step "aka-provisioner の登録簿（radsec-ca とエッジは後で足す）"
	cd "$P" || exit 1
	cp "$K/vecgen-admin.pem" downstreams/vecgen-admin.pem
	cp "$K/radius-admin.pem" downstreams/radius-admin.pem
	cat > downstreams/downstreams.json << JSON
{
  "clientCert": "client.pem",
  "clientKey": "client.pem",
  "vecgen": { "url": "https://aka-vecgen:9443/admin/v2", "serverCert": "vecgen-admin.pem" },
  "radius": { "url": "https://aka-radius-admin:9444/admin/v2", "serverCert": "radius-admin.pem" }
}
JSON

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
	echo 'COMPOSE_PROJECT_NAME=s4ossbss' >> .env
	mkdir -p secrets certs audit backups
	(umask 077; openssl rand -hex 32 > secrets/kek)
	install -m 600 "$TOKEN_FILE" secrets/tunnel-token
	oc run --rm --no-deps -T aka-ossbss gen-client-cert -name ossbss > certs/provisioner-client.pem 2> "$OUT/ossbss-gen.txt"
	PIN2=$(grep -E '^ossbss=[0-9a-f]{64}$' "$OUT/ossbss-gen.txt") || exit 1

	step "aka-provisioner を起動する"
	cd "$P" || exit 1
	echo "$PIN2" > secrets/admin-clients
	sudo chown -R 65532:65532 downstreams secrets/admin-clients audit
	sudo chmod 600 downstreams/client.pem secrets/admin-clients
	pc up -d --no-build --wait --wait-timeout 120 || exit 1

	step "radsec-ca（aka-provisioner の共有ネットワークに入るので後に起動する。運用ガイド 3 章）"
	cd "$CA" || exit 1
	cp .env.example .env && chmod 600 .env
	mkdir -p secrets audit
	openssl rand -hex 32 > secrets/kek
	echo "$PIN" > secrets/admin-clients
	sed -i -e 's|^CA_ORG=.*|CA_ORG=Stage4 Lab|' -e "s|^CA_URN_PREFIX=.*|CA_URN_PREFIX=$URN_PREFIX|" -e "s|^CA_DNS_DOMAIN=.*|CA_DNS_DOMAIN=$DNS_DOMAIN|" \
		-e "s|^CA_BIND_ADDR=.*|CA_BIND_ADDR=$C_ADDR|" -e 's|^CA_TLS_HOSTS=.*|CA_TLS_HOSTS=radsec-ca|' \
		-e "s|^CA_ACCESS_TEAM_DOMAIN=.*|CA_ACCESS_TEAM_DOMAIN=$OSSBSS_ACCESS_TEAM_DOMAIN|" -e 's|^CA_ACCESS_AUD=.*|CA_ACCESS_AUD=stage4-unused|' \
		-e "s|^CA_INITIAL_ADMIN_EMAIL=.*|CA_INITIAL_ADMIN_EMAIL=$ADMIN_EMAIL|" .env
	cat >> .env << ENV
COMPOSE_PROJECT_NAME=s4ca
COMPOSE_FILE=compose.yaml:compose.managed.yaml:compose.fluent-bit.yaml:$T/compose.ca.yaml
CA_VERSION=s4
PROVISIONER_FLUENT_BIT_PORT=24225
CA_MERAKI_API_BASE=https://fake-dashboard:8443/api/v1
S4_FAKE_DIR=$W/fake
S4_FAKE_API_KEY=$FAKE_API_KEY
ENV
	sudo chown -R 65532:65532 secrets audit
	sudo chmod 600 secrets/kek secrets/admin-clients
	sudo chmod 750 audit
	cc up -d --no-build --wait --wait-timeout 120 radsec-ca fake-dashboard || exit 1
	cc exec -T radsec-ca /radsec-ca server-cert | sudo tee "$P/downstreams/ca-admin.pem" > /dev/null
	sudo chown 65532:65532 "$P/downstreams/ca-admin.pem"
	registry

	step "aka-ossbss を起動する"
	cd "$O" || exit 1
	pc exec -T aka-provisioner /aka-provisioner server-cert > certs/provisioner-server.pem
	sudo chown -R 65532:65532 secrets certs audit
	sudo chmod 600 secrets/kek secrets/tunnel-token certs/provisioner-client.pem certs/provisioner-server.pem
	oc run --rm --no-deps aka-ossbss check-provisioner 2>&1 | grep -v -E 'Container|Network|Volume' | tee "$OUT/check-provisioner.txt"
	check I3 "aka-ossbss の check-provisioner がつながる" "$(grep -q '接続できました' "$OUT/check-provisioner.txt"; echo $?)"
	oc up -d --no-build --wait --wait-timeout 180 || exit 1
	oc up -d --no-build cloudflared
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

# registry [<ID>=<URL>=<フィンガープリント>...]: aka-provisioner の登録簿を書いて読み直させる（運用ガイド 3.5・3.6。その場で書き換える）
registry() {
	python3 -I - "$@" << 'PY' | sudo tee "$P/downstreams/downstreams.json" > /dev/null
import json, sys
doc = {"clientCert": "client.pem", "clientKey": "client.pem",
       "vecgen": {"url": "https://aka-vecgen:9443/admin/v2", "serverCert": "vecgen-admin.pem"},
       "radius": {"url": "https://aka-radius-admin:9444/admin/v2", "serverCert": "radius-admin.pem"},
       "ca": {"url": "https://radsec-ca:9448", "serverCert": "ca-admin.pem"}}
edges = [dict(zip(("id", "url", "serverFingerprint"), a.split("="))) for a in sys.argv[1:]]
if edges:
    doc["edges"] = edges
print(json.dumps(doc, indent=2))
PY
	pc kill -s HUP aka-provisioner > /dev/null
	sleep 2
}

# ---------------------------------------------------------------- エッジ（docker:dind の中。radsec-edge の運用ガイド 10 章のとおり）
D() { docker exec -i "$EDGE" "$@"; }
# edge_setup <ID> <公開するアドレス> <上流のシークレット> <aka-provisioner のピンの行>
edge_setup() {
	EDGE=$1
	local addr=$2 secret=$3 pin=$4
	docker network inspect s4edge > /dev/null 2>&1 || docker network create --subnet 172.31.94.0/24 s4edge > /dev/null
	docker rm -f "$EDGE" > /dev/null 2>&1
	# ホストの Docker の設定は変えず、dind の dockerd に userland-proxy オフと live-restore を渡す（決定事項 27）。
	docker run -d --privileged --name "$EDGE" --hostname "$EDGE" --network s4edge --ip 172.31.94.2 -e DOCKER_TLS_CERTDIR= \
		-p "$addr:9447:9447" -p "$addr:20000-20009:20000-20009" --entrypoint sh "$DIND_IMAGE" \
		-c 'while :; do dind dockerd --host=unix:///var/run/docker.sock --userland-proxy=false --live-restore >>/var/log/dockerd.log 2>&1; sleep 1; done' > /dev/null
	for _ in $(seq 60); do D docker info > /dev/null 2>&1 && break; sleep 1; done
	D docker load -q < "$W/edge-images.tar"
	D mkdir -p /edge
	tar -C "$W/edge" -cf - . | D tar -xf - -C /edge
	local gid
	gid=$(D stat -c %g /var/run/docker.sock)
	D sh -s << SH
set -e
cd /edge
cp .env.example .env
chmod 600 .env
sed -i -e 's|^EDGE_DOCKER_GID=.*|EDGE_DOCKER_GID=$gid|' -e 's|^EDGE_URN_PREFIX=.*|EDGE_URN_PREFIX=$URN_PREFIX|' -e 's|^EDGE_DNS_DOMAIN=.*|EDGE_DNS_DOMAIN=$DNS_DOMAIN|' \
  -e 's|^EDGE_UPSTREAM_SECRET=.*|EDGE_UPSTREAM_SECRET=$secret|' -e 's|^EDGE_CRL_BASE_URL=.*|EDGE_CRL_BASE_URL=http://$C_ADDR:8449|' \
  -e 's|^EDGE_ACCESS_TEAM_DOMAIN=.*|EDGE_ACCESS_TEAM_DOMAIN=$OSSBSS_ACCESS_TEAM_DOMAIN|' -e 's|^EDGE_ACCESS_AUD=.*|EDGE_ACCESS_AUD=stage4-unused|' .env
cat >> .env << ENV
COMPOSE_PROJECT_NAME=radsec-edge
COMPOSE_FILE=compose.yaml:compose.managed.yaml:compose.fluent-bit.yaml
EDGE_VERSION=s4
EDGE_BIND_ADDR=0.0.0.0
EDGE_TLS_HOSTS=$addr
EDGE_FLUENT_BIT_PORT=24224
ENV
install -d -o 10084 -g 10083 -m 0750 /var/lib/radsec-edge/data /var/lib/radsec-edge/tenants /var/lib/radsec-edge/audit
install -d -m 0755 /var/lib/radsec-edge/logs
mkdir -p secrets
: > secrets/tunnel-token
chmod 644 secrets/tunnel-token
echo '$pin' > secrets/admin-clients
chown 10084 secrets/admin-clients
chmod 400 secrets/admin-clients
docker compose up -d --no-build --wait --wait-timeout 120 radsec-edge radsec-edge-agent fluent-bit
SH
	D sh -c 'cd /edge && docker compose exec -T radsec-edge /radsec-edge server-cert 2> /dev/null' | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2
}
dc() { D sh -c "cd /edge && docker compose $*"; }

# ---------------------------------------------------------------- AP の役（radsecproxy。UDP で eapaka_test から受け、RadSec でエッジへ。名前は実物の DNS で引く）
# ap_up <名前> <UDP のポート> <slug> <テナントのポート> <証明書> <鍵> [偽の刻印の値（なしは -）] [スロット（既定 primary,secondary）]
ap_up() {
	local name=$1 port=$2 slug=$3 tport=$4 cert=$5 key=$6 fake=${7:--} slots=${8:-primary,secondary} s
	{
		echo "ListenUDP *:1812"
		echo "ListenUDP *:1813"
		echo "LogLevel 3"
		printf 'tls default {\n    CACertificateFile /ap/server-ca.pem\n    CertificateFile /ap/%s\n    CertificateKeyFile /ap/%s\n}\n' "$cert" "$key"
		if [ "$fake" != - ]; then
			printf "rewrite fake {\n    addVendorAttribute 32473:1:'%s\n}\n" "$fake"
			printf 'client local {\n    type udp\n    host 0.0.0.0/0\n    secret ap-secret-0123456789\n    rewriteIn fake\n}\n'
		else
			printf 'client local {\n    type udp\n    host 0.0.0.0/0\n    secret ap-secret-0123456789\n}\n'
		fi
		for s in ${slots//,/ }; do
			printf 'server %s {\n    type tls\n    host %s.%s.%s\n    port %s\n    secret radsec\n    tls default\n    certificateNameCheck on\n}\n' "$s" "$s" "$slug" "$DNS_DOMAIN" "$tport"
		done
		echo "realm * {"
		for s in ${slots//,/ }; do echo "    server $s"; done
		for s in ${slots//,/ }; do echo "    accountingServer $s"; done
		echo "}"
	} > "$AP/$name.conf"
	docker rm -f "ap-$name" > /dev/null 2>&1
	docker run -d --name "ap-$name" -p "127.0.0.1:$port:1812/udp" -p "127.0.0.1:$((port + 1)):1813/udp" -v "$AP:/ap:ro" stage2-tools:dev \
		radsecproxy -f -c "/ap/$name.conf" > /dev/null
	for _ in $(seq 30); do
		docker logs "ap-$name" 2>&1 | grep -q 'TLS connection to' && break
		sleep 1
	done
	docker logs "ap-$name" 2>&1 | grep -E 'TLS connection to|tlsconnect|verify' | tail -2
}
cfg() { # <IMSI> <ポート> <SQN の初期値> <SQN の保存ファイル> <SSID>
	local f=$OUT/cfg-$1-$2-$3-$5.yaml
	cat > "$f" << YAML
radius:
  server_addr: "127.0.0.1:$2"
  secret: "ap-secret-0123456789"
  timeout_ms: 4000
  retries: 2
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
YAML
	echo "$f"
}
# eaprun <IMSI> <aka|prime> <accept|reject> <ポート> [SSID] [SQN の初期値]: 最後の行に終了コードを出す
eaprun() {
	local imsi=$1 method=$2 expect=$3 port=$4 ssid=${5:-ssid1} sqn=${6:-000000000000} prefix=0 r
	[ "$method" = prime ] && prefix=6
	local name=$imsi-$method-$port-$$
	cat > "$OUT/case-$name.yaml" << YAML
version: 1
name: $name
identity: "$prefix$imsi@$REALM"
expect:
  result: $expect
trace:
  level: verbose
YAML
	"$T/eapaka_test" -c "$(cfg "$imsi" "$port" "$sqn" "$OUT/sqn-$imsi-$sqn.json" "$ssid")" --trace-radius-attrs run "$OUT/case-$name.yaml" > "$OUT/eap-$name.log" 2>&1
	r=$?
	echo "log=$OUT/eap-$name.log"
	grep -iE 'timeout|timed out|result|nas' "$OUT/eap-$name.log" | tail -2
	echo "rc=$r"
}
# tls_try <名前> <ポート> <証明書> <鍵> [チェーン]: 手順書の 4.5 のとおり openssl で試す。サーバー証明書の検証の結果を出す
tls_try() {
	local name=$1 port=$2 cert=$3 key=$4 chain=${5:-} opt=()
	[ -n "$chain" ] && opt=(-cert_chain "$AP/$chain")
	(sleep 1.5) | timeout 6 openssl s_client -connect "$name:$port" -CAfile "$AP/server-ca.pem" -verify_hostname "$name" -cert "$AP/$cert" -key "$AP/$key" "${opt[@]}" 2>&1 |
		grep -E 'Verify return code|Verification' | head -2
	true
}
edge_logs() { # <エッジ> <slug> <秒前から>
	docker exec "$1" docker logs --since "$(($(date +%s) - $3))" "radsecproxy-$2" 2>&1
}
log_count() { # <event_id> <IMSI>: aka-radius の auth のログの行の数
	rc logs --no-color auth 2> /dev/null | grep -c "\"event_id\":\"$1\".*$2"
}
wait_applied() { # <テナント> <秒>: 全配置が求めた版に届いて ok になるまで待つ
	local i n
	for i in $(seq "$2"); do
		n=$(sql "SELECT count(*) FROM placements p JOIN tenant_radsec t USING (tenant_id) WHERE p.tenant_id=$1 AND p.deleted_at IS NULL AND (p.applied_revision = 0 OR p.applied_revision < t.requested_revision OR p.apply_result <> 'ok')")
		[ "$n" = 0 ] && { echo "applied after ${i}s"; return 0; }
		sleep 1
	done
	sql "SELECT edge_id, slot, applied_revision, apply_result, apply_error FROM placements WHERE tenant_id=$1 AND deleted_at IS NULL"
	return 1
}
acct_send() { # <AP> <種類> <時間> <受信> <受信の Gigawords> <送信> <IMSI> <Class> <ポート>
	printf 'Acct-Status-Type = %s\nAcct-Session-Id = "s4-acct-1"\nUser-Name = "0%s@%s"\nNAS-Identifier = "ap-01"\nClass = "%s"\nAcct-Session-Time = %s\nAcct-Input-Octets = %s\nAcct-Input-Gigawords = %s\nAcct-Output-Octets = %s\n' \
		"$2" "$7" $REALM "$8" "$3" "$4" "$5" "$6" |
		docker exec -i "ap-$1" radclient -r 2 -t 5 127.0.0.1:1813 acct ap-secret-0123456789 2>&1
}

# src_try <送信元> <名前> <ポート> <証明書> <鍵>: dind と同じネットワークのコンテナから edge-01 へつなぐ（送信元の範囲の確かめ）
src_try() {
	docker run --rm --network s4edge --ip "$1" --add-host "$2:172.31.94.2" -v "$AP:/ap:ro" --entrypoint sh "$DIND_IMAGE" -c \
		"(sleep 1.5) | timeout 6 openssl s_client -connect $2:$3 -CAfile /ap/server-ca.pem -cert /ap/$4 -key /ap/$5 2>&1 | grep -E 'Verify return code' | head -1; true"
}
# order_watch <テナント> <秒>: 配置の反映の版を 1 秒ごとに読み、順を確かめる
order_watch() {
	local want bad=0 seen=0 i line p s
	want=$(sql "SELECT requested_revision FROM tenant_radsec WHERE tenant_id=$1")
	for i in $(seq "$2"); do
		line=$(sql "SELECT string_agg(applied_revision::text, ' ' ORDER BY slot) FROM placements WHERE tenant_id=$1 AND deleted_at IS NULL")
		read -r p s <<< "$line"
		[ "$s" -ge "$want" ] && [ "$p" -lt "$want" ] && bad=1
		[ "$p" -ge "$want" ] && [ "$s" -lt "$want" ] && seen=1
		[ "$p" -ge "$want" ] && [ "$s" -ge "$want" ] && break
		sleep 1
	done
	echo "want=$want primary=$p secondary=$s seen-first-only=$seen after ${i}s"
	if [ "$bad" = 0 ] && [ "$p" -ge "$want" ] && [ "$s" -ge "$want" ]; then echo "order=ok"; else echo "order=ng"; fi
}
set_ossbss_env() { # <名前> <値>
	(cd "$O" && { grep -q "^$1=" .env && sed -i "s|^$1=.*|$1=$2|" .env || echo "$1=$2" >> .env; })
	oc up -d --no-build --wait --wait-timeout 180 aka-ossbss 2>&1 | tail -1
}

# ずれを作る（エッジの管理API を直接呼ぶ）。drift_decl は宣言の版を変えて送信元の範囲を足す。
drift_decl() { # <エッジ> <テナント>: 詳細の応答には CA の本体がないので、台帳の CA の証明書で組み立てる（持ち込みの CA のないテナントだけ）
	local b
	sql "SELECT ca_certificate FROM tenant_radsec WHERE tenant_id=$2" > "$OUT/drift-ca.pem"
	b=$(eapi "$1" GET "/tenants/$2" | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
open(sys.argv[1],"w").write(str(d["revision"]))
print(json.dumps({"revision":9999,"slug":d["slug"],"port":d["port"],"authUpstream":d["authUpstream"],"acctUpstream":d["acctUpstream"],
  "clientCas":[{"id":"tenant."+d["slug"],"kind":"issued","certificate":open(sys.argv[2]).read(),"hasCrl":True}],
  "sourceCidrs":["192.0.2.0/24"],"aps":[{k:a[k] for k in a if k!="nasId"} for a in d["aps"]]}))' "$OUT/drift-rev" "$OUT/drift-ca.pem")
	eapi "$1" PUT "/tenants/$2" "$b" | json 'str(d.get("revision"))+" "+str(d.get("sourceCidrs"))+" "+str(d.get("pending"))+" "+str(d.get("detail") or "")'
}
wait_decl() { # <エッジ> <テナント> <秒>
	local i s want
	want=$(cat "$OUT/drift-rev")
	for i in $(seq "$3"); do
		s=$(eapi "$1" GET "/tenants/$2" | json 'str(d.get("revision"))+" "+str(d.get("sourceCidrs"))')
		case $s in "$want "*) if ! echo "$s" | grep -q 192.0.2; then echo "ok ${i}s $s"; return 0; fi ;; esac
		sleep 1
	done
	echo "ng $s"
}
drift_orphan() { # <エッジ>
	local b
	b=$(python3 -I -c 'import json,sys
print(json.dumps({"revision":1,"slug":"orphan99","port":20009,"authUpstream":"192.0.2.1:1812","acctUpstream":"192.0.2.1:1813","clientCas":[{"id":"tenant.orphan99","kind":"issued","certificate":open(sys.argv[1]).read(),"hasCrl":True}],"aps":[]}))' "$AP/server-ca.pem")
	eapi "$1" PUT /tenants/99 "$b" | json '"orphan", d.get("revision")'
}
# edge_wipe <エッジ>: データとテナントのコンテナを失った形にして起動し直し、新しいフィンガープリントを出す
edge_wipe() {
	EDGE=$1
	D sh -s << 'SH'
cd /edge
docker compose stop radsec-edge radsec-edge-agent
docker ps -aq --filter label=radsec-edge.tenant | xargs -r docker rm -f
rm -rf /var/lib/radsec-edge/data/* /var/lib/radsec-edge/tenants/*
docker compose up -d --no-build --wait --wait-timeout 120 radsec-edge radsec-edge-agent
SH
	D sh -c 'cd /edge && docker compose exec -T radsec-edge /radsec-edge server-cert 2> /dev/null' | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2
}
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
	sql "CREATE TABLE IF NOT EXISTS usage_daily_202610 PARTITION OF usage_daily FOR VALUES FROM ('2026-10-01') TO ('2026-11-01')"
	sql "UPDATE usage_daily SET date='2026-10-15' WHERE date >= '2026-10-01'"
	sql "UPDATE charging_events SET time='2026-10-15 12:00:00+09'"
	sql "INSERT INTO usage_import_days (date, attempted_at, imported_at, last_error) SELECT d::date, now(), now(), '' FROM generate_series('2026-10-01'::date, '2026-10-31'::date, '1 day') d ON CONFLICT (date) DO NOTHING"
	# 今の行は 10 月の中に作ったことにし、もう消した行は 10 月の中に消したことにする。外し終えた配置は月末に数えない
	for t in aps brought_cas placements; do
		sql "UPDATE $t SET deleted_at='2026-10-20 12:00:00+09' WHERE deleted_at IS NOT NULL"
		sql "UPDATE $t SET created_at='2026-10-15 12:00:00+09'"
	done
	sql "SELECT count(*) FROM charging_events; SELECT count(*) FROM usage_daily"
}
ossbss_logs() { sudo sh -c "cat $P/logs_on_host/ossbss.log" 2> /dev/null; }
logs_check() {
	local ev n missing=""
	for ev in RADSEC_APPLY_FAILED RADSEC_EDGE_UNREACHABLE RADSEC_EDGE_REACHABLE RADSEC_ORPHAN_TENANT; do
		n=$(ossbss_logs | grep -c "\"event_id\":\"$ev\"")
		echo "$ev $n"
		[ "$n" -gt 0 ] || missing="$missing $ev"
	done
	check L1 "aka-ossbss のログ（Fluent Bit のファイル）に RADSEC_* が出る${missing:+ ない:$missing}" "$(ok -z "$missing")"
	n=$(sql "SELECT count(*) FROM audit_log WHERE actor_email='system' AND action LIKE 'radsec.%' AND trace_id LIKE 'radsec-%'")
	check L2 "ループの操作が監査ログに操作者 system・トレース radsec-* で残る（$n）" "$(ok "$n" -gt 0)"
	sql "SELECT action, count(*) FROM audit_log WHERE action LIKE 'radsec.%' GROUP BY action ORDER BY action" | tr '\n' ' '; echo
	missing=""
	for ev in radsec.enable radsec.ap.create radsec.ap.revoke radsec.ap.delete radsec.brought.create radsec.brought.crl_refresh radsec.sources radsec.apply radsec.apply.retry radsec.placement.move radsec.placement.move_finish radsec.edge.orphan_delete radsec.declare radsec.apply.result radsec.cert.place radsec.cert.revoke; do
		[ "$(sql "SELECT count(*) FROM audit_log WHERE action='$ev'")" -gt 0 ] || missing="$missing $ev"
	done
	check L3 "画面とループの操作の監査ログがそろう${missing:+ ない:$missing}" "$(ok -z "$missing")"
	missing=""
	sudo test -s "$P/logs_on_host/radsec-ca.log" || missing=" radsec-ca.log"
	sudo sh -c "ls $CA/audit/audit-*.jsonl > /dev/null 2>&1" || missing="$missing ca-audit"
	check L4 "radsec-ca のログと監査ログのファイルがある${missing:+ ない:$missing}" "$(ok -z "$missing")"
	# 秘密の値が残らないこと
	oc exec -T postgres pg_dump -U ossbss ossbss > "$OUT/ossbss.sql"
	local hits=""
	grep -q -e "$FAKE_API_KEY" "$OUT/ossbss.sql" && hits="$hits db"
	sudo sh -c "grep -l -r -e '$FAKE_API_KEY' $O/audit $P/audit $P/logs_on_host $CA/audit 2> /dev/null" | sed 's/^/hit: /'
	sudo sh -c "grep -q -r -e '$FAKE_API_KEY' $O/audit $P/audit $P/logs_on_host $CA/audit 2> /dev/null" && hits="$hits files"
	docker run --rm -v s4ca_ca-data:/d:ro busybox:1.37.0 sh -c "grep -q -r -e '$FAKE_API_KEY' /d" && hits="$hits ca-db"
	check L5 "Meraki の API キーが aka-ossbss の DB・ログ・監査ログ・radsec-ca の DB の平文に残らない${hits:+ 残る:$hits}" "$(ok -z "$hits")"
	rm -f "$OUT/ossbss.sql"
	hits=""
	sudo sh -c "grep -q -r -e $KI -e $OPC $O/audit $P/audit $P/logs_on_host $R/logs_on_host $V/audit $R/audit 2> /dev/null" && hits=" 残る"
	check L6 "Ki・OPc がログと監査ログに残らない$hits" "$(ok -z "$hits")"
}
edge_logs_check() { # <エッジ> <slug>
	local missing=""
	EDGE=$1
	D sh -c "grep -q 'client ' /var/lib/radsec-edge/logs/radsecproxy.log" || missing=" radsecproxy.log"
	D sh -c "grep -q 'radsecproxy-$2' /var/lib/radsec-edge/logs/radsecproxy.log" || missing="$missing container"
	D sh -c "grep -q 'management API\|request completed' /var/lib/radsec-edge/logs/radsec-edge.log" || missing="$missing radsec-edge.log"
	D sh -c "ls /var/lib/radsec-edge/audit/audit-*.jsonl > /dev/null" || missing="$missing audit"
	D sh -c "grep -q -e '$FAKE_API_KEY' -r /var/lib/radsec-edge/logs /var/lib/radsec-edge/audit" && missing="$missing api-key"
	check "L7${1##*-}" "$1 の Fluent Bit のファイル（テナントのコンテナと radsec-edge）と監査ログがある${missing:+ 問題:$missing}" "$(ok -z "$missing")"
	check "L8${1##*-}" "$1 のテナントのコンテナのログドライバーが fluentd" "$(ok "$(D docker inspect -f '{{.HostConfig.LogConfig.Type}}' "radsecproxy-$2")" = fluentd)"
}

cmd=${1:?usage: stage4.sh <サブコマンド>}
shift
case $cmd in
setup-central) setup_central ;;
edge-setup) edge_setup "$@" ;;
registry) registry "$@" ;;
client-add) # <IP> <名前> <シークレット>
	echo "$3" | rc exec -T admin aka-radius client add -ip "$1" -name "$2" -trust-stamp true -operator stage4 ;;
check-downstream) pc exec -T aka-provisioner /aka-provisioner check-downstream ;;
sql) sql "$1" ;;
mark) check "$@" ;;
ap-up) ap_up "$@" ;;
ap-rm) docker rm -f "ap-$1" > /dev/null ;;
ap-restart) docker restart "ap-$1" > /dev/null; sleep 8; docker logs --tail 5 "ap-$1" 2>&1 | grep -E 'TLS connection to|verify' | tail -2 ;;
eap) eaprun "$@" ;;
tls-try) tls_try "$@" ;;
edge-logs) edge_logs "$@" ;;
log-count) log_count "$@" ;;
wait-applied) wait_applied "$@" ;;
acct) acct_send "$@" ;;
dapi) dapi "$@" ;;
eapi) eapi "$@" ;;
dind) docker exec -i "$1" "${@:2}" ;;
src-try) src_try "$@" ;;
order-watch) order_watch "$@" ;;
set-ossbss-env) set_ossbss_env "$@" ;;
stop) "$1" stop "${@:2}" ;;
start) "$1" up -d --no-build "${@:2}" ;;
drift-decl) drift_decl "$@" ;;
wait-decl) wait_decl "$@" ;;
drift-orphan) drift_orphan "$@" ;;
edge-wipe) edge_wipe "$@" ;;
usage-yesterday) usage_yesterday ;;
shift-month) shift_month ;;
role) sql "UPDATE accounts SET role='$1', tenant_id=$2, disabled=${3:-false} WHERE email='$ADMIN_EMAIL'" ;;
ossbss-log-count) ossbss_logs | grep -c "\"event_id\":\"$1\"" ;;
logs-check) logs_check ;;
edge-logs-check) edge_logs_check "$@" ;;
ps) for f in vc rc pc cc oc; do $f ps --format '{{.Service}} {{.Status}}'; done ;;
*)
	echo "unknown: $cmd" >&2
	exit 2
	;;
esac
