#!/bin/bash
# 段階 2 の終わりの通し（aka-radius の設計概要 §17.1 の 2-6、確認事項 M7）。
# 検証機の作業場所（README の「配置」）の tools/ で動かす。結果は results.tsv と、標準出力の表。
#
#   cd ~/aka-work/stage2/tools && ./stage2.sh
set -uo pipefail

T=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$T/.." && pwd)
V=$W/vecgen
R=$W/radius/deployments
P=$W/pki
OUT=$W/out
mkdir -p "$P" "$OUT"
RESULTS=$W/results.tsv
: > "$RESULTS"

vc() { (cd "$V" && docker compose -p s2vecgen -f compose.yaml -f compose.fluent-bit.yaml -f "$T/compose.vecgen.yaml" "$@"); }
rc() { (cd "$R" && docker compose -p s2radius -f docker-compose.yml -f docker-compose.aka-av.yml -f "$T/compose.radius.yaml" "$@"); }
api() { # <メソッド> <パス> [本文]
	curl -sS --cacert "$R/certs/admin/server.pem" --cert "$P/prov.pem" --key "$P/prov.key" \
		-H X-Operator-Id:stage2 -H Content-Type:application/json -X "$1" "https://localhost:9444/admin/v2$2" ${3:+-d "$3"}
}
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
check() { # <場面> <内容> <0 なら PASS>
	local r=FAIL
	[ "$3" = 0 ] && r=PASS
	printf '%s\t%s\t%s\n' "$1" "$r" "$2" | tee -a "$RESULTS"
}
step() { echo "== $*"; }
# own <ファイルかディレクトリ>...: コンテナ（UID 65532）が読み書きできるようにする。
# 検証機は sudo で chown する。sudo のない手元の試しでは、だれでも読み書きできるようにする（試しの間だけ）
own() {
	if sudo -n true 2> /dev/null; then
		sudo chown -R 65532:65532 "$@"
	else
		chmod -R a+rwX "$@"
	fi
}
secret() { # <ファイル>...: 秘密のファイルを 600 にする（sudo のない手元の試しでは 644 のまま）
	if sudo -n true 2> /dev/null; then sudo chmod 600 "$@"; fi
}
rootcat() { docker run --rm -v "$1":/d:ro valkey/valkey:9.1.2 sh -c "cat /d/$2"; } # <ディレクトリ> <パターン>

KI=465b5ce8b199b49faa5f0a2ee238a6bc
OPC=cd63cb71954a9f4e48a5994e37a02baf
REALM=wlan.mnc010.mcc440.3gppnetwork.org
A=440100000000001 # EAP-AKA の成功・再同期・Accounting（テナント 42）
B=440100000000002 # EAP-AKA' の成功・再同期（テナント 42）
C=440100000000003 # inactive
D=440100000000004 # terminated
E=440100000000005 # aka-vecgen にだけいる（aka-radius にいない）
F=440100000000006 # aka-radius にだけいる（aka-vecgen にいない）
G=440100000000007 # バックアップの後に足す
RULES='[{"tenantId":42,"nasId":"*","ssids":["*"],"vlanId":100,"sessionTimeout":3600}]'

# ---------------------------------------------------------------- 準備
step "aka-vecgen"
cd "$V"
cp .env.example .env
sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD=s2-vecgen-valkey|' .env
mkdir -p secrets audit
openssl rand -hex 32 > secrets/kek
touch secrets/admin-clients
own secrets/kek secrets/admin-clients audit
secret secrets/kek secrets/admin-clients
vc up -d --wait --wait-timeout 120 || exit 1

step "aka-radius の準備"
cd "$R"
cp .env.example .env
sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD=s2-radius-valkey|' .env
mkdir -p sources certs/admin secrets audit backups logs_on_host
cp sources/sources.example.json sources/sources.json
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=aka-radius \
	-addext extendedKeyUsage=clientAuth -keyout sources/vecgen-client.key -out sources/vecgen-client.pem 2> /dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=provisioner \
	-addext extendedKeyUsage=clientAuth -keyout "$P/prov.key" -out "$P/prov.pem" 2> /dev/null
VCLIENT=$(vc exec -T aka-vecgen /aka-vecgen client add -name aka-radius -cert - < sources/vecgen-client.pem)
echo "$VCLIENT"
VCLIENT_ID=$(echo "$VCLIENT" | sed -n 's/^client \([0-9]*\) added.*/\1/p')
VCLIENT_FP=$(echo "$VCLIENT" | sed -n 's/.*fingerprint=\([0-9a-f]*\).*/\1/p')
vc exec -T aka-vecgen /aka-vecgen av-cert > sources/vecgen-av-server.pem
for imsi in $A $B $C $D $E; do
	vc exec -T aka-vecgen /aka-vecgen subscriber add -imsi "$imsi" -ki $KI -opc $OPC -clients "$VCLIENT_ID" > /dev/null
done
touch secrets/admin-clients
echo "provisioner=$(rc run --rm --no-deps -T admin fingerprint < "$P/prov.pem" 2> /dev/null)" > secrets/admin-clients
own sources certs/admin secrets/admin-clients audit
secret sources/vecgen-client.key secrets/admin-clients
rc run --rm --no-deps -v ./certs/admin:/out admin admin-cert create -hosts aka-radius-admin,localhost,127.0.0.1 -out /out -operator stage2
rc up -d --wait --wait-timeout 120 || exit 1
rc ps --format '{{.Service}} {{.Status}}'

step "RADIUS クライアントと加入者"
echo "edge-t42-secret-0123456789" | rc exec -T admin aka-radius client add -ip 172.30.250.42 -name edge-t42 -trust-stamp true -operator stage2
echo "edge-t7-secret-0123456789" | rc exec -T admin aka-radius client add -ip 172.30.250.7 -name edge-t7 -trust-stamp true -operator stage2
echo "ap-direct-secret-0123456789" | rc exec -T admin aka-radius client add -ip 172.30.250.100 -name ap-direct -trust-stamp true -operator stage2
for imsi in $A $B $F; do api POST /subscribers "{\"imsi\":\"$imsi\",\"state\":\"active\",\"sourceId\":\"vecgen\",\"rules\":$RULES}" > /dev/null; done
for imsi in $C $D; do api POST /subscribers "{\"imsi\":\"$imsi\",\"state\":\"inactive\",\"sourceId\":\"vecgen\",\"rules\":$RULES}" > /dev/null; done
api PUT /subscribers/$D/state '{"state":"terminated","reason":"stage2"}' > /dev/null
n=$(api GET /status | json 'd["subscriberCount"], d["clientCount"]')
check S0 "加入者 5・RADIUS クライアント 3（$n）" "$([ "$n" = "5 3" ]; echo $?)"

# ---------------------------------------------------------------- EAP（eapaka_test。エッジの代わりを通す）
# cfg <IMSI> <ポート> <SQN の初期値> <SQN の保存ファイル> → 設定ファイルのパス
cfg() {
	local f=$OUT/cfg-$1-$2-$3.yaml
	cat > "$f" << EOF
radius:
  server_addr: "127.0.0.1:$2"
  secret: "ap-secret-0123456789"
  timeout_ms: 6000
  retries: 1
radius_attrs:
  nas_ip_address: "192.0.2.10"
  nas_identifier: "ap-01"
  called_station_id: "00-11-22-33-44-55:ssid1"
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
# eap <名前> <IMSI> <方式 aka|prime> <期待 accept|reject> [ポート] [SQN の初期値] [SQN の保存ファイル] → 終了コード
eap() {
	local name=$1 imsi=$2 method=$3 expect=$4 port=${5:-11812} sqn=${6:-000000000000} store=${7:-$OUT/sqn-$2.json}
	local prefix=0
	[ "$method" = prime ] && prefix=6
	cat > "$OUT/case-$name.yaml" << EOF
version: 1
name: $name
identity: "$prefix$imsi@$REALM"
expect:
  result: $expect
trace:
  level: verbose
EOF
	"$T/eapaka_test" -c "$(cfg "$imsi" "$port" "$sqn" "$store")" --trace-radius-attrs run "$OUT/case-$name.yaml" > "$OUT/eap-$name.log" 2>&1
}
authlog() { rc logs --no-color auth 2> /dev/null; }
count() { authlog | grep -c "\"event_id\":\"$1\".*$2"; } # <event_id> <IMSI など>

step "EAP-AKA・EAP-AKA' の成功"
eap aka-ok $A aka accept
check E1 "EAP-AKA の成功（テナント 42）" $?
# Accept の属性: Class（25、セッションの ID 36 文字）、Tunnel-Type・Medium-Type・Private-Group-Id（64・65・81）、Session-Timeout（27）
grep -A3 'radius=Access-Accept' "$OUT/eap-aka-ok.log" | grep 'radius_attrs=' | grep -q '25(len=36).*64(len=4),65(len=4),81(len=4),27(len=4)'
check E2 "Accept に Class・VLAN（Tunnel-*）・Session-Timeout" $?
eap prime-ok $B prime accept
check E3 "EAP-AKA' の成功（ネットワーク名 WLAN）" $?

step "再同期"
before=$(count EAP_RESYNC_CHALLENGE $A)
eap aka-resync $A aka accept 11812 00000F000000 "$OUT/sqn-$A-high.json"
r=$?
after=$(count EAP_RESYNC_CHALLENGE $A)
check E4 "EAP-AKA の再同期（UE の SQN を上げる）で成功し、再同期の Challenge が 1 回" "$([ $r = 0 ] && [ $((after - before)) = 1 ]; echo $?)"
before=$(count EAP_RESYNC_CHALLENGE $B)
eap prime-resync $B prime accept 11812 00000F000000 "$OUT/sqn-$B-high.json"
r=$?
after=$(count EAP_RESYNC_CHALLENGE $B)
check E5 "EAP-AKA' の再同期で成功" "$([ $r = 0 ] && [ $((after - before)) = 1 ]; echo $?)"

step "拒否"
vlog() { vc logs --no-color aka-vecgen 2> /dev/null | grep -c "AV_.*$1"; }
v_before="$(vlog $C) $(vlog $D) $(vlog $E)"
eap rej-inactive $C aka reject
check R1 "inactive は拒否（AUTH_SUBSCRIBER_INACTIVE）" "$([ $? = 0 ] && [ "$(count AUTH_SUBSCRIBER_INACTIVE $C)" -ge 1 ]; echo $?)"
eap rej-terminated $D aka reject
check R2 "terminated は拒否（AUTH_SUBSCRIBER_TERMINATED）" "$([ $? = 0 ] && [ "$(count AUTH_SUBSCRIBER_TERMINATED $D)" -ge 1 ]; echo $?)"
eap rej-notfound $E aka reject
check R3 "aka-radius にいない加入者は拒否（AUTH_SUBSCRIBER_NOT_FOUND）" "$([ $? = 0 ] && [ "$(count AUTH_SUBSCRIBER_NOT_FOUND $E)" -ge 1 ]; echo $?)"
check R4 "R1〜R3 では取得先を呼ばない（aka-vecgen の払い出しのログが増えない）" "$([ "$(vlog $C) $(vlog $D) $(vlog $E)" = "$v_before" ]; echo $?)"
eap rej-vecgen $F aka reject
check R5 "aka-vecgen にいない加入者は取得先が断って拒否（VECTOR_REJECTED）" "$([ $? = 0 ] && [ "$(count VECTOR_REJECTED $F)" -ge 1 ]; echo $?)"
eap rej-tenant $A aka reject 21812
check R6 "別のテナント（7）のエッジからは拒否（AUTH_POLICY_DENIED）" "$([ $? = 0 ] && [ "$(count AUTH_POLICY_DENIED $A)" -ge 1 ]; echo $?)"

# radclient で EAP-Response/Identity だけを送る（AP の役のコンテナから）
ident_req() { # <刻印の値（空なら付けない）>
	local id hex len
	id=$(printf '0%s@%s' $A $REALM | od -An -tx1 | tr -d ' \n')
	len=$((5 + ${#id} / 2))
	hex=$(printf '0200%04x01%s' $len "$id")
	printf 'User-Name = "0%s@%s"\nEAP-Message = 0x%s\nMessage-Authenticator = 0x00\nNAS-Identifier = "ap-direct"\n' $A $REALM "$hex"
	if [ -n "$1" ]; then
		printf 'Attr-26 = 0x00007ed901%02x%s\n' $((2 + ${#1})) "$(printf %s "$1" | od -An -tx1 | tr -d ' \n')"
	fi
}
before=$(count AUTH_STAMP_MISSING $A)
ident_req "" | rc exec -T ap radclient -r 1 -t 5 auth:1812 auth ap-direct-secret-0123456789 > "$OUT/direct-nostamp.log" 2>&1
grep -q 'Access-Reject' "$OUT/direct-nostamp.log"
check R7 "エッジを通さない（刻印のない）要求は拒否（AUTH_STAMP_MISSING）" "$([ $? = 0 ] && [ $(($(count AUTH_STAMP_MISSING $A) - before)) = 1 ]; echo $?)"
rc exec -T admin aka-radius client update -ip 172.30.250.100 -trust-stamp false -operator stage2 > /dev/null
ident_req 42 | rc exec -T ap radclient -r 1 -t 5 auth:1812 auth ap-direct-secret-0123456789 > "$OUT/direct-untrusted.log" 2>&1
grep -q 'Access-Reject' "$OUT/direct-untrusted.log"
check R8 "刻印を信頼しないクライアントの刻印は使わずに拒否" "$([ $? = 0 ] && [ $(($(count AUTH_STAMP_MISSING $A) - before)) = 2 ]; echo $?)"

# ---------------------------------------------------------------- Accounting（radclient。エッジの代わりを通す）
step "Accounting"
eap acct-auth $A aka accept
sess=$(api GET "/sessions?imsi=$A" | json '" ".join(i["id"] for i in d["items"])')
SID=${sess%% *}
acct() { # <種類> <時間> <受信> <受信の Gigawords> <送信>
	printf 'Acct-Status-Type = %s\nAcct-Session-Id = "s2-acct-1"\nUser-Name = "0%s@%s"\nNAS-Identifier = "ap-01"\nClass = "%s"\nAcct-Session-Time = %s\nAcct-Input-Octets = %s\nAcct-Input-Gigawords = %s\nAcct-Output-Octets = %s\n' \
		"$1" $A $REALM "$SID" "$2" "$3" "$4" "$5" |
		rc exec -T ap radclient -r 1 -t 5 172.30.250.42:1813 acct ap-secret-0123456789 2>&1
}
acct Start 0 0 0 0 > "$OUT/acct.log"
acct Interim-Update 60 1000 1 500 >> "$OUT/acct.log"
acct Interim-Update 60 1000 1 500 >> "$OUT/acct.log" # 同じ値（増分 0）
acct Stop 90 1500 1 800 >> "$OUT/acct.log"
check A1 "Accounting-Response が 4 つ" "$([ "$(grep -c 'Accounting-Response' "$OUT/acct.log")" = 4 ]; echo $?)"
today=$(TZ=Asia/Tokyo date +%F)
u=$(api GET "/usage?date=$today" | json "[ (i['sessions'],i['seconds'],i['inOctets'],i['outOctets']) for i in d['items'] if i['imsi']=='$A' and i['tenantId']==42 ]")
echo "usage: $u"
check A2 "利用の集計（sessions 1・seconds 90・in 4294968796・out 800）" "$([ "$u" = "[(1, 90, 4294968796, 800)]" ]; echo $?)"
api GET "/sessions?imsi=$A" | json "'$SID' in [i['id'] for i in d['items']]" | grep -q False
check A3 "Stop でセッションが消える" $?

# ---------------------------------------------------------------- 運用
step "運用"
api GET /sources | json "d['items'][0]['clientCertificate']['fingerprint']" | grep -q "^$VCLIENT_FP$"
check O1 "/sources のクライアント証明書のフィンガープリントが aka-vecgen の登録と一致" $?
# この試しでは auth の IP を決めているので、run ではなく動いている auth の中で動かす
rc exec -T auth aka-radius sources check > "$OUT/sources-check.log" 2>&1
check O2 "sources check（本物の aka-vecgen に TLS でつながる）" $?
rc kill -s HUP auth admin > /dev/null 2>&1
sleep 2
check O3 "SIGHUP で auth と admin が登録簿を読み直す" "$([ "$(rc logs --no-color auth admin 2> /dev/null | grep -c SOURCES_RELOADED)" -ge 2 ]; echo $?)"

step "遮断器"
vc stop aka-vecgen > /dev/null 2>&1
for i in 1 2 3 4 5; do eap cb-$i $A aka reject; done
cb() { api GET /status | json "d['sources'][0].get('circuitBreaker',{}).get('state')"; }
check O4 "取得先が止まると遮断器が開く（/status が open）" "$([ "$(cb)" = open ]; echo $?)"
vc start aka-vecgen > /dev/null 2>&1
# 開いてから 30 秒で半開きに移り、auth は 30 秒ごとの報告でそれを書く（報告は最大 30 秒遅れる）
st=open
for i in $(seq 75); do
	st=$(cb)
	[ "$st" = half-open ] && break
	sleep 1
done
check O5 "30 秒で半開きになり、/status に報告される（開いてから ${i} 秒ほど）" "$([ "$st" = half-open ]; echo $?)"
ok=0
for i in 1 2 3; do eap cb-ok-$i $A aka accept || ok=1; done
sleep 1
check O6 "半開きで 3 回成功すると閉じる" "$([ $ok = 0 ] && [ "$(cb)" = closed ]; echo $?)"

step "続けて 20 回"
start=$(date +%s%N)
ok=0
for i in $(seq 20); do eap seq-$i $A aka accept || ok=1; done
ms=$((($(date +%s%N) - start) / 1000000))
check O7 "続けて 20 回の EAP-AKA が成功（計 ${ms} ms、eapaka_test の起動を含む）" $ok

step "再起動とバックアップ"
rc restart valkey auth acct admin > /dev/null 2>&1
rc up -d --wait --wait-timeout 120 > /dev/null 2>&1
eap after-restart $A aka accept
check O8 "Valkey と各サーバーを再起動しても認証できる（AOF）" $?
# スクリプトは素の docker compose を使うので、この試しのプロジェクト名と重ね合わせを渡す
export COMPOSE_PROJECT_NAME=s2radius COMPOSE_FILE="docker-compose.yml:docker-compose.aka-av.yml:$T/compose.radius.yaml"
(cd "$R" && ../scripts/backup-valkey.sh backups/valkey.rdb) > "$OUT/backup.log" 2>&1
api POST /subscribers "{\"imsi\":\"$G\",\"state\":\"active\",\"sourceId\":\"vecgen\",\"rules\":$RULES}" > /dev/null
(cd "$R" && ../scripts/restore-valkey.sh backups/valkey.rdb) > "$OUT/restore.log" 2>&1
unset COMPOSE_PROJECT_NAME COMPOSE_FILE
rc up -d --wait --wait-timeout 120 > /dev/null 2>&1
sleep 2
g=$(api GET /subscribers/$G | json "d.get('status')")
eap after-restore $A aka accept
check O9 "バックアップから戻すと後の加入者は消え、認証は続く" "$([ $? = 0 ] && [ "$g" = 404 ]; echo $?)"

step "ログと監査ログ"
for f in auth acct admin vecgen; do
	[ -s "$R/logs_on_host/$f.log" ] || echo "missing $f.log"
done > "$OUT/logs.txt"
grep -q AV_ISSUED "$R/logs_on_host/vecgen.log"
check O10 "Fluent Bit が auth・acct・admin・aka-vecgen のログをファイルに書く" "$([ $? = 0 ] && [ ! -s "$OUT/logs.txt" ]; echo $?)"
rootcat "$R/audit" 'audit-*.jsonl' > "$OUT/audit.jsonl"
python3 -I -c "
import json,sys
acts={json.loads(l)['action'] for l in open('$OUT/audit.jsonl')}
need={'admin-server-certificate.create','client.create','client.update','subscriber.create','subscriber.state'}
sys.exit(0 if need<=acts else 1)"
check O11 "監査ログの日ごとのファイルにコマンドと管理API の操作" $?
check O12 "auth・acct・admin が healthy" "$([ "$(rc ps --format '{{.Service}} {{.Status}}' | grep -E '^(auth|acct|admin) ' | grep -c healthy)" = 3 ]; echo $?)"

echo
echo "== 結果"
column -t -s "$(printf '\t')" "$RESULTS"
echo "PASS $(grep -c $'\tPASS\t' "$RESULTS") / $(wc -l < "$RESULTS")"
