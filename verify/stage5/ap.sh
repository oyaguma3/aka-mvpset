#!/bin/bash
# 段階 5 の VPS の上の通し（概要 §18.11 の S5-15、確認事項 T5-2・T5-3）の、AP の役の側の部品。
# 検証機の 1 台目（手元の回線の内側）の ~/aka-work/stage5 で動かす。AP の役はインターネット越しにエッジの公開のアドレスへつなぐ。
#
#   ./ap.sh up <名前> <UDP のポート> <証明書> <鍵> <slug> <スロット,...>   radsecproxy（AP の役）を起動する
#   ./ap.sh eap <IMSI> <aka|prime> <accept|reject> <UDP のポート> [SSID]   eapaka_test で EAP を最後まで通す（最後の行が rc=）
#   ./ap.sh tls <名前> <ポート> <証明書> <鍵>                             openssl で TLS を試す（Verify return code を出す）
#   ./ap.sh logs <名前> [秒]                                              AP の役のログ
#   ./ap.sh down                                                          AP の役を全部止める
#
# 公開のリポジトリに置くので、ドメインは書かない（作業場所の site.env の DNS_DOMAIN から読む）。
set -uo pipefail
W=$(cd "$(dirname "$0")" && pwd)
AP=$W/ap
OUT=$W/out
mkdir -p "$AP" "$OUT"
. "$W/site.env"
# 試験の加入者の鍵（段階 4 の通しと同じ試験用の値。試験の環境だけで使い、顧客を収容する前に作り直す。S5-2）
KI=465b5ce8b199b49faa5f0a2ee238a6bc
OPC=cd63cb71954a9f4e48a5994e37a02baf
REALM=wlan.mnc010.mcc440.3gppnetwork.org
IMAGE=stage2-tools:dev

up() {
	local name=$1 port=$2 cert=$3 key=$4 slug=$5 slots=$6 s tport
	tport=$(cat "$AP/port-$slug")
	{
		echo "ListenUDP *:1812"
		echo "ListenUDP *:1813"
		echo "LogLevel 3"
		printf 'tls default {\n    CACertificateFile /ap/server-ca.pem\n    CertificateFile /ap/%s\n    CertificateKeyFile /ap/%s\n}\n' "$cert" "$key"
		printf 'client local {\n    type udp\n    host 0.0.0.0/0\n    secret ap-secret-0123456789\n}\n'
		for s in ${slots//,/ }; do
			printf 'server %s {\n    type tls\n    host %s.%s.%s\n    port %s\n    secret radsec\n    tls default\n    certificateNameCheck on\n}\n' "$s" "$s" "$slug" "$DNS_DOMAIN" "$tport"
		done
		echo "realm * {"
		for s in ${slots//,/ }; do echo "    server $s"; done
		for s in ${slots//,/ }; do echo "    accountingServer $s"; done
		echo "}"
	} > "$AP/$name.conf"
	docker rm -f "s5-ap-$name" > /dev/null 2>&1
	docker run -d --name "s5-ap-$name" -p "127.0.0.1:$port:1812/udp" -p "127.0.0.1:$((port + 1)):1813/udp" -v "$AP:/ap:ro" "$IMAGE" \
		radsecproxy -f -c "/ap/$name.conf" > /dev/null
	for _ in $(seq 30); do
		docker logs "s5-ap-$name" 2>&1 | grep -q 'TLS connection to' && break
		sleep 1
	done
	docker logs "s5-ap-$name" 2>&1 | grep -E 'TLS connection to|tlsconnect|verify' | tail -2
}

cfg() { # <IMSI> <ポート> <SSID>
	local f=$OUT/cfg-$1-$2-$3.yaml
	cat > "$f" << YAML
radius:
  server_addr: "127.0.0.1:$2"
  secret: "ap-secret-0123456789"
  timeout_ms: 4000
  retries: 2
radius_attrs:
  nas_ip_address: "192.0.2.10"
  nas_identifier: "ap-01"
  called_station_id: "00-11-22-33-44-55:$3"
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
  sqn_initial_hex: "000000000000"
sqn_store:
  mode: "file"
  path: "$OUT/sqn-$1.json"
YAML
	echo "$f"
}

eap() {
	local imsi=$1 method=$2 expect=$3 port=$4 ssid=${5:-s5a} prefix=0 r name
	[ "$method" = prime ] && prefix=6
	name=$imsi-$method-$port-$$
	cat > "$OUT/case-$name.yaml" << YAML
version: 1
name: $name
identity: "$prefix$imsi@$REALM"
expect:
  result: $expect
YAML
	"$W/eapaka_test" -c "$(cfg "$imsi" "$port" "$ssid")" run "$OUT/case-$name.yaml" > "$OUT/eap-$name.log" 2>&1
	r=$?
	grep -iE 'timeout|timed out|deadline|result|Access-' "$OUT/eap-$name.log" | tail -2
	echo "rc=$r"
}

tls() {
	(sleep 1.5) | timeout 6 openssl s_client -connect "$1:$2" -CAfile "$AP/server-ca.pem" -verify_hostname "$1" -cert "$AP/$3" -key "$AP/$4" 2>&1 |
		grep -E 'Verify return code|alert|errno' | head -2
	true
}

case ${1:-} in
up) shift; up "$@" ;;
eap) shift; eap "$@" ;;
tls) shift; tls "$@" ;;
logs) docker logs --since "${3:-600}s" "s5-ap-$2" 2>&1 | tail -20 ;;
down) docker ps -aq --filter name=s5-ap- | xargs -r docker rm -f > /dev/null ;;
*) echo "使い方は先頭の説明を見る" >&2; exit 2 ;;
esac
