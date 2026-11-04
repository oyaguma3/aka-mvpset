#!/usr/bin/env bash
# 外形監視（docs/deployment.md §9.4、確認事項 S5-12）。
#   probe.sh conf  probe.env から radsecproxy の設定を作る（conf/primary.conf・secondary.conf）
#   probe.sh run   各スロットへ EAP-AKA を 1 回ずつ通し、/var/lib/aka-textfile/probe.prom に書く（aka-probe.timer が 1 分ごと）
# conf/ に AP の証明書（ap.pem・ap.key。radsec-ca が発行）とサーバーCA（server-ca.pem）を置き、radsecproxy（nobody）が読めるよう
# chown -R 65534:65534 conf にする。
set -uo pipefail
D=/opt/aka-probe
. "$D/probe.env"
state=/var/lib/aka-probe
mkdir -p "$state"

conf() {
	local slot
	for slot in primary secondary; do
		cat > "$D/conf/$slot.conf" << CONF
# probe.sh conf が作った（$slot）
ListenUDP *:1812
LogLevel 3
tls default {
    CACertificateFile /probe/conf/server-ca.pem
    CertificateFile /probe/conf/ap.pem
    CertificateKeyFile /probe/conf/ap.key
}
client local {
    type udp
    host 0.0.0.0/0
    secret probe-local-secret
}
server $slot {
    type tls
    host $slot.$SLUG.$DNS_DOMAIN
    port $TENANT_PORT
    secret radsec
    tls default
    certificateNameCheck on
}
realm * {
    server $slot
}
CONF
	done
	echo "作った: $D/conf/primary.conf secondary.conf"
}

one() { # <スロット> <UDP のポート>
	local slot=$1 port=$2 cfg=$state/cfg-$1.yaml casef=$state/case.yaml
	cat > "$cfg" << YAML
radius:
  server_addr: "127.0.0.1:$port"
  secret: "probe-local-secret"
  timeout_ms: 5000
  retries: 1
radius_attrs:
  nas_ip_address: "192.0.2.10"
  nas_identifier: "$SLUG-$AP_NAME"
  called_station_id: "00-11-22-33-44-55:$SSID"
  calling_station_id: "02-00-00-00-00-01"
eap:
  method_mismatch_policy: "warn"
  outer_identity_update_on_permanent_req: true
  permanent_id_policy: "always"
identity:
  realm: "$REALM"
sim:
  imsi: "$IMSI"
  ki: "$KI"
  opc: "$OPC"
  amf: "8000"
  sqn_initial_hex: "000000000000"
sqn_store:
  mode: "file"
  path: "$state/sqn.json"
YAML
	cat > "$casef" << YAML
version: 1
name: probe
identity: "0$IMSI@$REALM"
expect:
  result: accept
YAML
	chmod 600 "$cfg"
	timeout 30 /usr/local/bin/eapaka_test -c "$cfg" run "$casef" > "$state/last-$slot.log" 2>&1
}

run() {
	local slot port t0 t1 ok fails now
	local tmp
	tmp=$(mktemp /var/lib/aka-textfile/.probe.XXXXXX)
	{
		echo "# HELP aka_probe_success 外形監視の最後の結果（1 が成功）"
		echo "# TYPE aka_probe_success gauge"
		echo "# HELP aka_probe_duration_seconds 外形監視の 1 回の時間"
		echo "# TYPE aka_probe_duration_seconds gauge"
		echo "# HELP aka_probe_consecutive_failures 外形監視の続けての失敗の数"
		echo "# TYPE aka_probe_consecutive_failures gauge"
		echo "# HELP aka_probe_last_run_seconds 外形監視を最後に動かした時刻"
		echo "# TYPE aka_probe_last_run_seconds gauge"
		for x in primary:18121 secondary:18131; do
			slot=${x%%:*} port=${x##*:}
			t0=$(date +%s.%N)
			if one "$slot" "$port"; then ok=1; else ok=0; fi
			t1=$(date +%s.%N)
			fails=$(cat "$state/fails-$slot" 2> /dev/null || echo 0)
			if [ $ok = 1 ]; then fails=0; else fails=$((fails + 1)); fi
			echo "$fails" > "$state/fails-$slot"
			now=$(date +%s)
			echo "aka_probe_success{slot=\"$slot\"} $ok"
			echo "aka_probe_duration_seconds{slot=\"$slot\"} $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
			echo "aka_probe_consecutive_failures{slot=\"$slot\"} $fails"
			echo "aka_probe_last_run_seconds{slot=\"$slot\"} $now"
		done
	} > "$tmp"
	chmod 644 "$tmp"
	mv "$tmp" /var/lib/aka-textfile/probe.prom
}

case ${1:-} in
conf) conf ;;
run) run ;;
*) echo "使い方: probe.sh conf|run" >&2; exit 2 ;;
esac
