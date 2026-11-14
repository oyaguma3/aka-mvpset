#!/bin/bash
# 段階 5 の VPS の上の通し（概要 §18.11 の S5-15、確認事項 T5-1〜T5-4）の台本。手元で動かす。
# ノードへは踏み台（監視ノード）を通した SSH（~/aka-deploy/ssh_config）、AP の役は検証機の 1 台目（ap.sh）、画面は playwright-cli。
#
#   WORK=<手元の作業ディレクトリ> ./drive.sh <段>
#
# $WORK/site.env（公開しない）: BASE（aka-ossbss の公開のホスト名）、ADMIN_EMAIL、DNS_DOMAIN、HOME_IP（手元の回線の公開のアドレス）、
# PROBE_IMSI（外形監視の IMSI。別のテナントの IMSI として使う）。段の一覧は README.md。
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
S4=$T/../stage4
: "${WORK:?}"
. "$WORK/site.env"
mkdir -p "$WORK/pki" "$WORK/run"
RES=$WORK/results.tsv
C=simwifi
REMOTE='~/aka-work/stage5'
SSHCFG=$HOME/aka-deploy/ssh_config
# 通しの加入者（テナント s5a）。A1 は AKA と AKA'、A2 は状態の確かめ、AX は登録しない
A1=440109999100001 A2=440109999100002 AX=440109999100009
# AP の役の UDP のポート: 両方のスロット・primary だけ・secondary だけ・失効させる AP
PBOTH=31812 PP=31822 PS=31832 PX=31842

N() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "aka-$1" "${@:2}" < /dev/null; }  # ノードで動かす
Ni() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "aka-$1" "${@:2}"; }             # 標準入力を渡す
APX() { local q="" a; for a in "$@"; do q="$q $(printf '%q' "$a")"; done; ssh "$C" "cd $REMOTE && ./ap.sh$q" < /dev/null; }
mark() { # <場面> <内容> <0 なら PASS>
	local r=FAIL
	[ "$3" = 0 ] && r=PASS
	printf '%s\t%s\t%s\n' "$1" "$r" "$2" | tee -a "$RES"
}
sql() { echo "$1" | Ni mgmt 'cd /opt/aka-ossbss && docker compose exec -T postgres psql -U ossbss -d ossbss -At -v ON_ERROR_STOP=1'; }
PW() { (cd "$WORK" && timeout 120 playwright-cli -s=stage5 "$@" < /dev/null); }
# W <METHOD> <パス> [名前=値 | 名前=@ファイル]...: 画面の要求を Cloudflare 越しに送る（段階 4 の部品）。状態の番号を WS に
W() {
	local f=$WORK/run-http.js
	python3 -I "$S4/web.py" build "$@" > "$WORK/req.b64" || return 1
	python3 -I - "$S4/ui/http.js" "$f" "$BASE" "$WORK/req.b64" << 'PY'
import sys
src, dst, base, req = sys.argv[1:]
s = open(src, encoding="utf-8").read().replace("__BASE__", base).replace("__A1__", open(req).read().strip())
open(dst, "w", encoding="utf-8").write(s)
PY
	WS=$(PW --raw run-code --filename=run-http.js 2>&1 | python3 -I "$S4/web.py" save "$WORK")
}
uuid() { python3 -I -c 'import uuid; print(uuid.uuid4())'; }
# UI <台本> [引数...]: verify/stage5/ui/<台本>.js を __BASE__・__A1__… を置き換えて動かし、出力をそのまま返す
UI() {
	local name=$1 f="$WORK/run-$1.js"
	shift
	python3 -I - "$T/ui/$name.js" "$f" "$BASE" "$@" << 'PY'
import sys
src, dst, base, *args = sys.argv[1:]
s = open(src, encoding="utf-8").read().replace("__BASE__", base)
for i, a in enumerate(args, 1):
    s = s.replace(f"__A{i}__", a)
open(dst, "w", encoding="utf-8").write(s)
PY
	# 前の台本が登録した確認の小窓の処理がブラウザーに残り、警告の行が混じることがあるので、JSON の文字列の行だけを読む
	PW --raw run-code --filename="run-$name.js" 2>&1 | python3 -I -c '
import json, sys
lines = sys.stdin.read().splitlines()
js = [l for l in lines if l.startswith("\"")]
print(json.loads(js[-1]) if js else "\n".join(lines))'
}
tid() { sql "SELECT id FROM tenants WHERE name='s5a' AND deleted_at IS NULL"; }
# applied <テナント> <秒>: 全部の配置が望む版を反映するまで待つ
applied() {
	local t=$1 n=${2:-300} i r
	for i in $(seq 1 $((n / 5))); do
		r=$(sql "SELECT count(*) FILTER (WHERE p.applied_revision = r.revision AND p.apply_result = 'ok')||'/'||count(*) FROM placements p JOIN tenant_radsec r USING (tenant_id) WHERE p.tenant_id=$t AND p.removed_at IS NULL")
		[ "${r%/*}" = "${r#*/}" ] && [ "${r#*/}" != 0 ] && { echo "反映 $r（$((i * 5)) 秒）"; return 0; }
		sleep 5
	done
	echo "反映が終わらない: $r"
	return 1
}
# radlog <IMSI> <この時刻より後>: aka-radius の auth のログから、その IMSI の event_id・テナント・送信元を出す
radlog() {
	echo "import json,sys,datetime
imsi, since = sys.argv[1], float(sys.argv[2])
for l in open('/opt/aka-radius/deployments/logs_on_host/auth.log'):
    try:
        d = json.loads(l)
        m = json.loads(d['log']) if isinstance(d.get('log'), str) and d['log'].startswith('{') else d
    except Exception:
        continue
    t = m.get('time', '')
    try:
        ts = datetime.datetime.fromisoformat(t).timestamp()
    except Exception:
        continue
    if ts < since or (m.get('imsi') != imsi and m.get('event_id') != 'PKT_RECV'):
        continue
    print(m.get('event_id'), m.get('imsi', '-'), m.get('tenant_id', '-'), m.get('src_ip', '-'))" | Ni data "python3 - $1 $2"
}
# edgelog <エッジ> <この時刻より後> <語>: エッジの radsecproxy のログ（全テナント。s5a の行だけ）
edgelog() {
	N "$1" "python3 -c 'import json,sys,datetime
for l in open(\"/var/lib/radsec-edge/logs/radsecproxy.log\"):
    try: d=json.loads(l)
    except Exception: continue
    if d.get(\"container_name\",\"\").lstrip(\"/\")!=\"radsecproxy-s5a\": continue
    print(d.get(\"log\",\"\"))' | tail -400" | python3 -I -c '
import sys, datetime, re
since = float(sys.argv[1]); word = sys.argv[2]
for l in sys.stdin:
    m = re.match(r"(\w{3} \w{3} +\d+ [\d:]+ \d{4})", l)
    if not m: continue
    ts = datetime.datetime.strptime(m.group(1), "%a %b %d %H:%M:%S %Y").replace(tzinfo=datetime.timezone.utc).timestamp()
    if ts >= since and word in l: print(l.rstrip())' "$2" "$3"
}
# eap <場面> <内容> <IMSI> <aka|prime> <accept|reject|noreply> <ポート> [SSID]
eap() {
	local id=$1 text=$2 imsi=$3 method=$4 expect=$5 port=$6 ssid=${7:-s5a} run=$5 out r
	[ "$expect" = noreply ] && run=accept
	out=$(APX eap "$imsi" "$method" "$run" "$port" "$ssid")
	r=$(echo "$out" | tail -1 | sed 's/^rc=//')
	if [ "$expect" = noreply ]; then
		echo "$out" | grep -qiE 'timeout|timed out|deadline exceeded'
		r=$?
	fi
	[ "$r" = 0 ] || echo "$out" | tail -3
	mark "$id" "$text" "$r"
}
# ③ 150 テナント（T5-7〜T5-10）: 新しく作るテナントの数（probe・s5a と合わせて edge-02 に 150）と edge-02 の公開のアドレス
LN=${LN:-148}
EDGE02=$(sed -n 's/^PUB_edge_02=//p' "$HOME/aka-deploy/inventory.env")
# lstate: 試験のテナント（ld*）の状態（id|name|slug|AP の名前|配置の数）
lstate() {
	sql "SELECT t.id, t.name, coalesce(r.slug, ''), coalesce((SELECT string_agg(a.name, ',' ORDER BY a.name) FROM aps a WHERE a.tenant_id = t.id AND a.deleted_at IS NULL), ''),
		(SELECT count(*) FROM placements p WHERE p.tenant_id = t.id AND p.removed_at IS NULL) FROM tenants t LEFT JOIN tenant_radsec r ON r.tenant_id = t.id
		WHERE t.name LIKE 'ld%' AND t.deleted_at IS NULL ORDER BY t.name"
}
# BULK <要求の JSON>: ui/bulk.js でまとめて送り、結果の JSON を出す
BULK() {
	python3 -I - "$T/ui/bulk.js" "$WORK/run-bulk.js" "$BASE" "$1" << 'PY'
import base64, sys
src, dst, base, req = sys.argv[1:]
s = open(src, encoding="utf-8").read().replace("__BASE__", base).replace("__A1__", base64.b64encode(open(req, "rb").read()).decode())
open(dst, "w", encoding="utf-8").write(s)
PY
	(cd "$WORK" && timeout 1200 playwright-cli -s=stage5 --raw run-code --filename=run-bulk.js < /dev/null 2>&1) | python3 -I -c '
import json, sys
lines = sys.stdin.read().splitlines()
js = [l for l in lines if l.startswith("\"")]
print(json.loads(js[-1]) if js else json.dumps([{"s": -1, "a": "\n".join(lines)[-300:]}]))'
}
dropcount() { N data"sudo nft list chain inet aka published" | awk '/ほかの公開ポート/ {for (i=1;i<=NF;i++) if ($i=="packets") print $(i+1)}'; }

case ${1:-} in
prepare) # AP の役の道具（段階 2 のイメージ）と eapaka_test を検証機に送り、AP の鍵と CSR を検証機で作る
	set -e
	docker build -q -t stage2-tools:dev "$T/../stage2" > /dev/null
	ssh $C "mkdir -p $REMOTE/ap $REMOTE/out && chmod 700 $REMOTE"
	docker save stage2-tools:dev | gzip -1 | ssh $C 'gunzip | docker load' | tail -1
	scp -q "$T/ap.sh" "$HOME/aka-deploy/bin/eapaka_test" "$C:aka-work/stage5/"
	grep -E '^DNS_DOMAIN=' "$WORK/site.env" | ssh $C "umask 077; cat > $REMOTE/site.env"
	for n in ap01 ap02; do
		ssh $C "cd $REMOTE/ap && [ -s $n.key ] || openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $n.key -out $n.csr -subj /CN=ap 2> /dev/null; chmod 644 $n.key; cat $n.csr" > "$WORK/pki/$n.csr"
	done
	ls "$WORK/pki"
	;;
login-start) # Access のログイン画面を開いてメールアドレスを送る（PIN はユーザーから）
	PW open > /dev/null 2>&1
	PW goto "$BASE/" | grep -E 'Page Title'
	UI login "$ADMIN_EMAIL"
	;;
login-pin) # <PIN>
	UI pin "$2"
	;;
setup) # 通しのテナント s5a、加入者、RadSec、配置、AP（画面から）
	UI setup "$A1,$A2" "$(python3 -I -c 'import json,sys; print(json.dumps({n: open(f"{sys.argv[1]}/pki/{n}.csr").read() for n in ("ap01","ap02")}))' "$WORK")" > "$WORK/run/setup.txt"
	cat "$WORK/run/setup.txt" | head -40
	t=$(tid)
	echo "テナント s5a の ID: $t"
	W GET "/tenants/$t/radsec/server-ca.pem"
	cp "$WORK/last.html" "$WORK/pki/server-ca.pem"
	for n in ap01 ap02; do
		row=$(sql "SELECT a.id||' '||c.serial FROM aps a JOIN ap_certs c ON c.ap_id=a.id WHERE a.tenant_id=$t AND a.name='$n' AND a.deleted_at IS NULL ORDER BY c.issued_at DESC LIMIT 1")
		W GET "/tenants/$t/aps/${row%% *}/certs/${row##* }/pem"
		cp "$WORK/last.html" "$WORK/pki/$n.pem"
		openssl x509 -in "$WORK/pki/$n.pem" -noout -subject -ext subjectAltName | tr '\n' ' '
		echo
	done
	port=$(sql "SELECT port FROM tenant_radsec WHERE tenant_id=$t")
	echo "$port" > "$WORK/pki/port-s5a"
	(cd "$WORK/pki" && tar cf - server-ca.pem ap01.pem ap02.pem port-s5a) | ssh $C "tar xf - -C $REMOTE/ap && chmod 644 $REMOTE/ap/*"
	applied "$t" 300
	;;
aps) # AP の役を起動する（両方のスロット・primary だけ・secondary だけ・失効させる AP）
	APX up both $PBOTH ap01.pem ap01.key s5a primary,secondary
	APX up p $PP ap01.pem ap01.key s5a primary
	APX up s $PS ap01.pem ap01.key s5a secondary
	APX up x $PX ap02.pem ap02.key s5a primary,secondary
	;;
dns) # P1: スロットの名前を公開のリゾルバーと AP の役の機械から引く
	: > "$RES"
	for s in primary secondary; do
		e=edge-01
		[ $s = secondary ] && e=edge-02
		a=$(dig +short @1.1.1.1 "$s.s5a.$DNS_DOMAIN" | tr '\n' ' ')
		b=$(ssh $C "getent hosts $s.s5a.$DNS_DOMAIN" | awk '{print $1}')
		mark P1-$s "スロットの名前 $s が $e を指し、公開のリゾルバーと AP の役の機械で引ける（$a/ $b）" "$(echo "$a" | grep -q "$e.$DNS_DOMAIN" && [ -n "$b" ]; echo $?)"
	done
	;;
auth) # B: インターネット越しに 2 台のエッジで EAP-AKA・EAP-AKA'、刻印と本物の RADIUS クライアント、本物の送信元
	t=$(tid)
	t0=$(date +%s)
	eap B1 "EAP-AKA が primary（edge-01）で通る" $A1 aka accept $PP
	eap B2 "EAP-AKA が secondary（edge-02）で通る" $A1 aka accept $PS
	eap B3 "EAP-AKA' が通る（両方のスロットを持つ AP）" $A1 prime accept $PBOTH
	sleep 2
	radlog $A1 "$t0" > "$WORK/run/radlog-auth.txt"
	n=$(grep -c "^AUTH_SUCCESS $A1 $t " "$WORK/run/radlog-auth.txt")
	mark B4 "aka-radius の AUTH_SUCCESS が 3 件、テナントは刻印の s5a（$t）（$n）" "$([ "$n" = 3 ]; echo $?)"
	src=$(grep '^PKT_RECV' "$WORK/run/radlog-auth.txt" | awk '{print $4}' | sort -u | tr '\n' ' ')
	mark B5 "RADIUS はエッジのサービス用の WireGuard のアドレス（登録した RADIUS クライアント）から届く（$src）" "$(echo "$src" | grep -q 10.81.0.11 && echo "$src" | grep -q 10.81.0.12; echo $?)"
	for e in edge-01 edge-02; do
		l=$(edgelog $e "$((t0 - 120))" "TLS connection from" | grep -c "from $HOME_IP, client s5a-ap01")
		mark B6-$e "$e の radsecproxy に、AP の役の本物の送信元（手元の回線の公開のアドレス）で s5a-ap01 の TLS が見える（$l）" "$([ "$l" -gt 0 ]; echo $?)"
	done
	;;
reject) # R: 他のテナントの IMSI、登録のない IMSI、状態による拒否
	t=$(tid)
	eap R1 "別のテナント（probe）の IMSI は s5a の AP から拒否" "$PROBE_IMSI" aka reject $PP
	eap R2 "登録のない IMSI は拒否" $AX aka reject $PP
	;&
state) # R3・R4 だけをやり直すとき
	UI state "$A2" radius inactive > "$WORK/run/state1.txt"
	eap R3 "radius 側を止めた加入者は拒否" $A2 aka reject $PP
	UI state "$A2" radius active > "$WORK/run/state2.txt"
	eap R4 "radius 側を使うに戻すと通る" $A2 aka accept $PP
	;;
source) # S: 送信元の範囲（手元の回線のアドレスで受ける／範囲の外を断る）
	t=$(tid)
	UI sources "$t" "$HOME_IP/32" > "$WORK/run/src1.txt"
	applied "$t" 300
	eap S1 "送信元の範囲を手元の回線のアドレス /32 にしても通る" $A1 aka accept $PP
	UI sources "$t" "192.0.2.0/24" > "$WORK/run/src2.txt"
	applied "$t" 300
	t0=$(date +%s)
	APX up p $PP ap01.pem ap01.key s5a primary > /dev/null
	eap S2 "範囲の外（192.0.2.0/24）にすると AP の接続が断られ、応答がない" $A1 aka noreply $PP
	l=$(edgelog edge-01 "$t0" "$HOME_IP" | grep -v -c ' up$')
	edgelog edge-01 "$t0" "$HOME_IP" | tail -2
	mark S2b "edge-01 の radsecproxy が範囲の外の送信元（手元の回線のアドレス）の接続を断った記録がある（$l）" "$([ "$l" -gt 0 ]; echo $?)"
	UI sources "$t" "" > "$WORK/run/src3.txt"
	applied "$t" 300
	APX up p $PP ap01.pem ap01.key s5a primary > /dev/null
	eap S3 "範囲を空に戻すとまた通る" $A1 aka accept $PP
	;;
revoke) # X: AP の証明書の失効が WireGuard 越しの CRL で 2 台に届く
	t=$(tid)
	eap X0 "失効させる前は ap02 で通る" $A1 aka accept $PX
	t0=$(date +%s)
	UI revoke "$t" ap02 > "$WORK/run/revoke.txt"
	for i in $(seq 1 36); do
		d=$(sql "SELECT count(*) FROM tenant_radsec WHERE tenant_id=$t AND crl_dirty")
		[ "$d" = 0 ] && break
		sleep 5
	done
	mark X1 "失効の後、整合のループが 2 台に CRL を配り終える（$((i * 5)) 秒）" "$([ "$d" = 0 ]; echo $?)"
	sleep 5
	APX up x $PX ap02.pem ap02.key s5a primary,secondary > /dev/null
	eap X2 "失効させた ap02 はつながらず、応答がない" $A1 aka noreply $PX
	for e in edge-01 edge-02; do
		l=$(edgelog $e "$t0" "revoked" | wc -l)
		mark X3-$e "$e の radsecproxy が ap02 の証明書を失効として断る（$l）" "$([ "$l" -gt 0 ]; echo $?)"
	done
	eap X4 "ap01 は失効の後も通る" $A1 aka accept $PBOTH
	;&
apply) # X5 だけをやり直すとき: 失効で変わった宣言を「反映する」で 2 台に届ける（反映は手動が基本。OB1）
	t=$(tid)
	r=$(sql "SELECT revision||' '||requested_revision FROM tenant_radsec WHERE tenant_id=$t")
	UI apply "$t" > "$WORK/run/apply.txt"
	applied "$t" 300
	mark X5 "失効の後の宣言の変更（版 ${r% *}、求めた版 ${r#* }）を「反映する」で 2 台に届けられる" $?
	;;
nft) # F: エッジ以外の WireGuard のアドレスからデータ面の RADIUS に送ると nftables で落ちる
	b=$(dropcount)
	N mgmt "python3 -c 'import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3); s.sendto(b\"\\x01\\x01\\x00\\x14\"+b\"\\x00\"*16, (\"10.81.0.1\", 1812))
try: print(\"返事\", s.recv(100))
except Exception as e: print(\"返事なし\", e)'"
	a=$(dropcount)
	mark F1 "管理面（10.81.0.2）からデータ面の 1812 に送った RADIUS は nftables で落ちる（落とした数 $b → $a）" "$([ "$a" -gt "$b" ]; echo $?)"
	;;
reboot) # G: edge-01 の再起動の間、AP が secondary に切り替わり、戻った後は primary で通る
	t=$(tid)
	N edge-01 'sudo systemctl reboot' > /dev/null 2>&1
	sleep 5
	# AP の役の radsecproxy は、primary に送った要求の返事がないことで止まりに気づいて secondary に切り替える（段階 4 の F1 と同じく 3 秒おきに試す）
	t0=$SECONDS
	for a in $(seq 1 10); do
		r=$(APX eap $A1 aka accept $PBOTH | tail -1)
		[ "$r" = rc=0 ] && break
		sleep 3
	done
	mark G1 "edge-01 の再起動の間、両方のスロットを持つ AP は secondary に切り替わって通る（$a 回目、$((SECONDS - t0)) 秒）" "$([ "$r" = rc=0 ]; echo $?)"
	l=$(ssh $C "docker logs --since 60s s5-ap-both 2>&1 | grep -c 'Access-Accept.*from secondary'")
	mark G1b "その応答は secondary から返っている（$l）" "$([ "$l" -gt 0 ]; echo $?)"
	for i in $(seq 1 60); do
		sleep 5
		N edge-01 'docker ps --format "{{.Names}}"' 2> /dev/null | grep -q radsecproxy-s5a && break
	done
	sleep 15
	APX up p $PP ap01.pem ap01.key s5a primary > /dev/null
	eap G2 "edge-01 が戻ると primary でまた通る（$((i * 5 + 23)) 秒で s5a のコンテナが戻った）" $A1 aka accept $PP
	r=$(sql "SELECT apply_result FROM placements WHERE tenant_id=$t AND edge_id='edge-01' AND removed_at IS NULL")
	mark G3 "edge-01 の配置は反映済みのまま（$r）" "$([ "$r" = ok ]; echo $?)"
	;;
ui) # U: Cloudflare 越しの画面（ダッシュボード、テナントの RadSec）
	t=$(tid)
	UI check "$t" > "$WORK/run/ui.txt"
	cat "$WORK/run/ui.txt"
	n=$(grep -c '^接続中' "$WORK/run/ui.txt")
	mark U1 "ダッシュボードで aka-provisioner と 5 つの下流が接続中（$n）" "$([ "$n" = 6 ]; echo $?)"
	n=$(grep -c '^反映済み' "$WORK/run/ui.txt")
	mark U2 "s5a の RadSec の画面で 2 つの配置が反映済み（$n）" "$([ "$n" = 2 ]; echo $?)"
	;;
drill-data) # T5-5: データ面の戻す練習（バックアップ → ops-pc → 変更 → ボリュームと KEK を消す → ops-pc の写しと KEK の写しから戻す）
	A3=440109999100003 D=$(date +%Y%m%d)
	N data 'sudo /usr/local/lib/aka/backup.sh' | tail -1
	ssh simwifi2 'docker exec ops-pc /usr/local/bin/pull.sh' | grep ' data '
	ssh simwifi2 "ls ~/aka-work/ops-pc/data/data/backups/$D/" | tr '\n' ' '
	echo
	# 写しの後の変更: 加入者 A3 を足し、A1 で 2 回認証して SQN を進める
	UI sub "$A3" > "$WORK/run/drill-sub.txt"
	eap D0 "写しの後に足した A3 で通る" $A3 aka accept $PP
	APX eap $A1 aka accept $PP > /dev/null
	APX eap $A1 aka accept $PP > /dev/null
	t0=$(date +%s)
	echo "== 消す（$(date +%T)）"
	N data 'cd /opt/aka-radius/deployments && docker compose down -v 2>&1 | tail -1; cd /opt/aka-vecgen && docker compose down -v 2>&1 | tail -1; sudo rm -f /opt/aka-vecgen/secrets/kek; docker volume ls -q | grep -c -E "valkey" | sed "s/^/残っている valkey のボリューム: /"'
	echo "== 戻す（$(date +%T)）"
	ssh simwifi2 "cat ~/aka-work/ops-pc/data/data/backups/$D/aka-vecgen-valkey.rdb" | Ni data "cat > /tmp/aka-vecgen-valkey.rdb"
	ssh simwifi2 "cat ~/aka-work/ops-pc/data/data/backups/$D/aka-radius-valkey.rdb" | Ni data "cat > /tmp/aka-radius-valkey.rdb"
	Ni data 'sudo tee /opt/aka-vecgen/secrets/kek > /dev/null && sudo chown 65532 /opt/aka-vecgen/secrets/kek && sudo chmod 600 /opt/aka-vecgen/secrets/kek' < "$HOME/aka-deploy/keks/aka-vecgen.kek"
	N data 'set -e
		cd /opt/aka-vecgen && sudo install -m 600 -o aka /tmp/aka-vecgen-valkey.rdb backups/drill.rdb
		docker compose up -d --no-build --wait valkey 2>&1 | tail -1
		scripts/restore-valkey.sh backups/drill.rdb 2>&1 | tail -2
		docker compose up -d --no-build --wait --wait-timeout 120 2>&1 | tail -1
		cd /opt/aka-radius/deployments && sudo install -m 600 -o aka /tmp/aka-radius-valkey.rdb backups/drill.rdb
		docker compose up -d --no-build --wait valkey 2>&1 | tail -1
		../scripts/restore-valkey.sh backups/drill.rdb 2>&1 | tail -2
		docker compose up -d --no-build --wait --wait-timeout 180 2>&1 | tail -1
		rm -f /tmp/aka-vecgen-valkey.rdb /tmp/aka-radius-valkey.rdb'
	t1=$(date +%s)
	n=$(N data 'docker ps --format "{{.Names}} {{.Status}}"' | grep -E 'aka-(vecgen|radius)' | grep -c healthy)
	mark D1 "ボリュームと KEK を消したデータ面を、ops-pc の写しと手元の KEK の写しから戻し、7 つのコンテナが healthy（$n）。消してから戻すまで $((t1 - t0)) 秒（RTO 4 時間）" "$([ "$n" = 6 ] || [ "$n" = 7 ]; echo $?)"
	eap D2 "戻した後、A1 で通る（写しの後に進めた SQN は巻き戻り、再同期で回復する）" $A1 aka accept $PP
	n=$(radlog $A1 "$t1" | grep -c -i -E 'RESYNC|SYNC')
	mark D3 "aka-radius のログに A1 の再同期が出る（$n）" "$([ "$n" -gt 0 ]; echo $?)"
	eap D4 "写しの後に足した A3 は戻した後は拒否（写しにないため）" $A3 aka reject $PP
	UI submit /reconcile 今すぐ実行する > "$WORK/run/drill-rec.txt"
	sleep 10
	UI page /reconcile > "$WORK/run/drill-rec.txt"
	sed -n '/^ID/,/^定期/p' "$WORK/run/drill-rec.txt" | head -4
	r=$(sed -n '/^ID/{n;p}' "$WORK/run/drill-rec.txt")
	mark D5 "突き合わせを手で動かすと、A3 のずれを見つけて台帳を下流に合わせる（$(echo "$r" | cut -f2-7 | tr '\t' ' ')）" "$(echo "$r" | awk -F'\t' '{exit !($6 >= 1)}'; echo $?)"
	;&
drill-data-rereg) # D6 だけをやり直すとき
	A3=440109999100003
	UI sub "$A3" > "$WORK/run/drill-sub2.txt"
	cat "$WORK/run/drill-sub2.txt"
	eap D6 "A3 を両側に登録し直すと通る（vecgen 側は鍵があるので登録し直しが要る）" $A3 aka accept $PP
	;;
drill-mgmt) # T5-6: 管理面の戻す練習（バックアップ → ops-pc → AP ap03 を足して反映 → 3 つを ops-pc の写しから戻す → 11.2）
	D=$(date +%Y%m%d) t=$(tid)
	N mgmt 'sudo /usr/local/lib/aka/backup.sh' | tail -1
	ssh simwifi2 'docker exec ops-pc /usr/local/bin/pull.sh' | grep ' mgmt '
	ssh simwifi2 "ls -l ~/aka-work/ops-pc/data/mgmt/backups/$D/" | awk 'NR>1 {print $5, $9}' | tr '\n' ' '
	echo
	rev0=$(sql "SELECT revision FROM tenant_radsec WHERE tenant_id=$t")
	# 写しの後の変更: AP ap03 を足して反映する
	UI setup "$A1,$A2" "$(python3 -I -c 'import json,sys; print(json.dumps({"ap03": open(sys.argv[1]).read()}))' "$WORK/pki/ap03.csr")" > "$WORK/run/drill-ap03.txt"
	applied "$t" 300
	row=$(sql "SELECT a.id||' '||c.serial FROM aps a JOIN ap_certs c ON c.ap_id=a.id WHERE a.tenant_id=$t AND a.name='ap03' ORDER BY c.issued_at DESC LIMIT 1")
	W GET "/tenants/$t/aps/${row%% *}/certs/${row##* }/pem"
	cp "$WORK/last.html" "$WORK/pki/ap03.pem"
	echo "ap03 のシリアル ${row##* }" | tee "$WORK/run/drill-ap03-serial.txt"
	(cd "$WORK/pki" && tar cf - ap03.pem) | ssh $C "tar xf - -C $REMOTE/ap && chmod 644 $REMOTE/ap/ap03.pem"
	APX up ap3 31852 ap03.pem ap03.key s5a primary > /dev/null
	eap M0 "写しの後に足した ap03 で通る（版 $rev0 → $(sql "SELECT revision FROM tenant_radsec WHERE tenant_id=$t")）" $A1 aka accept 31852
	t0=$(date +%s)
	echo "== 戻す（$(date +%T)）"
	for f in aka-provisioner-valkey.rdb aka-ossbss.dump radsec-ca.db; do
		ssh simwifi2 "cat ~/aka-work/ops-pc/data/mgmt/backups/$D/$f" | Ni mgmt "cat > /tmp/drill-$f"
	done
	N mgmt 'set -e
		cd /opt/aka-provisioner && sudo install -m 600 -o aka /tmp/drill-aka-provisioner-valkey.rdb backups/drill.rdb 2>/dev/null || { mkdir -p backups && chmod 700 backups && sudo install -m 600 -o aka /tmp/drill-aka-provisioner-valkey.rdb backups/drill.rdb; }
		scripts/restore-valkey.sh backups/drill.rdb 2>&1 | tail -1
		docker compose up -d --no-build --wait --wait-timeout 120 2>&1 | tail -1
		cd /opt/aka-ossbss && sudo install -m 600 -o aka /tmp/drill-aka-ossbss.dump backups/drill.dump
		scripts/restore-db.sh backups/drill.dump 2>&1 | tail -2
		docker compose up -d --no-build --wait --wait-timeout 180 2>&1 | tail -1
		cd /opt/radsec-ca && mkdir -p backups && sudo install -m 644 /tmp/drill-radsec-ca.db backups/drill.db
		docker compose stop radsec-ca 2>&1 | tail -1
		docker run --rm -v radsec-ca_ca-data:/data -v ./backups:/b busybox:1.37.0 sh -c "cp /b/drill.db /data/radsec-ca.db && rm -f /data/radsec-ca.db-wal /data/radsec-ca.db-shm && chown 65532:65532 /data/radsec-ca.db"
		docker compose start radsec-ca 2>&1 | tail -1
		sudo rm -f /tmp/drill-*'
	for i in $(seq 1 24); do N mgmt 'docker ps --format "{{.Names}} {{.Status}}"' | grep -q -E 'starting|unhealthy' || break; sleep 5; done
	t1=$(date +%s)
	n=$(N mgmt 'docker ps --format "{{.Names}} {{.Status}}"' | grep -c healthy)
	c=$(N mgmt 'cd /opt/aka-provisioner && docker compose exec -T aka-provisioner /aka-provisioner check-downstream 2>&1' | grep -c 接続できました)
	h=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$BASE/healthz")
	mark M1 "aka-provisioner の Valkey・aka-ossbss の DB・radsec-ca の DB を ops-pc の写しから戻した。healthy $n、下流 $c/5、公開のホスト名 $h。始めてから $((t1 - t0)) 秒（RTO 4 時間）" "$([ "$c" = 5 ] && [ "$h" = 302 ]; echo $?)"
	rev1=$(sql "SELECT revision FROM tenant_radsec WHERE tenant_id=$t")
	n=$(sql "SELECT count(*) FROM aps WHERE tenant_id=$t AND name='ap03'")
	mark M2 "戻した DB は写しの時点（s5a の版 $rev1、ap03 の行 $n）" "$([ "$n" = 0 ]; echo $?)"
	eap M3 "戻した後も ap01 で通る（エッジと認証は止まらない）" $A1 aka accept $PBOTH
	sleep 70
	UI page "/tenants/$t/radsec" > "$WORK/run/drill-radsec1.txt"
	l=$(grep -c 'エッジのほうが新しい版' "$WORK/run/drill-radsec1.txt")
	sed -n '/^配置/,/^スロット$/p' "$WORK/run/drill-radsec1.txt" | head -12
	mark M4 "配置の行に「エッジのほうが新しい版です」が出る（$l）" "$([ "$l" -gt 0 ]; echo $?)"
	eap M5 "「やり直す」を押す前は ap03 でもまだ通る（ループはエッジに反映しない）" $A1 aka accept 31852
	;&
drill-mgmt-redo) # M6〜: 「やり直す」を 1 台ずつ押す
	t=$(tid)
	for e in edge-01 edge-02; do
		UI submit "/tenants/$t/radsec" やり直す > "$WORK/run/drill-redo-$e.txt"
		sleep 20
	done
	applied "$t" 300
	mark M6 "「やり直す」を 1 台ずつ押すと、2 台が今の DB の状態（版 $(sql "SELECT revision FROM tenant_radsec WHERE tenant_id=$t")）になる" $?
	APX up ap3 31852 ap03.pem ap03.key s5a primary > /dev/null
	eap M7 "やり直した後は、写しの後に足した ap03 はつながらない" $A1 aka noreply 31852
	eap M8 "ap01 は通る" $A1 aka accept $PBOTH
	;;
keepalive) # T5-18: エッジの TCP の生存確認（TCPKeepalive on）で、AP の接続を 10 分何も送らずに置いても通る（手元の回線の NAT の対応が消えない）
	# 入れ替えの後に、テナントを aka-provisioner の API で反映し直してから動かす（T5-18。ひな形が変わっても既存のテナントは作り直されない）
	IDLE=${IDLE:-660}
	for e in edge-01 edge-02; do
		n=$(N "$e" "sudo grep -c 'TCPKeepalive on' /var/lib/radsec-edge/tenants/s5a/current/radsecproxy.conf")
		mark K0-$e "$e の s5a の設定の client ブロックに TCPKeepalive on（$n 件）" "$([ "${n:-0}" -ge 2 ]; echo $?)"
	done
	APX up p $PP ap01.pem ap01.key s5a primary > /dev/null
	APX up s $PS ap01.pem ap01.key s5a secondary > /dev/null
	eap K1-p "つないですぐは primary（edge-01）で通る" $A1 aka accept $PP
	eap K1-s "つないですぐは secondary（edge-02）で通る" $A1 aka accept $PS
	for e in edge-01 edge-02; do
		l=$(N "$e" "sudo sh -c 'nsenter -t \$(docker inspect -f {{.State.Pid}} radsecproxy-s5a) -n ss -tnoi state established'" | grep -A1 "$HOME_IP:" | grep -o 'timer:(keepalive[^)]*)' | head -1)
		mark K2-$e "$e の s5a のコンテナの中の AP の役の接続（送信元は手元の回線）に keepalive の timer（$l）" "$([ -n "$l" ]; echo $?)"
	done
	echo "== $IDLE 秒何も送らずに置く（$(date +%T)〜）"
	sleep "$IDLE"
	eap K3-s "$IDLE 秒何も送らなかった AP の役が secondary（edge-02）で通る（前は 10 分で応答がなくなった）" $A1 aka accept $PS
	eap K3-p "$IDLE 秒何も送らなかった AP の役が primary（edge-01）で通る" $A1 aka accept $PP
	for n in p s; do
		l=$(ssh $C "docker logs s5-ap-$n 2>&1 | grep -c -E 'TLS connection to .* up'")
		mark K4-$n "その間に AP の役（$n）の TLS はつなぎ直していない（つないだ回数 $l）" "$([ "$l" = 1 ]; echo $?)"
	done
	;;
load-keys) # ③ T5-7: 148 テナント × AP 5 台の鍵と CSR を検証機で作り、CSR を手元に集める（s5a も edge-02 にあるので probe・s5a と合わせて 150）
	mkdir -p "$WORK/load/pki" "$WORK/load/req"
	ssh $C "mkdir -p $REMOTE/load/pki && cd $REMOTE/load/pki && for i in \$(seq -f %03g 1 $LN); do for a in ap1 ap2 ap3 ap4 ap5; do f=ld\$i-\$a; [ -s \$f.key ] || openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout \$f.key -out \$f.csr -subj /CN=ap < /dev/null 2> /dev/null; done; done; chmod 644 *.key; ls *.csr | wc -l"
	ssh $C "cd $REMOTE/load/pki && python3 -I -c 'import json,glob; print(json.dumps({f[:-4]: open(f).read() for f in sorted(glob.glob(\"ld*.csr\"))}))'" > "$WORK/load/csr.json"
	scp -q "$T/load-ap.py" "$C:aka-work/stage5/load/"
	python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))), "件の CSR")' "$WORK/load/csr.json"
	;;
load-tenants) # ③ T5-7: テナントを作り、RadSec を有効にし、AP を 5 台ずつ登録して edge-02 だけに置く（画面の HTTP。やり直すと残りだけ送る）
	rm -f "$WORK"/load/req/tenants*.json "$WORK"/load/req/setup-*.json
	lstate > "$WORK/load/state.tsv"
	python3 -I "$T/load.py" tenants "$WORK/load/state.tsv" "$LN" "$WORK/load/req/tenants.json"
	if [ "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORK/load/req/tenants.json")" != 0 ]; then
		BULK "$WORK/load/req/tenants.json" > "$WORK/load/req/tenants.out.json"
		python3 -I "$T/load.py" result "$WORK/load/req/tenants.out.json"
	fi
	lstate > "$WORK/load/state.tsv"
	echo "テナント $(wc -l < "$WORK/load/state.tsv")"
	python3 -I "$T/load.py" setup "$WORK/load/state.tsv" "$WORK/load/csr.json" edge-02 "$WORK/load/req/setup-" 40
	for f in "$WORK"/load/req/setup-[0-9][0-9][0-9].json; do
		[ -e "$f" ] || break
		BULK "$f" > "${f%.json}.out.json"
		echo "$(basename "$f") $(date +%T) $(python3 -I "$T/load.py" result "${f%.json}.out.json" | tr '\n' ' ')"
	done
	lstate > "$WORK/load/state.tsv"
	awk -F'|' '$3 != "" && $4 == "ap1,ap2,ap3,ap4,ap5" && $5 == 1 {n++} END {print "そろったテナント", n + 0}' "$WORK/load/state.tsv"
	;;
load-wait) # ③: 148 テナントの配置が全部反映されるまで待つ（新しい配置は整合のループが反映する。OB1）
	for i in $(seq 1 120); do
		r=$(sql "SELECT count(*) FILTER (WHERE p.applied_revision = r.revision AND p.apply_result = 'ok')||'/'||count(*)||'/'||count(*) FILTER (WHERE p.apply_result NOT IN ('ok', '')) FROM placements p JOIN tenant_radsec r USING (tenant_id) JOIN tenants t ON t.id = p.tenant_id WHERE t.name LIKE 'ld%' AND p.removed_at IS NULL")
		echo "$(date +%T) 反映済み/配置/失敗 $r"
		[ "${r%%/*}" = "$LN" ] && break
		sleep 30
	done
	N edge-02 'docker ps --filter name=radsecproxy- --format "{{.Names}}" | wc -l; free -m | sed -n 2p'
	;;
load-certs) # ③: 148 のサーバー CA と 740 枚の AP の証明書を画面から取り、検証機に送って aps.txt を作る
	rm -f "$WORK"/load/req/certs-*.json
	sql "SELECT t.name, t.id, r.port, a.name, a.id, c.serial FROM tenants t JOIN tenant_radsec r ON r.tenant_id = t.id JOIN aps a ON a.tenant_id = t.id AND a.deleted_at IS NULL
		JOIN LATERAL (SELECT serial FROM ap_certs WHERE ap_id = a.id ORDER BY issued_at DESC LIMIT 1) c ON true WHERE t.name LIKE 'ld%' AND t.deleted_at IS NULL ORDER BY t.name, a.name" > "$WORK/load/certs.tsv"
	python3 -I "$T/load.py" certs "$WORK/load/certs.tsv" "$WORK/load/req/certs-" 60
	pairs=()
	for f in "$WORK"/load/req/certs-[0-9][0-9][0-9].json; do
		BULK "$f" > "${f%.json}.out.json"
		pairs+=("$f" "${f%.json}.out.json")
	done
	python3 -I "$T/load.py" save-certs "${pairs[@]}" "$WORK/load/pki" || exit 1
	python3 -I "$T/load.py" aps "$WORK/load/certs.tsv" "/home/claude/aka-work/stage5/load/pki" > "$WORK/load/aps.txt"
	(cd "$WORK/load/pki" && tar cf - ld*.pem) | ssh $C "tar xf - -C $REMOTE/load/pki && chmod 644 $REMOTE/load/pki/*.pem"
	scp -q "$WORK/load/aps.txt" "$C:aka-work/stage5/load/aps.txt"
	echo "aps.txt $(wc -l < "$WORK/load/aps.txt") 行"
	;;
load-try) # ③ T5-8: 1 テナント（AP 5 台）だけで、認証の要求に aka-radius の Access-Reject が返ることを試す
	ssh $C "cd $REMOTE/load && rm -f ap-status.json && timeout 45 python3 -I load-ap.py $REMOTE/load $EDGE02 0.001 2 5; cat ap-status.json"
	echo
	N data "tail -300 /opt/aka-radius/deployments/logs_on_host/auth.log" | grep -o '"event_id":"[A-Z_]*"' | sort | uniq -c | sort -rn | head -6
	;;
load-start) # ③ T5-8・T5-9: edge-02 の 10 分ごとの測定（systemd の一時の timer）と、検証機の AP の役（接続 740 本、し直し毎秒 1 本、RADIUS 10 件/秒）を始める
	Ni edge-02 'sudo install -d -m 755 /var/tmp/aka-s5load && sudo tee /var/tmp/aka-s5load/load-measure.py > /dev/null' < "$T/load-measure.py"
	N edge-02 'systemctl is-active -q aka-s5load-measure.timer || sudo systemd-run --unit aka-s5load-measure --on-calendar "*:0/10" python3 -I /var/tmp/aka-s5load/load-measure.py /var/tmp/aka-s5load/samples.jsonl; sudo python3 -I /var/tmp/aka-s5load/load-measure.py /var/tmp/aka-s5load/samples.jsonl && systemctl list-timers --no-pager | grep aka-s5load'
	date +%s > "$WORK/load/start"
	# pkill・pgrep は行頭に固定する（遠隔のシェル自身のコマンドの文字列に当たって止めてしまうため）
	ssh $C "cd $REMOTE/load && pkill -f '^python3 -I [l]oad-ap.py'; rm -f ap-status.json; nohup python3 -I load-ap.py $REMOTE/load $EDGE02 1 10 > ap.log 2>&1 < /dev/null & sleep 1; pgrep -af '^python3 -I [l]oad-ap.py'"
	echo "始めた: $(date -d @"$(cat "$WORK/load/start")" +'%F %T')"
	;;
load-status) # ③: 最後の測定と AP の役の状態
	N edge-02 'sudo tail -1 /var/tmp/aka-s5load/samples.jsonl' | python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); p=d["procs"]; print({k: d[k] for k in ("t","mem_used_mib","ap_conns","containers","disk_root_used_gib")}, *[n + " " + str(p.get(n, {}).get("pss_kb", 0) // 1024) + " MiB" for n in ("dockerd", "containerd", "containerd-shim", "radsecproxy")])'
	ssh $C "cat $REMOTE/load/ap-status.json"
	echo
	;;
load-report) # ③ T5-9: 記録を手元に写してまとめる
	N edge-02 'sudo cat /var/tmp/aka-s5load/samples.jsonl' > "$WORK/load/samples.jsonl"
	ssh $C "cat $REMOTE/load/ap-status.jsonl" > "$WORK/load/ap-status.jsonl" 2> /dev/null
	python3 -I "$T/load.py" report "$WORK/load/samples.jsonl" "$WORK/load/ap-status.jsonl" "$(cat "$WORK/load/start")"
	;;
notify) # ④ T5-11: edge-01 のテナントのポート（probe 20000・s5a 20001）を nftables で 6 分止め、外形監視の ProbeFailing（primary）が発報して
	# Slack に届き、両方のスロットを持つ AP が secondary に切り替わり、戻すと解消する。止めるのは別の表（inet aka_t511。Docker の DNAT より前）で、
	# 消し忘れても 10 分で消える一時の timer をつける。Slack の [発生]・[解消] が届いたかはユーザーが確かめる
	pf() { N mon "curl -s -G --data-urlencode 'query=ALERTS{alertname=\"ProbeFailing\",alertstate=\"firing\"}' http://10.82.0.1:9090/api/v1/query" |
		python3 -I -c 'import json, sys; print(" ".join(sorted(r["metric"].get("slot", "?") for r in json.load(sys.stdin)["data"]["result"])))'; }
	APX up both $PBOTH ap01.pem ap01.key s5a primary,secondary > /dev/null
	sleep 5
	eap N0 "止める前は両方のスロットを持つ AP で通る" $A1 aka accept $PBOTH
	f=$(pf)
	mark N0b "止める前に発報している ProbeFailing はない（${f:-なし}）" "$([ -z "$f" ]; echo $?)"
	N edge-01 "sudo systemd-run --quiet --unit=aka-t511-undo --on-active=600 /usr/sbin/nft delete table inet aka_t511 && sudo nft add table inet aka_t511 && sudo nft add chain inet aka_t511 pre '{ type filter hook prerouting priority -300 ; }' && sudo nft add rule inet aka_t511 pre tcp dport '{ 20000, 20001 }' counter drop"
	t0=$SECONDS
	echo "== edge-01 のテナントのポートを止めた（$(date +%T)）"
	for a in $(seq 1 10); do
		r=$(APX eap $A1 aka accept $PBOTH | tail -1)
		[ "$r" = rc=0 ] && break
		sleep 3
	done
	mark N1 "止めている間、両方のスロットを持つ AP は secondary に切り替わって通る（$a 回目、$((SECONDS - t0)) 秒）" "$([ "$r" = rc=0 ]; echo $?)"
	l=$(ssh $C "docker logs --since 90s s5-ap-both 2>&1 | grep -c 'Access-Accept.*from secondary'")
	mark N1b "その応答は secondary から返っている（$l）" "$([ "$l" -gt 0 ]; echo $?)"
	until [ "$(pf)" = primary ] || [ $((SECONDS - t0)) -ge 360 ]; do sleep 10; done
	f=$(pf)
	mark N2 "外形監視の ProbeFailing が primary だけで発報した（止めてから $((SECONDS - t0)) 秒）" "$([ "$f" = primary ]; echo $?)"
	while [ $((SECONDS - t0)) -lt 360 ]; do sleep 10; done
	N edge-01 "sudo nft list table inet aka_t511 | grep -o 'packets [0-9]*'; sudo nft delete table inet aka_t511 && sudo systemctl stop aka-t511-undo.timer"
	t1=$SECONDS
	echo "== 戻した（$(date +%T)。止めていたのは $((t1 - t0)) 秒）"
	until [ -z "$(pf)" ] || [ $((SECONDS - t1)) -ge 300 ]; do sleep 10; done
	f=$(pf)
	mark N3 "戻すと ProbeFailing が解消した（戻してから $((SECONDS - t1)) 秒）" "$([ -z "$f" ]; echo $?)"
	for a in $(seq 1 10); do
		r=$(APX eap $A1 aka accept $PP | tail -1)
		[ "$r" = rc=0 ] && break
		sleep 3
	done
	mark N4 "戻すと primary だけの AP でまた通る（$a 回目）" "$([ "$r" = rc=0 ]; echo $?)"
	;;
clean) # T5-12: 試験のテナント（ld001〜ld148 と s5a）を画面から片付ける。s5a の加入者を消し、配置を外して AP を削除し（有効な証明書は画面が失効させる）、
	# ループがエッジから消し終えたらテナントを削除する（ポートが空き、テナントの CA が止まる）。probe は残す。やり直すと残りだけ送る
	cstate() { sql "SELECT t.id, t.name,
		coalesce((SELECT string_agg(a.id::text, ',' ORDER BY a.id) FROM aps a WHERE a.tenant_id = t.id AND a.deleted_at IS NULL), ''),
		coalesce((SELECT string_agg(p.id::text, ',' ORDER BY p.id) FROM placements p WHERE p.tenant_id = t.id AND p.deleted_at IS NULL), ''),
		(SELECT count(*) FROM placements p WHERE p.tenant_id = t.id AND p.removed_at IS NULL)
		FROM tenants t WHERE (t.name LIKE 'ld%' OR t.name = 's5a') AND t.deleted_at IS NULL ORDER BY t.name"; }
	mkdir -p "$WORK/load/req"
	rm -f "$WORK"/load/req/clean-*.json
	# s5a の加入者（A1〜A3）: 両方の側を止めてから、側ごとに物理削除する（Active は消せない。W6）
	A3=440109999100003 # 戻す練習（drill-data）で足した加入者
	python3 -I - "$WORK/load/req/clean-sub.json" $A1 $A2 $A3 << 'PY'
import json, sys, uuid
out, *imsis = sys.argv[1:]
reqs = []
for i in imsis:
    reqs.append({"m": "POST", "p": f"/subscribers/{i}/state", "f": {"side": "both", "state": "inactive", "reason": "段階 5 の片付け"}})
    reqs += [{"m": "POST", "p": f"/subscribers/{i}/delete", "f": {"side": s, "idem": str(uuid.uuid4())}} for s in ("radius", "vecgen")]
json.dump(reqs, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
	BULK "$WORK/load/req/clean-sub.json" > "$WORK/load/req/clean-sub.out.json"
	echo "s5a の加入者 $(python3 -I "$T/load.py" result "$WORK/load/req/clean-sub.out.json" | tr '\n' ' ')"
	cstate > "$WORK/load/clean-state.tsv"
	python3 -I "$T/load.py" clean "$WORK/load/clean-state.tsv" detach "$WORK/load/req/clean-detach-" 60
	for f in "$WORK"/load/req/clean-detach-[0-9][0-9][0-9].json; do
		[ -e "$f" ] || break
		BULK "$f" > "${f%.json}.out.json"
		echo "$(basename "$f") $(date +%T) $(python3 -I "$T/load.py" result "${f%.json}.out.json" | tr '\n' ' ')"
	done
	for i in $(seq 1 60); do # ループがエッジから消し終えるまで待つ（removed_at）
		n=$(sql "SELECT count(*) FROM placements p JOIN tenants t ON t.id = p.tenant_id WHERE (t.name LIKE 'ld%' OR t.name = 's5a') AND t.deleted_at IS NULL AND p.removed_at IS NULL")
		echo "$(date +%T) エッジから消し終えていない配置 $n"
		[ "$n" = 0 ] && break
		sleep 30
	done
	cstate > "$WORK/load/clean-state.tsv"
	python3 -I "$T/load.py" clean "$WORK/load/clean-state.tsv" delete "$WORK/load/req/clean-delete-" 60
	for f in "$WORK"/load/req/clean-delete-[0-9][0-9][0-9].json; do
		[ -e "$f" ] || break
		BULK "$f" > "${f%.json}.out.json"
		echo "$(basename "$f") $(date +%T) $(python3 -I "$T/load.py" result "${f%.json}.out.json" | tr '\n' ' ')"
	done
	n=$(sql "SELECT count(*) FROM tenants WHERE (name LIKE 'ld%' OR name = 's5a') AND deleted_at IS NULL")
	mark C1 "試験のテナント（ld・s5a）が残っていない（$n）" "$([ "$n" = 0 ]; echo $?)"
	p=$(sql "SELECT string_agg(slug || ':' || port, ' ') FROM tenant_radsec WHERE released_at IS NULL")
	mark C2 "空いていないポートは probe の分だけ（$p）" "$([ "$p" = probe:20000 ]; echo $?)"
	for e in edge-01 edge-02; do
		c=$(N $e 'docker ps -a --filter label=radsec-edge.tenant --format "{{.Names}}" | sort | tr "\n" " "')
		mark C3 "$e のテナントのコンテナは probe だけ（$c）" "$([ "$c" = "radsecproxy-probe " ]; echo $?)"
	done
	;;
summary)
	awk -F'\t' '{c[$2]++} END {printf "PASS %d / FAIL %d\n", c["PASS"], c["FAIL"]}' "$RES"
	grep -P '\tFAIL\t' "$RES" || true
	;;
*) echo "段の一覧は README.md" >&2; exit 2 ;;
esac
