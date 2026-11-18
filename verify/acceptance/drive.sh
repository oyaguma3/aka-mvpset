#!/bin/bash
# 受入試験の予行（段階 6-4。確認事項 A6-1〜A6-11）の台本。手元で動かす。手順書は docs/acceptance-test.md。
# ノードへは踏み台（監視ノード）を通した SSH（~/aka-deploy/ssh_config）、画面は playwright-cli、
# 端末の役は検証機の 1 台目の simwifi（MBIM のモデムに挿した検証用 SIM と無線 LAN。https://github.com/oyaguma3/simwifi）。
#
#   WORK=<手元の作業ディレクトリ> ./drive.sh <段>
#
# $WORK/site.env（公開しない）: BASE（aka-ossbss の公開のホスト名）、ADMIN_EMAIL、DNS_DOMAIN、HOME_IP（手元の回線の公開のアドレス）。
# 予行の値（テナント・グループ・SSID）は下の既定を環境変数で変えられる。SIM の IMSI は $WORK/accept/imsi（1 行に 1 つ。公開しない）。
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
S5=$T/../stage5
: "${WORK:?}"
. "$WORK/site.env"
A=$WORK/accept
mkdir -p "$A/pki" "$A/unifi" "$A/run"
chmod 700 "$A" "$A/pki" "$A/unifi"
RES=$A/results.tsv
TEN=${TEN:-at1} TEN2=${TEN2:-at2} GRP=${GRP:-unifi} SSID=${SSID:-U7-Lite-AKA} STO=${STO:-3600}
C=simwifi IFACE=${IFACE:-wlo1}
REMOTE='~/aka-work/accept'
SSHCFG=$HOME/aka-deploy/ssh_config

N() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "aka-$1" "${@:2}" < /dev/null; }
Ni() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "aka-$1" "${@:2}"; }
sql() { echo "$1" | Ni mgmt 'cd /opt/aka-ossbss && docker compose exec -T postgres psql -U ossbss -d ossbss -At -v ON_ERROR_STOP=1'; }
mark() { # <項目> <内容> <0 なら PASS>
	local r=FAIL
	[ "$3" = 0 ] && r=PASS
	printf '%s\t%s\t%s\t%s\n' "$(date +%T)" "$1" "$r" "$2" | tee -a "$RES"
}
# 無操作で閉じないように --idle-timeout 0 で開く（headless の既定は 1 時間で閉じる）
PW() { (cd "$WORK" && timeout "${PWT:-300}" playwright-cli -s=stage6 "$@" < /dev/null); }
# UI <台本のパス> [引数...]: __BASE__・__A1__… を置き換えて動かし、出力をそのまま返す
UI() {
	local src=$1 f
	f="$WORK/run-at-$(basename "$1")"
	shift
	python3 -I - "$src" "$f" "$BASE" "$@" << 'PY'
import sys
src, dst, base, *args = sys.argv[1:]
s = open(src, encoding="utf-8").read().replace("__BASE__", base)
for i, a in enumerate(args, 1):
    s = s.replace(f"__A{i}__", a)
open(dst, "w", encoding="utf-8").write(s)
PY
	PW --raw run-code --filename="$(basename "$f")" 2>&1 | python3 -I -c '
import json, sys
lines = sys.stdin.read().splitlines()
js = [l for l in lines if l.startswith("\"")]
print(json.loads(js[-1]) if js else "\n".join(lines))'
}
tid() { sql "SELECT id FROM tenants WHERE name='${1:-$TEN}' AND deleted_at IS NULL"; }
imsis() { grep -E '^[0-9]{15}$' "$A/imsi" 2> /dev/null | paste -sd,; }
# applied [秒]: 予行のテナントの全部の配置が望む版を反映するまで待つ
applied() {
	local t n=${1:-300} i r
	t=$(tid)
	for i in $(seq 1 $((n / 5))); do
		r=$(sql "SELECT count(*) FILTER (WHERE p.applied_revision = r.revision AND p.apply_result = 'ok')||'/'||count(*) FROM placements p JOIN tenant_radsec r USING (tenant_id) WHERE p.tenant_id=$t AND p.removed_at IS NULL")
		[ "${r%/*}" = "${r#*/}" ] && [ "${r#*/}" != 0 ] && { echo "反映 $r（$((i * 5)) 秒）"; return 0; }
		sleep 5
	done
	echo "反映が終わらない: $r"
	return 1
}

# ---- 端末の役（simwifi）と記録の読み方 ----
SIMI() { cat "$A/sim-imsi"; }  # 検証機の SIM の IMSI（sim-id で取る）
# simrun <aka|akap> [待つ秒]: 検証機の端末の役で 1 回つなぐ。つながったらすぐ切る。rc=0 接続、3 認証の失敗、4 時間切れ
simrun() {
	local m=$1 w=${2:-90}
	ssh $C "cd $REMOTE && mkdir -p run && sudo timeout $((w + 30)) ./simwifi connect --iface $IFACE --ssid $SSID --method $m --timeout $w --max-auth-failures 1 --exec-up 'kill -TERM \$PPID' --log-file run/sim.log 2>&1 | tail -4; echo rc=\${PIPESTATUS[0]}" < /dev/null
}
# radlog <この時刻（epoch）より後> [IMSI]: aka-radius の auth のログ（最後の 20 万行）から、その IMSI の event_id・テナント・NAS-Identifier・ルール・SSID を出す
radlog() {
	local py
	py=$(cat << 'EOP'
import json,sys,datetime
imsi, since = sys.argv[1], float(sys.argv[2])
for l in sys.stdin:
    try:
        d = json.loads(l)
        m = json.loads(d['log']) if isinstance(d.get('log'), str) and d['log'].startswith('{') else d
        ts = datetime.datetime.fromisoformat(m.get('time', '')).timestamp()
    except Exception:
        continue
    i = str(m.get('imsi', ''))
    if ts < since or not i or not (i == imsi or (len(i) == 15 and i[:6] == imsi[:6] and i[-1] == imsi[-1])):
        continue
    print(m.get('time', '')[11:23], m.get('event_id'), 'tenant=%s' % m.get('tenant_id', '-'), 'nas=%s' % m.get('nas_identifier', '-'),
          'rule=%s' % m.get('rule_index', '-'), 'ssid=%s' % m.get('ssid', '-'))
EOP
)
	N data "tail -n 200000 /opt/aka-radius/deployments/logs_on_host/auth.log | python3 -c $(printf '%q' "$py") ${2:-$(SIMI)} $1"
}
# conns <エッジ>: エッジのテナントのコンテナが受けている AP の接続（送り元）。コンテナの中の待ち受けは 2083
conns() {
	N "$1" "p=\$(docker inspect -f '{{.State.Pid}}' radsecproxy-$TEN 2> /dev/null) && sudo nsenter -t \$p -n ss -Htn state established '( sport = :'\$(docker port radsecproxy-$TEN | head -1 | sed 's#/tcp.*##')' )' | awk '{print \$4}' | sed 's/:[0-9]*\$//' | sort | uniq -c | tr '\n' ' '"
}
# edgelog <エッジ> <語> [行数]: エッジの radsecproxy のログ（予行のテナントの行だけ、最後の行数）
edgelog() {
	N "$1" "tail -n 20000 /var/lib/radsec-edge/logs/radsecproxy.log | python3 -c 'import json,sys
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: continue
    if d.get(\"container_name\",\"\").lstrip(\"/\")==\"radsecproxy-$TEN\": print(d.get(\"log\",\"\").rstrip())' | grep -E '$2' | tail -n ${3:-10}"
}
# auth <項目> <内容> <aka|akap> <accept|reject>: 端末の役で 1 回つなぎ、期待どおりか記録する（拒否は時間切れも拒否と数える）
auth() {
	local id=$1 text=$2 m=$3 want=$4 t out r ok
	t=$(date +%s)
	out=$(simrun "$m")
	r=$(echo "$out" | tail -1 | sed 's/^rc=//')
	sleep 2
	echo "$out" | head -n -1 | sed 's/^/    /'
	radlog "$t" | tail -8 | sed 's/^/    /'
	case $want in
	accept) ok=$([ "$r" = 0 ]; echo $?) ;;
	reject) ok=$([ "$r" = 3 ] || [ "$r" = 4 ]; echo $?) ;;
	esac
	mark "$id" "$text（rc=$r）" "$ok"
}
info() { printf '%s\t%s\tINFO\t%s\n' "$(date +%T)" "$1" "$2" | tee -a "$RES"; }
PIXI() { grep -E '^[0-9]{15}$' "$A/imsi" | grep -vx "$(SIMI)" | head -1; }  # Pixel の SIM の IMSI
grp() { sql "SELECT a.id FROM aps a WHERE a.tenant_id=$(tid) AND a.name='$GRP' AND a.deleted_at IS NULL"; }
serials() { sql "SELECT c.serial||' '||coalesce(c.revoked_at::text,'有効')||' '||c.issued_at FROM ap_certs c WHERE c.ap_id=$(grp) ORDER BY c.issued_at"; }
# retry <回数> <aka|akap>: つながるまで繰り返す（切り替えの直後など）。回数を echo
retry() {
	local n=$1 m=$2 a r
	for a in $(seq 1 "$n"); do
		r=$(simrun "$m" | tail -1)
		[ "$r" = rc=0 ] && { echo "$a"; return 0; }
		sleep 5
	done
	echo "$n"
	return 1
}

case ${1:-} in
csr) # 顧客の役で、グループの鍵と CSR を手順書（aka-ossbss の AP の接続の手順書 4.1）のとおりに作る（鍵は手元だけ）
	[ -e "$A/pki/$GRP.key" ] && { echo "鍵はある: $A/pki/$GRP.key"; exit 0; }
	(cd "$A/pki" && umask 077 && openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$GRP.key" -out "$GRP.csr" -subj "/CN=ap" 2> /dev/null)
	chmod 600 "$A/pki/$GRP.key"
	openssl req -in "$A/pki/$GRP.csr" -noout -text | grep -E 'Public Key Algorithm|ASN1 OID|NIST'
	;;
login-start) # Access のログイン画面でメールアドレスを送る（PIN はユーザーから。10 分で切れる）
	PW open --idle-timeout 0 > /dev/null 2>&1
	PW goto "$BASE/" | grep -E 'Page Title'
	UI "$S5/ui/login.js" "$ADMIN_EMAIL"
	;;
login-pin) # <PIN>
	UI "$S5/ui/pin.js" "${2:?PIN}"
	;;
setup) # テナント at1・at2、at1 の RadSec と配置（primary=edge-01、secondary=edge-02）、グループ（用途 unifi）、反映、PEM 3 つ
	UI "$T/ui/setup.js" "$TEN" "$TEN2" "$GRP" "$(python3 -I -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$A/pki/$GRP.csr")" > "$A/run/setup.txt"
	head -60 "$A/run/setup.txt"
	t=$(tid)
	row=$(sql "SELECT a.id||' '||c.serial FROM aps a JOIN ap_certs c ON c.ap_id=a.id WHERE a.tenant_id=$t AND a.name='$GRP' AND a.deleted_at IS NULL AND c.revoked_at IS NULL ORDER BY c.issued_at DESC LIMIT 1")
	echo "グループの ID とシリアル: $row"
	"$0" pem
	sql "SELECT 'port', port FROM tenant_radsec WHERE tenant_id=$t"
	applied 300
	;;
pem) # 画面からグループの最新の証明書とサーバー CA を取り出し、UniFi に入れる PEM 3 つ（証明書・鍵・CA）を $A/unifi に置く
	t=$(tid)
	row=$(sql "SELECT a.id||' '||c.serial FROM aps a JOIN ap_certs c ON c.ap_id=a.id WHERE a.tenant_id=$t AND a.name='$GRP' AND a.deleted_at IS NULL AND c.revoked_at IS NULL ORDER BY c.issued_at DESC LIMIT 1")
	UI "$T/ui/fetch.js" "/tenants/$t/radsec/server-ca.pem" > "$A/unifi/server-ca.pem"
	UI "$T/ui/fetch.js" "/tenants/$t/aps/${row%% *}/certs/${row##* }/pem" > "$A/unifi/$GRP-cert.pem"
	install -m 600 "$A/pki/$GRP.key" "$A/unifi/$GRP-key.pem"
	for f in "$A/unifi/"*.pem; do
		printf '%s: ' "$(basename "$f")"
		case $f in
		*-key.pem) openssl pkey -in "$f" -noout && echo 鍵 ;;
		*) openssl x509 -in "$f" -noout -subject -enddate -ext subjectAltName 2> /dev/null | tr '\n' ' ' && echo ;;
		esac
	done
	# 証明書と鍵が対になっていること、証明書がサーバー CA の上の CA（テナントの CA）で署名されていることは openssl で確かめる
	[ "$(openssl x509 -in "$A/unifi/$GRP-cert.pem" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$A/unifi/$GRP-key.pem" -pubout | sha256sum)" ] && echo "証明書と鍵は対" || echo "証明書と鍵が対でない"
	openssl x509 -in "$A/unifi/server-ca.pem" -noout -fingerprint -sha256
	;;
dns) # スロットの名前を公開のリゾルバーで引く
	for s in primary secondary; do
		printf '%s.%s.%s: ' "$s" "$TEN" "$DNS_DOMAIN"
		dig +short @1.1.1.1 "$s.$TEN.$DNS_DOMAIN" | paste -sd' '
	done
	;;
tls) # AP の接続の手順書 4.4 の確かめを手元から（グループの証明書で TLS）。名前で照らすと通る。IPv4 アドレスで照らすと、
	# サーバー証明書に名前しか入っていないので合わない（名前を照らす AP にサーバーを IP アドレスで書くと、こうなる）
	# AT-11 の後は古い証明書が失効しているので、更新した証明書（-new）があればそれを使う（古いほうはエッジが CRL で断る）
	port=$(sql "SELECT port FROM tenant_radsec WHERE tenant_id=$(tid)")
	c=$GRP-cert k=$GRP-key
	[ -s "$A/unifi/$GRP-cert-new.pem" ] && c=$GRP-cert-new k=$GRP-key-new
	for s in primary secondary; do
		h=$s.$TEN.$DNS_DOMAIN ip=$(dig +short @1.1.1.1 "$s.$TEN.$DNS_DOMAIN" | tail -1)
		o=(-CAfile "$A/unifi/server-ca.pem" -cert "$A/unifi/$c.pem" -key "$A/unifi/$k.pem")
		v1=$(openssl s_client -connect "$h:$port" -servername "$h" -verify_hostname "$h" "${o[@]}" < /dev/null 2>&1 | grep -m1 'Verify return code')
		v2=$(openssl s_client -connect "$ip:$port" -verify_ip "$ip" "${o[@]}" < /dev/null 2>&1 | grep -m1 'Verify return code')
		echo "$s 名前で: ${v1:-応答なし} / IPv4 アドレスで: ${v2:-応答なし}"
	done
	;;
radius) # SIM の radius 側を登録する（IMSI は $A/imsi。vecgen 側はユーザーが登録済み）
	UI "$T/ui/radius.js" "$(imsis)" "$SSID" "$STO"
	;;
sim-status) # 端末の役（simwifi）の前提を確かめる
	ssh $C "cd $REMOTE && sudo ./simwifi status --iface $IFACE" < /dev/null
	;;
sim-id) # 検証機の SIM の IMSI を $A/sim-imsi に取る（SIM の認証は使わない）
	ssh $C "cd $REMOTE && sudo ./simwifi identity --method aka" < /dev/null | sed -n 's/^0\([0-9]\{15\}\)@.*/\1/p' > "$A/sim-imsi"
	chmod 600 "$A/sim-imsi"
	[ -s "$A/sim-imsi" ] && echo "検証機の SIM: $(cut -c1-6 "$A/sim-imsi")…$(cut -c12- "$A/sim-imsi")" || echo "IMSI を読めない"
	;;
status) # 配置の反映、エッジの接続、端末の役の状態
	applied 10
	for e in edge-01 edge-02; do echo "$e の接続: $(conns $e)"; done
	ssh $C "systemctl is-active aka-at-night 2> /dev/null; ls $REMOTE/run 2> /dev/null" < /dev/null | paste -sd' '
	;;
at01) # AT-01: 反映済みで、名前が引け、AP が primary（edge-01）につながっている（UniFi はサーバーを IPv4 アドレスで書く）
	applied 60
	"$0" dns
	"$0" tls
	c1=$(conns edge-01) c2=$(conns edge-02)
	echo "edge-01: $c1 / edge-02: $c2"
	edgelog edge-01 'TLS|tls|client' 6
	mark AT-01 "AP が primary（edge-01）に RadSec でつながっている（送り元 ${c1:-なし}）" "$(echo "$c1" | grep -qF "$HOME_IP"; echo $?)"
	;;
first) # AT-02〜AT-04: 端末の役で EAP-AKA（最初は再同期の見込み）と EAP-AKA'
	t=$(date +%s)
	auth AT-02 "EAP-AKA で認証が通る" aka accept
	r=$(radlog "$t" | grep -c EAP_RESYNC_CHALLENGE)
	if [ "$r" -gt 0 ]; then mark AT-04 "再同期（AUTS）が起きて、その後に通った（再同期 $r 回）" "$(radlog "$t" | grep -q AUTH_SUCCESS; echo $?)"; else info AT-04 "再同期は起きなかった（SIM と aka-vecgen の SQN がそろっていた）"; fi
	auth AT-03 "EAP-AKA' で認証が通る" akap accept
	radlog "$t" | grep AUTH_SUCCESS | tail -2
	;;
at05) # AT-05: 実際の NAS-Identifier を記録し、ルールの NAS-Identifier をその値にしても通る。終わったら * に戻す
	nas=$(radlog $(($(date +%s) - 86400)) | grep AUTH_SUCCESS | tail -1 | sed -n 's/.* nas=\([^ ]*\).*/\1/p')
	info AT-05a "AP が送る NAS-Identifier は「$nas」（グループなのでエッジはそのまま通す）"
	[ -n "$nas" ] && [ "$nas" != - ] || { echo "NAS-Identifier が分からない"; exit 1; }
	UI "$T/ui/policy.js" "$(SIMI)" "$nas"
	auth AT-05 "ルールの NAS-Identifier を実際の値にしても通る" aka accept
	UI "$T/ui/policy.js" "$(SIMI)" '*'
	;;
try) # try [aka|akap]: 端末の役で 1 回つないで、aka-radius のログを見る（記録しない）
	t=$(date +%s)
	simrun "${2:-aka}" | tail -1
	radlog "$t" "$(SIMI)"
	;;
at05b) # AT-05 の続き: ルールの NAS-Identifier が合わないと拒否され、拒否のログに SSID（Called-Station-Id の「:」の後ろ）が出る。終わったら * に戻す
	t=$(date +%s)
	UI "$T/ui/policy.js" "$(SIMI)" other-ap
	auth AT-05b "ルールの NAS-Identifier が合わないと拒否される" aka reject
	radlog "$t" | grep -E 'POLICY|DENIED' | tail -2
	UI "$T/ui/policy.js" "$(SIMI)" '*'
	;;
at06) # AT-06: セッションの一覧（Pixel はつないだまま、端末の役は今つないで切る）
	UI "$T/ui/text.js" "/sessions?imsi=$(imsis)" | sed -n '/セッション/,$p' | head -30
	;;
at07) # AT-07: radius 側を止めると拒否され、戻すと通る
	UI "$S5/ui/state.js" "$(SIMI)" radius inactive
	auth AT-07a "radius 側を止めると拒否される" aka reject
	UI "$S5/ui/state.js" "$(SIMI)" radius active
	auth AT-07b "radius 側を戻すと通る" aka accept
	;;
at08) # AT-08: 所属を別のテナント（at2）に付け替えると、at1 のエッジから来た認証は拒否される。戻すと通る
	UI "$T/ui/move.js" "$(SIMI)" "$TEN2"
	auth AT-08a "所属を別のテナントに付け替えると拒否される（刻印のテナントと合わない）" aka reject
	UI "$T/ui/move.js" "$(SIMI)" "$TEN"
	auth AT-08b "所属を戻すと通る" aka accept
	;;
at09) # AT-09: 送信元の範囲。手元の回線のアドレスで通り、範囲の外は TLS で受けず、空に戻すとまた通る
	t=$(tid)
	UI "$S5/ui/sources.js" "$t" "$HOME_IP/32" | tail -2
	sleep 10; applied 180
	n=$(retry 8 aka)
	mark AT-09a "範囲に手元の回線の公開のアドレスを入れても通る（$n 回目）" $?
	UI "$S5/ui/sources.js" "$t" "192.0.2.0/24" | tail -2
	sleep 10; applied 180
	auth AT-09b "範囲の外の送信元からはつながらない" aka reject
	l=$(edgelog edge-01 'unknown TLS client|ignoring' 2)
	echo "$l"
	mark AT-09c "エッジが範囲の外の接続を TLS で受けない（ログ）" "$([ -n "$l" ]; echo $?)"
	UI "$S5/ui/sources.js" "$t" "" | tail -2
	sleep 10; applied 180
	n=$(retry 12 aka)
	mark AT-09d "範囲を空に戻すとまた通る（$n 回目）" $?
	;;
at10) # AT-10: edge-01 のテナントのポートを nftables で止めて、secondary（edge-02）で通る。edge-02 で RADIUS の属性を記録する（AT-05 の Called-Station-Id）
	port=$(sql "SELECT port FROM tenant_radsec WHERE tenant_id=$(tid)")
	N edge-02 "sudo systemd-run --quiet --unit=aka-at10-cap --property=RuntimeMaxSec=600 /usr/bin/tcpdump -i wg-svc -nn -U -w /var/tmp/aka-at10.pcap 'udp dst port 1812'"
	N edge-01 "sudo systemd-run --quiet --unit=aka-at10-undo --on-active=900 /usr/sbin/nft delete table inet aka_at10 && sudo nft add table inet aka_at10 && sudo nft add chain inet aka_at10 pre '{ type filter hook prerouting priority -300 ; }' && sudo nft add rule inet aka_at10 pre tcp dport $port counter drop"
	t0=$SECONDS
	echo "== edge-01 のポート $port を止めた（$(date +%T)）"
	n=$(retry 12 aka)
	mark AT-10a "primary を止めると secondary に切り替わって通る（$n 回目、$((SECONDS - t0)) 秒）" $?
	c2=$(conns edge-02)
	mark AT-10b "AP が secondary（edge-02）につながっている（${c2:-なし}）" "$(echo "$c2" | grep -qF "$HOME_IP"; echo $?)"
	N edge-02 "sudo systemctl stop aka-at10-cap; sudo tcpdump -r /var/tmp/aka-at10.pcap -nn -vv 2> /dev/null; sudo rm -f /var/tmp/aka-at10.pcap" > "$A/run/at10-radius.txt"
	chmod 600 "$A/run/at10-radius.txt"
	grep -E 'NAS-Identifier|Called-Station|Called Station|Calling Station|NAS-Port-Type' "$A/run/at10-radius.txt" | sed 's/^ *//' | sort | uniq -c | grep -v probe | head -12
	N edge-01 "sudo nft list table inet aka_at10 | grep -o 'packets [0-9]*'; sudo nft delete table inet aka_at10 && sudo systemctl stop aka-at10-undo.timer"
	echo "== 戻した（$(date +%T)。止めていたのは $((SECONDS - t0)) 秒）。AP が primary に戻るかを 10 分見る"
	t1=$SECONDS
	while [ $((SECONDS - t1)) -lt 600 ]; do
		c1=$(conns edge-01)
		echo "$(date +%T) edge-01: ${c1:-なし} / edge-02: $(conns edge-02)"
		echo "$c1" | grep -qF "$HOME_IP" && break
		sleep 30
	done
	info AT-10c "止めるのをやめた後、AP が primary に戻ったか: ${c1:-戻っていない}（$((SECONDS - t1)) 秒）"
	;;
revoke) # revoke <シリアル> [superseded|keyCompromise]: グループの証明書を 1 枚失効させ、反映する（宣言の版が上がる）
	UI "$T/ui/revoke.js" "$(tid)" "$(grp)" "${2:?シリアル}" "${3:-superseded}"
	serials
	"$0" apply
	;;
apply) # 「反映する」を押して、2 つの配置が反映済みになるのを待つ
	UI "$T/ui/apply.js" "$(tid)"
	applied 120
	;;
renew-rsa) # RSA 2048 の鍵（PKCS#1）と CSR で証明書を更新し、PEM（-rsa）を置く（RSA の鍵しか受けない AP の確かめ用。UniFi は P-256 でつながる）
	(cd "$A/pki" && umask 077 && openssl genrsa -traditional -out "$GRP-rsa.key" 2048 2> /dev/null && openssl req -new -key "$GRP-rsa.key" -out "$GRP-rsa.csr" -subj "/CN=ap")
	UI "$T/ui/renew.js" "$(tid)" "$GRP" "$(python3 -I -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$A/pki/$GRP-rsa.csr")"
	new=$(serials | tail -1 | cut -d' ' -f1)
	UI "$T/ui/fetch.js" "/tenants/$(tid)/aps/$(grp)/certs/$new/pem" > "$A/unifi/$GRP-rsa-cert.pem"
	install -m 600 "$A/pki/$GRP-rsa.key" "$A/unifi/$GRP-rsa-key.pem"
	[ "$(openssl x509 -in "$A/unifi/$GRP-rsa-cert.pem" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$A/unifi/$GRP-rsa-key.pem" -pubout | sha256sum)" ] && echo "RSA の証明書と鍵は対" || echo "RSA の証明書と鍵が対でない"
	openssl x509 -in "$A/unifi/$GRP-rsa-cert.pem" -noout -subject -issuer -serial -enddate; head -1 "$A/unifi/$GRP-rsa-key.pem"
	;;
at11-renew) # AT-11 の前半: 新しい鍵と CSR で証明書を更新し、UniFi に入れ替える PEM（-new）を置く。UniFi は入れ替えた後に AP の再起動が要る
	(cd "$A/pki" && umask 077 && openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$GRP-2.key" -out "$GRP-2.csr" -subj "/CN=ap" 2> /dev/null)
	UI "$T/ui/renew.js" "$(tid)" "$GRP" "$(python3 -I -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$A/pki/$GRP-2.csr")"
	serials
	new=$(serials | tail -1 | cut -d' ' -f1)
	UI "$T/ui/fetch.js" "/tenants/$(tid)/aps/$(grp)/certs/$new/pem" > "$A/unifi/$GRP-cert-new.pem"
	install -m 600 "$A/pki/$GRP-2.key" "$A/unifi/$GRP-key-new.pem"
	"$0" apply # 更新で宣言の版が上がるので反映する（radsecproxy の設定は変わらない）
	[ "$(openssl x509 -in "$A/unifi/$GRP-cert-new.pem" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "$A/unifi/$GRP-key-new.pem" -pubout | sha256sum)" ] && echo "新しい証明書と鍵は対" || echo "新しい証明書と鍵が対でない"
	openssl x509 -in "$A/unifi/$GRP-cert-new.pem" -noout -subject -serial -enddate
	;;
at11-check) # AT-11 の後半: UniFi に入れ替えた後、古い証明書を失効させ、エッジのコンテナを再起動して張り直させても通る（新しい証明書を使っている）
	auth AT-11a "UniFi に新しい証明書を入れ替えた後も通る" aka accept
	old=$(serials | grep ' 有効 ' | head -1 | cut -d' ' -f1)
	echo "失効させる古い証明書: $old"
	UI "$T/ui/revoke.js" "$(tid)" "$(grp)" "$old" superseded
	serials
	"$0" apply
	sleep 90
	for s in primary secondary; do UI "$T/ui/restart.js" "$(tid)" "$s"; done
	sleep 15
	n=$(retry 12 aka)
	mark AT-11b "古い証明書を失効させ、接続を張り直させても通る（新しい証明書を使っている。$n 回目）" $?
	for e in edge-01 edge-02; do echo "$e: $(conns $e)"; done
	edgelog edge-01 'revoked|certificate' 4
	;;
night-start) # AT-12: 端末の役をつないだまま一晩置く（systemd の一時の unit。Session-Timeout ごとに認証し直す）
	date +%s > "$A/night-start"
	# 無線の口に IPv6 の RA でアドレスと既定の経路が付くと、検証機の IPv6 の通信が Wi-Fi に流れる。この口だけ止める（/proc なので再起動で戻る。night-stop で戻す）
	ssh $C "cd $REMOTE && mkdir -p run && { [ -s run/ipv6-orig.txt ] || echo \"\$(cat /proc/sys/net/ipv6/conf/$IFACE/accept_ra) \$(cat /proc/sys/net/ipv6/conf/$IFACE/autoconf)\" > run/ipv6-orig.txt; } && echo 0 | sudo tee /proc/sys/net/ipv6/conf/$IFACE/accept_ra /proc/sys/net/ipv6/conf/$IFACE/autoconf > /dev/null" < /dev/null
	ssh $C "cd $REMOTE && mkdir -p run && sudo systemd-run --unit=aka-at-night --property=KillSignal=SIGTERM \$PWD/simwifi connect --iface $IFACE --ssid $SSID --method aka --max-auth-failures 5 --log-file \$PWD/run/night.log && sleep 20 && systemctl is-active aka-at-night && sudo tail -n 3 run/night.log" < /dev/null
	;;
night-status) # AT-12 の途中の様子
	t=$(cat "$A/night-start")
	ssh $C "systemctl is-active aka-at-night; sudo grep -cE '\"msg\":\"connected\"' $REMOTE/run/night.log; sudo grep -cE 'connection lost' $REMOTE/run/night.log" < /dev/null | paste -sd' ' | sed 's/^/端末の役: 状態・接続した回数・切れた回数 = /'
	for i in $(grep -E '^[0-9]{15}$' "$A/imsi"); do echo "$(echo "$i" | cut -c1-6)… の認証の成功: $(radlog "$t" "$i" | grep -c AUTH_SUCCESS)（拒否 $(radlog "$t" "$i" | grep -cE 'REJECT|DENIED|INACTIVE'))"; done
	for e in edge-01 edge-02; do echo "$e の接続: $(conns $e)"; done
	;;
night-stop) # AT-12 の終わり: 端末の役を止めてまとめる
	"$0" night-status
	t=$(cat "$A/night-start")
	ssh $C "sudo systemctl stop aka-at-night; sudo cp $REMOTE/run/night.log /tmp/aka-night.log && sudo chown \$USER /tmp/aka-night.log" < /dev/null
	ssh $C "cd $REMOTE && [ -s run/ipv6-orig.txt ] && read ra ac < run/ipv6-orig.txt && echo \$ra | sudo tee /proc/sys/net/ipv6/conf/$IFACE/accept_ra > /dev/null && echo \$ac | sudo tee /proc/sys/net/ipv6/conf/$IFACE/autoconf > /dev/null && rm -f run/ipv6-orig.txt && echo \"無線の口の IPv6 の設定を戻した（accept_ra=\$ra autoconf=\$ac）\"" < /dev/null
	scp -q $C:/tmp/aka-night.log "$A/run/night.log" && ssh $C 'rm -f /tmp/aka-night.log' < /dev/null
	h=$((($(date +%s) - t) / 3600))
	ok=$(radlog "$t" | grep -c AUTH_SUCCESS)
	# 成功の回数だけでは判定しない（2026-11-17 の予行で、拒否 0 でも AP の張り直しの遅れでつながらない時間があった）。
	# 判定は、各 SIM の認証し直しの間隔（Session-Timeout からの遅れ）と、端末の役のつながらない時間を見て人が書く
	info AT-12x "端末の役を約 $h 時間つないだまま置いた（認証の成功 $ok 回）。判定は認証し直しの間隔とつながらない時間で行う"
	for i in $(grep -E '^[0-9]{15}$' "$A/imsi"); do echo "$(echo "$i" | cut -c1-6)… の認証の成功の時刻:"; radlog "$t" "$i" | grep AUTH_SUCCESS | awk '{print "  " $1}'; done
	;;
clean) # A6-10: 予行の片付け。SIM（両側を止めて物理削除）→ グループ（有効な証明書は画面が失効させる）→ 配置を外してエッジから消えるまで待つ → テナント at1・at2
	t=$(tid) t2=$(tid "$TEN2") g=$(grp)
	echo "テナント $t・$t2、グループ $g"
	UI "$T/ui/clean.js" subs "$t" "$t2" "$g" "$(imsis)"
	[ -n "$g" ] && UI "$T/ui/clean.js" group "$t" "$t2" "$g" "$(imsis)"
	sql "SELECT c.serial, coalesce(c.revoked_at::text, '有効'), c.revoke_reason FROM ap_certs c JOIN aps a ON a.id = c.ap_id WHERE a.tenant_id = $t ORDER BY c.issued_at"
	UI "$T/ui/clean.js" detach "$t" "$t2" "$g" "$(imsis)"
	for i in $(seq 1 36); do
		n=$(for e in edge-01 edge-02; do N $e "docker ps -q --filter name=radsecproxy-$TEN | wc -l"; done | paste -sd+ | bc)
		[ "$n" = 0 ] && break
		sleep 5
	done
	echo "エッジの radsecproxy-$TEN: ${n}（$((i * 5)) 秒）"
	UI "$T/ui/clean.js" tenants "$t" "$t2" "$g" "$(imsis)"
	sql "SELECT name, deleted_at FROM tenants WHERE id IN ($t, $t2)"
	sql "SELECT 'radsec', tenant_id, port, released_at FROM tenant_radsec WHERE tenant_id = $t"
	ssh $C "systemctl is-active aka-at-night 2> /dev/null; sudo rm -rf $REMOTE; ls ~/aka-work" < /dev/null
	;;
*)
	echo "段: csr login-start login-pin setup pem dns radius sim-status sim-id status at01 first at05 at06 at07 at08 at09 at10 at11-renew at11-check night-start night-status night-stop clean" >&2
	exit 2
	;;
esac
