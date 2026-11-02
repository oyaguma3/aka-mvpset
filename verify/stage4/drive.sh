#!/bin/bash
# 段階 4 の検証機の通し（概要 §18.9 の S4-9）の台本。手元で動かす。検証機は stage4.sh を ssh で呼び、画面は playwright-cli で開く。
#
#   SITE=<site.env のパス> WORK=<手元の作業ディレクトリ> ./drive.sh <段>
#
# site.env（公開しない）: BASE、OSSBSS_ACCESS_TEAM_DOMAIN、OSSBSS_ACCESS_AUD、ADMIN_EMAIL、TOKEN_FILE、DNS_DOMAIN、URN_PREFIX、C_ADDR、E_ADDR、FAKE_API_KEY
# 段の一覧は README.md。
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
. "${SITE:?}"
: "${WORK:?}"
mkdir -p "$WORK/files" "$WORK/pki"
RES=$WORK/results.tsv
C=simwifi
E=simwifi2
REMOTE='~/aka-work/stage4'
# IA・IA2・IA3 はテナント 1（alpha）、IB はテナント 2（bravo）、IC はテナント 3（charlie）の加入者
IA=440100000000001 IA2=440100000000002 IA3=440100000000003 IB=440100000000011 IC=440100000000021
PW() { (cd "$WORK" && playwright-cli -s=stage4 "$@"); }
# R <ホスト> <サブコマンド> [引数]: 検証機で stage4.sh を動かす。PASS / FAIL の行を結果に足す
R() {
	local h=$1 q="" a
	shift
	for a in "$@"; do q="$q $(printf '%q' "$a")"; done
	ssh "$h" "cd $REMOTE/tools && ./stage4.sh$q" 2>&1 | tee -a "$WORK/remote.log" | tee >(grep -E $'^[A-Z][0-9a-z]*\t(PASS|FAIL)\t' >> "$RES")
	sleep 0.2
}
Rq() { R "$@" > /dev/null; }
Rv() { R "$@" | tail -1; }
mark() { Rq "$C" mark "$@"; }

# W <METHOD> <パス> [名前=値 | 名前=@ファイル]...: 画面の要求を Cloudflare 越しに送る。状態の番号を WS に、本文を last.html・last.txt に残す
W() {
	local f=$WORK/run-http.js
	python3 -I "$T/web.py" build "$@" > "$WORK/req.b64" || return 1
	python3 -I - "$T/ui/http.js" "$f" "$BASE" "$WORK/req.b64" << 'PY'
import sys
src, dst, base, req = sys.argv[1:]
s = open(src, encoding="utf-8").read().replace("__BASE__", base).replace("__A1__", open(req).read().strip())
open(dst, "w", encoding="utf-8").write(s)
PY
	WS=$(PW --raw run-code --filename=run-http.js 2>&1 | python3 -I "$T/web.py" save "$WORK")
}
uuid() { python3 -I -c 'import uuid; print(uuid.uuid4())'; }
# UI <台本> [引数...]: ブラウザーの台本を動かす。__A1__ などを置き換える。結果の行を足す
UI() {
	local name=$1 f="$WORK/run-$1.js" out
	shift
	cp "$T/ui/$name.js" "$f"
	python3 -I - "$f" "$BASE" "$@" << 'PY'
import sys
f, base, *args = sys.argv[1:]
s = open(f, encoding="utf-8").read().replace("__BASE__", base)
for i, a in enumerate(args, 1):
    s = s.replace(f"__A{i}__", a)
open(f, "w", encoding="utf-8").write(s)
PY
	out=$(PW --raw run-code --filename="run-$name.js" 2>&1)
	python3 -I - "$out" "$RES" "$name" << 'PY'
import json, sys
raw, res, name = sys.argv[1:]
try:
    rows = json.loads(raw)
except Exception:
    print(f"E0\tFAIL\t台本 {name} の失敗: {raw[:400]}")
    open(res, "a", encoding="utf-8").write(f"E0\tFAIL\t台本 {name} の失敗: {raw[:300]}\n".replace("\n", " ") + "\n")
    sys.exit(0)
for r in rows:
    print("\t".join(r))
    if r[1] in ("PASS", "FAIL"):
        open(res, "a", encoding="utf-8").write("\t".join(r) + "\n")
PY
}
OPEN() { UI open "$(python3 -I -c 'import base64,json,sys; print(base64.b64encode(json.dumps(json.loads(sys.argv[1])).encode()).decode())' "$1")"; }

# 試しの PKI。業者の CA は模型（verify/r10 と同じ形）で、実物ではない（確認事項 S9-6）。鍵は手元で作る。
pki_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$P/$1.key" 2> /dev/null; }
pki_root() { # <名前> <Subject>
	pki_key "$1"
	openssl req -x509 -new -key "$P/$1.key" -subj "$2" -days 3650 -out "$P/$1.pem" \
		-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2> /dev/null
	pki_db "$1"
}
pki_db() {
	mkdir -p "$P/ca-$1"
	: > "$P/ca-$1/index.txt"
	echo 01 > "$P/ca-$1/crlnumber"
	printf '[ca]\ndefault_ca=d\n[d]\ndatabase=%s\ncrlnumber=%s\ndefault_md=sha256\ndefault_crl_days=7\n' "$P/ca-$1/index.txt" "$P/ca-$1/crlnumber" > "$P/ca-$1/ca.cnf"
}
pki_ca() { # <名前> <Subject> <発行する CA>
	pki_key "$1"
	openssl req -new -key "$P/$1.key" -subj "$2" 2> /dev/null |
		openssl x509 -req -CA "$P/$3.pem" -CAkey "$P/$3.key" -CAserial "$P/$3.srl" -CAcreateserial -days 3650 \
			-extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n') \
			-out "$P/$1.pem" 2> /dev/null
	pki_db "$1"
}
pki_leaf() { # <名前> <Subject> <発行する CA> [SAN]
	pki_key "$1"
	openssl req -new -key "$P/$1.key" -subj "$2" 2> /dev/null |
		openssl x509 -req -CA "$P/$3.pem" -CAkey "$P/$3.key" -CAserial "$P/$3.srl" -CAcreateserial -days 730 \
			-extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth,serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n%s' "${4:+subjectAltName=$4}") \
			-out "$P/$1.pem" 2> /dev/null
}
pki_crl() { openssl ca -config "$P/ca-$1/ca.cnf" -keyfile "$P/$1.key" -cert "$P/$1.pem" -gencrl -out "$P/$1.crl" 2> /dev/null; }
pki_revoke() { openssl ca -config "$P/ca-$1/ca.cnf" -keyfile "$P/$1.key" -cert "$P/$1.pem" -revoke "$P/$2.pem" 2> /dev/null; }

# AP の役の UDP のポート
PA1=31812 PBOX=31822 PFAKE=31832 PB1=31842 PB2=31852 PC1=31862 PCI=31872
# eap <場面> <内容> <IMSI> <aka|prime> <accept|reject|noreply> <event_id|-> <ポート> [SSID] [SQN の初期値]: noreply は応答がないこと
eap() {
	local id=$1 text=$2 imsi=$3 method=$4 expect=$5 ev=$6 port=$7 ssid=${8:-ssid1} sqn=${9:-000000000000} before=0 after=0 r run=$5 out
	[ "$expect" = noreply ] && run=accept
	[ "$ev" != - ] && before=$(Rv $C log-count "$ev" "$imsi")
	out=$(R $E eap "$imsi" "$method" "$run" "$port" "$ssid" "$sqn")
	r=$(echo "$out" | tail -1 | sed 's/^rc=//')
	if [ "$expect" = noreply ]; then
		echo "$out" | grep -qiE 'timeout|timed out'
		r=$?
	fi
	if [ "$ev" != - ]; then
		sleep 1
		after=$(Rv $C log-count "$ev" "$imsi")
		[ "$r" = 0 ] && [ "$after" -gt "$before" ]
		r=$?
	fi
	[ "$r" = 0 ] || echo "$out" | tail -4
	mark "$id" "$text" "$r"
	printf '%s\t%s\t%s\n' "$id" "$r" "$text"
}
# tlsj <場面> <内容> <エッジ> <slug> <ポート> <ACCEPT|REJECT> <主体> <証明書> <鍵> [スロット]: AP の機械から TLS を試し、エッジの radsecproxy のログで判定する
tlsj() {
	local id=$1 text=$2 edge=$3 slug=$4 port=$5 expect=$6 subj=$7 cert=$8 key=$9 slot=${10:-} host=$C ts got=REJECT
	[ "$edge" = edge-02 ] && host=$E
	[ -n "$slot" ] || { slot=primary; [ "$edge" = edge-02 ] && slot=secondary; }
	ts=$(ssh $host date +%s)
	R $E tls-try "$slot.$slug.$DNS_DOMAIN" "$port" "$cert" "$key" > /dev/null
	sleep 1
	ssh $host "docker exec $edge docker logs --since $ts radsecproxy-$slug 2>&1" > "$WORK/tlsj.txt"
	grep -qE "TLS connection from [^,]+, client [^,]+, subject $subj[,/]" "$WORK/tlsj.txt" && got=ACCEPT
	[ "$got" = "$expect" ] || tail -5 "$WORK/tlsj.txt"
	mark "$id" "$text（$edge: $got）" "$([ "$got" = "$expect" ]; echo $?)"
	printf '%s\t%s\t%s\n' "$id" "$got" "$text"
}

A=$WORK/apfiles
mkdir -p "$A"
reg() { # <テナント> <名前> <種類> <用途> <CSR>。証明書を apfiles/<CSR の名前>.pem に取り出す
	W POST "/tenants/$1/aps" name="$2" kind="$3" purpose="$4" csr="@$WORK/pki/$5.csr" idem="$(uuid)"
	[ "$WS" = 200 ] || { echo "reg $2: $WS"; sed -n 1,5p "$WORK/last.txt"; }
	pull_cert "$1" "$2" "$5"
}
pull_cert() { # <テナント> <名前> <出力>: 一番新しい証明書を取り出す
	local row
	row=$(apline "$1" "$2")
	W GET "/tenants/$1/aps/${row%% *}/certs/${row##* }/pem"
	cp "$WORK/last.html" "$A/$3.pem"
}
apline() { Rv $C sql "SELECT a.id||' '||c.serial FROM aps a JOIN ap_certs c ON c.ap_id=a.id WHERE a.tenant_id=$1 AND a.name='$2' AND a.deleted_at IS NULL ORDER BY c.issued_at DESC LIMIT 1"; }
sync_ap() { (cd "$A" && tar cf - .) | ssh $E "tar xf - -C $REMOTE/ap"; (cd "$A" && tar cf - .) | ssh $C "tar xf - -C $REMOTE/ap"; }
newap() { # <テナント> <名前> <種類> <用途> <ファイル名>: 鍵と CSR を作って登録する（反映はしない）
	openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$WORK/pki/$5.key" -out "$WORK/pki/$5.csr" -subj "/CN=ap" 2> /dev/null
	cp "$WORK/pki/$5.key" "$A/$5.key"
	reg "$1" "$2" "$3" "$4" "$5"
	sync_ap
}
revoke_ap() { # <テナント> <名前> <理由>
	local row
	row=$(apline "$1" "$2")
	W POST "/tenants/$1/aps/${row%% *}/certs/${row##* }/revoke" reason="$3"
}
# waitsql <SQL> <期待> <秒>: 値が期待になるまで待ち、かかった秒を出す
waitsql() {
	local i v
	for i in $(seq 1 "$3"); do
		v=$(Rv $C sql "$1")
		[ "$v" = "$2" ] && { echo "$i"; return 0; }
		sleep 1
	done
	echo "timeout($v)"
	return 1
}
# srcj <場面> <内容> <送信元> <ACCEPT|REJECT>: dind と同じネットワークから edge-01 へつなぎ、ログの送信元で判定する
srcj() {
	local ts got=REJECT
	ts=$(ssh $C date +%s)
	R $C src-try "$3" "primary.alpha.$DNS_DOMAIN" 20000 a-ap01n.pem a-ap01n.key > /dev/null
	sleep 1
	ssh $C "docker exec edge-01 docker logs --since $ts radsecproxy-alpha 2>&1" > "$WORK/srcj.txt"
	grep -qE "TLS connection from $3, client alpha-ap01," "$WORK/srcj.txt" && got=ACCEPT
	[ "$got" = "$4" ] || tail -5 "$WORK/srcj.txt"
	mark "$1" "$2（$3: $got）" "$([ "$got" = "$4" ]; echo $?)"
	printf '%s\t%s\t%s\n' "$1" "$got" "$2"
}

z16() { # 業者の CRL がエッジに届くまで待つ（最大 6 分）
	local i e
	for e in edge-01 edge-02; do
		for i in $(seq 1 12); do
			tlsj Z16try "試し（$i 回目）" $e bravo 20001 REJECT 'CN=Q2AA-AAAA-0002' m2.pem m2.key 2>&1 | tail -1 | grep -q $'\tREJECT\t' && break
			sleep 30
		done
	done
	sed -i '/^Z16try\t/d' "$RES"
	tlsj Z16 "業者の CRL を取り直すと、エッジの定期の取得（5 分以内）で失効した AP を断る（edge-01）" edge-01 bravo 20001 REJECT 'CN=Q2AA-AAAA-0002' m2.pem m2.key
	tlsj Z17 "edge-02 も断る" edge-02 bravo 20001 REJECT 'CN=Q2AA-AAAA-0002' m2.pem m2.key
}

info() { UI "$@" | grep -E $'\tINFO\t' | tail -1 | cut -f3-; }
waitlog() { # <event_id> <秒>: aka-ossbss のログに出るまで待つ
	local i
	for i in $(seq 1 "$2"); do
		[ "$(Rv $C ossbss-log-count "$1")" -gt 0 ] && { echo "$i"; return 0; }
		sleep 1
	done
	echo timeout
	return 1
}

f14() { # ずれの自動の修正: エッジの宣言の版を変える（送信元の範囲を勝手に足す）
	local t
	R $C drift-decl "$C_ADDR" 1 | tail -1
	t=$(R $C wait-decl "$C_ADDR" 1 180 | tail -1)
	mark F14 "エッジの宣言を直接変えても、ループが版の違いで送り直す（$t）" "$(case $t in ok*) echo 0 ;; *) echo 1 ;; esac)"
}

f_wipe() {
	local old new f2 n i
	# データを失ったエッジの復旧（運用ガイド 14.8）
	old=$(Rv $C sql "SELECT string_agg(server_serial, ' ' ORDER BY tenant_id) FROM placements WHERE edge_id='edge-02' AND deleted_at IS NULL")
	f2=$(R $E edge-wipe edge-02 | grep -E '^[0-9A-F]{2}:' | tail -1)
	echo "new fp: $f2"
	. "$WORK/edge-fps"
	R $C registry "edge-01=https://$C_ADDR:9447=$F1" "edge-02=https://$E_ADDR:9447=$f2" > /dev/null
	printf 'F1=%s\nF2=%s\n' "$F1" "$f2" > "$WORK/edge-fps"
	# DB の状態は次の周回まで前のままなので、番号が変わるまで待つ
	for i in $(seq 1 60); do
		new=$(Rv $C sql "SELECT string_agg(server_serial, ' ' ORDER BY tenant_id) FROM placements WHERE edge_id='edge-02' AND deleted_at IS NULL")
		[ "$(ssh $E "docker exec edge-02 docker ps --format '{{.Names}}'" | grep -c radsecproxy-)" = 3 ] && [ "$new" != "$old" ] && break
		sleep 5
	done
	for i in 1 2 3; do Rq $C wait-applied $i 420; done
	echo "serial: $old -> $new"
	n=$(Rv $C sql "SELECT count(*) FROM placements WHERE edge_id='edge-02' AND deleted_at IS NULL AND apply_result='ok' AND applied_revision>0")
	mark F18 "データを失ったエッジに宣言と新しい証明書を送り直して反映する（$n / 3。番号が変わる）" "$([ "$n" = 3 ] && [ "$old" != "$new" ]; echo $?)"
	tlsj F19 "復旧したエッジが AP を受ける" edge-02 alpha 20000 ACCEPT 'CN=alpha-ap01' a-ap01n.pem a-ap01n.key
	tlsj F20 "復旧したエッジが持ち込みの CA の AP を受ける" edge-02 bravo 20001 ACCEPT 'CN=Q2AA-AAAA-0001' m1.pem m1.key
}

phase=${1:?}
shift
case $phase in
prepare)
	. "$T/refs.env"
	set -e
	B0=$WORK/build
	mkdir -p "$B0"
	for h in $C $E; do ssh "$h" "mkdir -p $REMOTE/tools $REMOTE/edge $REMOTE/fake"; done
	ssh $C "mkdir -p $REMOTE/vecgen $REMOTE/radius $REMOTE/prov $REMOTE/ossbss $REMOTE/ca"
	for x in "aka-vecgen $VECGEN_REF vecgen s4vecgen-aka-vecgen:latest" "aka-radius $RADIUS_REF radius aka-radius:dev" \
		"aka-provisioner $PROVISIONER_REF prov aka-provisioner:dev" "aka-ossbss $OSSBSS_REF ossbss s4ossbss-aka-ossbss:latest" "radsec-ca $CA_REF ca radsec-ca:s4"; do
		set -- $x
		git -C ~/projects/"$1" archive "$2" | ssh $C "tar x -C $REMOTE/$3"
		rm -rf "${B0:?}/$1"
		mkdir -p "$B0/$1"
		git -C ~/projects/"$1" archive "$2" | tar x -C "$B0/$1"
		echo "== build $1"
		docker build -q --build-arg VERSION="${2:0:7}" -t "$4" "$B0/$1"
	done
	rm -rf "${B0:?}/radsec-edge"
	mkdir -p "$B0/radsec-edge"
	git -C ~/projects/radsec-edge archive "$EDGE_REF" | tar x -C "$B0/radsec-edge"
	echo "== build radsec-edge"
	docker build -q --build-arg VERSION="${EDGE_REF:0:7}" -t radsec-edge:s4 "$B0/radsec-edge"
	docker image inspect radsec-edge/radsecproxy:1.11.4-pc1 > /dev/null 2>&1 || docker build -q -t radsec-edge/radsecproxy:1.11.4-pc1 "$B0/radsec-edge/images/radsecproxy"
	docker pull -q fluent/fluent-bit:4.2.8 > /dev/null
	docker pull -q docker:29.9.2-dind > /dev/null
	docker build -q -t stage2-tools:dev "$T/../stage2"
	(cd ~/projects/eapaka_test && CGO_ENABLED=0 go build -o "$WORK/eapaka_test" ./cmd/eapaka_test 2> /dev/null || CGO_ENABLED=0 go build -o "$WORK/eapaka_test" .)
	for h in $C $E; do
		git -C ~/projects/radsec-edge archive "$EDGE_REF" | ssh "$h" "tar x -C $REMOTE/edge"
		scp -q "$T/stage4.sh" "$T/compose.ca.yaml" "$T/fake_dashboard.py" "$WORK/eapaka_test" "$h:aka-work/stage4/tools/"
		grep -v '^BASE=' "$SITE" | ssh "$h" "umask 077; cat > $REMOTE/site.env"
	done
	echo "== send"
	docker save s4vecgen-aka-vecgen:latest aka-radius:dev aka-provisioner:dev s4ossbss-aka-ossbss:latest radsec-ca:s4 | gzip -1 | ssh $C 'gunzip | docker load' | tail -6
	docker save radsec-edge:s4 radsec-edge/radsecproxy:1.11.4-pc1 fluent/fluent-bit:4.2.8 | gzip -1 > "$WORK/edge-images.tar.gz"
	docker save docker:29.9.2-dind stage2-tools:dev | gzip -1 > "$WORK/tools-images.tar.gz"
	for h in $C $E; do
		gunzip -c "$WORK/edge-images.tar.gz" | ssh "$h" "cat > $REMOTE/edge-images.tar"
		ssh "$h" 'gunzip | docker load' < "$WORK/tools-images.tar.gz" | tail -2
	done
	;;
pki)
	P=$WORK/pki
	# 偽の Dashboard API のサーバー証明書
	pki_root fakeca "/CN=Stage4 fake dashboard CA"
	pki_leaf fakesrv "/CN=fake-dashboard" fakeca "DNS:fake-dashboard"
	# Meraki 形の模型: 共通のルート → 2 段の共通の中間 → 組織の CA → RadSec 用の CA → AP
	pki_root mroot "/CN=Stage4 Lab Meraki Dashboard Root CA"
	pki_ca msub "/CN=Stage4 Lab Meraki Dashboard Cluster SubCA" mroot
	pki_ca mcluster "/CN=Stage4 Lab Meraki.com Cluster CA" msub
	pki_ca orgA "/CN=1608009" mcluster
	pki_ca featA "/CN=radsec-1608009" orgA
	pki_leaf mAp1 "/CN=Q2AA-AAAA-0001" featA
	pki_leaf mAp2 "/CN=Q2AA-AAAA-0002" featA
	pki_ca orgB "/CN=2700001" mcluster
	pki_ca featB "/CN=radsec-2700001" orgB
	pki_leaf mOther "/CN=Q2BB-BBBB-0001" featB
	for x in mAp1:featA mAp2:featA mOther:featB; do
		l=${x%%:*} f=${x##*:} o=orgA
		[ "$f" = featB ] && o=orgB
		cat "$P/$l.pem" "$P/$f.pem" "$P/$o.pem" "$P/mcluster.pem" "$P/msub.pem" > "$P/$l-chain.pem"
	done
	pki_crl featA
	# Mist 形の模型: 組織ごとの自己署名 CA → AP（CN は MAC の 12 桁）
	pki_root mistA "/O=Mist/OU=OrgCA/CN=11111111-aaaa-4bbb-8ccc-000000000001"
	pki_leaf mistAp1 "/CN=d420b0000001" mistA
	pki_leaf mistBad "/CN=not-a-mac-address" mistA
	pki_root mistB "/O=Mist/OU=OrgCA/CN=22222222-aaaa-4bbb-8ccc-000000000002"
	pki_leaf mistOther "/CN=d420b0000099" mistB
	# 手順書の 4.1 の形の、AP とグループの鍵と CSR
	for n in a-ap01 a-ap01n a-box a-fake a-new b-ap01 c-ap01 c-ap02; do
		openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$P/$n.key" -out "$P/$n.csr" -subj "/CN=ap" 2> /dev/null
	done
	scp -q "$P/fakeca.pem" "$C:aka-work/stage4/fake/ca.pem"
	scp -q "$P/fakesrv.pem" "$C:aka-work/stage4/fake/server.pem"
	scp -q "$P/fakesrv.key" "$C:aka-work/stage4/fake/server.key"
	scp -q "$P/featA.crl" "$C:aka-work/stage4/fake/crl.pem"
	scp -q "$T/fake_dashboard.py" "$C:aka-work/stage4/fake/fake_dashboard.py"
	ssh $C "chmod -R a+rX $REMOTE/fake"
	ls "$P" | wc -l
	;;
setup)
	: > "$RES"
	R $C setup-central
	loc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/")
	case $loc in
	30*cloudflareaccess.com*) r=0 ;;
	*) r=1 ;;
	esac
	mark C0 "ログインしていない要求は Access のログインへ送られる（${loc%% *}）" $r
	;;
edges)
	pin=$(ssh $C "cat $REMOTE/out/prov-pin")
	# Tailscale が転送のパケットを MASQUERADE し、dind は Docker が MASQUERADE するので、aka-radius には 2 台とも同じアドレス
	# （aka-radius のネットワークのゲートウェイ）に見える。この環境だけのことで、シークレットを 1 つにして 1 件で登録する（README）。
	s1=$(openssl rand -hex 24)
	printf 'S1=%s\n' "$s1" > "$WORK/edge-secrets"
	f1=$(ssh $C "cd $REMOTE/tools && ./stage4.sh edge-setup edge-01 $C_ADDR $s1 $pin" | tail -1)
	f2=$(ssh $E "cd $REMOTE/tools && ./stage4.sh edge-setup edge-02 $E_ADDR $s1 $pin" | tail -1)
	echo "fp: $f1 / $f2"
	printf 'F1=%s\nF2=%s\n' "$f1" "$f2" > "$WORK/edge-fps"
	R $C registry "edge-01=https://$C_ADDR:9447=$f1" "edge-02=https://$E_ADDR:9447=$f2"
	R $C check-downstream | tee "$WORK/check-downstream.txt"
	n=$(grep -c '接続できました' "$WORK/check-downstream.txt")
	mark I2 "aka-provisioner の check-downstream が 5 つの下流につながる（$n）" "$([ "$n" = 5 ]; echo $?)"
	# auth は aka-av に、acct は default のネットワークにいるので、送信元は別のゲートウェイになる。
	gw=$(ssh $C "docker inspect -f '{{(index .NetworkSettings.Networks \"aka-av\").Gateway}}' s4radius-auth-1")
	gw2=$(ssh $C "docker inspect -f '{{(index .NetworkSettings.Networks \"s4radius_default\").Gateway}}' s4radius-acct-1")
	Rq $C client-add "$gw" edges-lab-auth "$s1"
	Rq $C client-add "$gw2" edges-lab-acct "$s1"
	R $C ps | tee "$WORK/ps.txt"
	n=$(grep -c -E 'unhealthy|Restarting' "$WORK/ps.txt")
	mark I4 "中央とデータ面の全部のコンテナが動き、unhealthy がない" "$([ "$n" = 0 ]; echo $?)"
	for x in "$C edge-01" "$E edge-02"; do
		set -- $x
		st=$(ssh "$1" "docker exec $2 docker ps --format '{{.Names}} {{.Status}}'; docker exec $2 docker info --format 'live={{.LiveRestoreEnabled}}'; docker exec $2 ps | grep -c 'userland-proxy=false'; docker ps --filter name=$2 --format '{{.Ports}}'")
		echo "$st"
		n=$(echo "$st" | grep -c -E 'healthy\)|Up ')
		mark "I5${2##*-}" "$2 は dind で動き、userland-proxy オフ・live-restore オン。公開は Tailscale のアドレスだけ" "$(echo "$st" | grep -q 'live=true' && ! echo "$st" | grep -q '0.0.0.0'; echo $?)"
	done
	;;
login-start)
	PW open > /dev/null
	PW goto "$BASE/" | grep -E 'Page URL|Page Title' | sed -E 's#https?://[^ ]*#<url>#'
	;;
ledger) # エッジの台帳、テナント、RadSec の有効化と配置（運用ガイド 14.3・14.4）
	W POST /edges id=edge-99 name=x capacity=150 publicAddr="$C_ADDR" authUpstream="$C_ADDR:1812" acctUpstream="$C_ADDR:1813"
	mark D1 "登録簿にない ID のエッジは断る（$WS）" "$(grep -q '登録簿にこの ID のエッジがありません' "$WORK/last.txt"; echo $?)"
	W POST /edges id=edge-01 name=edge-01 capacity=150 publicAddr="$C_ADDR" authUpstream="$C_ADDR:1812" acctUpstream="$C_ADDR:1813"
	W POST /edges id=edge-02 name=edge-02 capacity=150 publicAddr="$E_ADDR" authUpstream="$C_ADDR:1812" acctUpstream="$C_ADDR:1813"
	n=$(Rv $C sql "SELECT count(*) FROM edges")
	mark D2 "エッジ 2 台を台帳に足せる（$n）" "$([ "$n" = 2 ]; echo $?)"
	UI register s4-alpha,s4-bravo,s4-charlie "$IA:1,$IA2:1,$IA3:1,$IB:2,$IC:3"
	i=1
	for slug in alpha bravo charlie; do
		W POST "/tenants/$i/radsec/enable" slug="$slug" idem="$(uuid)"
		echo "enable $slug: $WS"
		W POST "/tenants/$i/radsec/placements" slot=primary edge=edge-01
		echo "primary: $WS"
		W POST "/tenants/$i/radsec/placements" slot=secondary edge=edge-02
		echo "secondary: $WS"
		i=$((i + 1))
	done
	n=$(Rv $C sql "SELECT string_agg(slug||':'||port, ' ' ORDER BY tenant_id) FROM tenant_radsec")
	mark D3 "テナント 3 つを有効にでき、ポートは一番小さい空きから（$n）" "$([ "$n" = "alpha:20000 bravo:20001 charlie:20002" ]; echo $?)"
	for i in 1 2 3; do
		R $C wait-applied $i 300 | tail -1
	done
	n=$(Rv $C sql "SELECT count(*) FROM placements WHERE apply_result='ok' AND applied_revision>0 AND deleted_at IS NULL")
	mark D4 "2 台の実物のエッジに宣言・証明書・最初の反映が届く（$n / 6）" "$([ "$n" = 6 ]; echo $?)"
	W GET /radsec
	python3 -I -c '
import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
for m in re.findall(r"<tr><td>([^<]+)</td><td>(A|CNAME)</td><td>([^<]+)</td>",t): print(*m)
' "$WORK/last.html" | tee "$WORK/dns.txt"
	mark D5 "全テナントの画面に DNS のレコード 8 件が出る（$(wc -l < "$WORK/dns.txt")）" "$([ "$(wc -l < "$WORK/dns.txt")" = 8 ]; echo $?)"
	;;
n) # DNS の解決（確認事項 S9-3）
	bad=0
	while read -r name type value; do
		v=$(dig +short @1.1.1.1 "$name" "$type" | head -1)
		[ "${v%.}" = "$value" ] || { echo "1.1.1.1 $name: $v"; bad=1; }
	done < "$WORK/dns.txt"
	mark N1 "公開のリゾルバーで 8 件が引ける" $bad
	ssh $E "docker run --rm stage2-tools:dev getent hosts primary.alpha.$DNS_DOMAIN secondary.alpha.$DNS_DOMAIN" | tee "$WORK/n2.txt"
	mark N2 "AP のコンテナから名前が引ける（primary は edge-01、secondary は edge-02）" "$(grep -q "$C_ADDR" "$WORK/n2.txt" && grep -q "$E_ADDR" "$WORK/n2.txt"; echo $?)"
	;;
aps) # AP・グループ・持ち込みの CA を画面から登録し、反映し、AP の役を立てる（手順書 4 章、運用ガイド 14.10）
	P=$WORK/pki
	A=$WORK/apfiles
	: > "$WORK/aps.txt"
	reg 1 ap01 ap "" a-ap01
	reg 1 box group box a-box
	reg 1 fakeap ap "" a-fake
	reg 3 ap01 ap "" c-ap01
	reg 3 ap02 ap "" c-ap02
	n=$(grep -c 'BEGIN CERTIFICATE' "$A/a-box.pem")
	sub=$(openssl x509 -in "$A/a-box.pem" -noout -ext subjectAltName 2> /dev/null | tail -1)
	mark P1 "用途 box のグループの証明書を発行できる（$sub）" "$(echo "$sub" | grep -q "grp:alpha:box"; echo $?)"
	W GET /tenants/1/radsec/server-ca.pem
	cp "$WORK/last.html" "$A/server-ca.pem"
	# 未反映のうちは AP がつながらない
	s=$(Rv $C sql "SELECT revision||'/'||requested_revision FROM tenant_radsec WHERE tenant_id=1")
	W GET /tenants/1/radsec
	mark P2 "登録しただけでは未反映と出る（版 $s）" "$(grep -q '未反映の変更' "$WORK/last.txt"; echo $?)"
	# Meraki 形の模型: 誤ったキーは 502 の文で断られ、正しいキーで登録できる
	W POST /tenants/2/brought-cas name=meraki certPem="@$P/featA.pem" source=meraki merakiOrgId=1608009 merakiApiKey=wrong-key tenantOnly=1 idem="$(uuid)"
	mark P3 "偽の Dashboard API が 401 なら持ち込みの CA を登録できない（$WS）" "$([ "$WS" != 200 ]; echo $?)"
	W POST /tenants/2/brought-cas name=meraki certPem="@$P/featA.pem" source=meraki merakiOrgId=1608009 merakiApiKey="$FAKE_API_KEY" tenantOnly=1 idem="$(uuid)"
	mark P4 "Meraki 形の模型の CA を偽の Dashboard API で登録できる（$WS）" "$([ "$WS" = 200 ]; echo $?)"
	# Mist 形の模型: CRL なしは了承と照合の形が必須
	W POST /tenants/3/brought-cas name=mist certPem="@$P/mistA.pem" source=none tenantOnly=1 idem="$(uuid)"
	mark P5 "CRL なしは了承と照合の形がないと断る（$WS）" "$([ "$WS" = 400 ]; echo $?)"
	W POST /tenants/3/brought-cas name=mist certPem="@$P/mistA.pem" source=none noCrl=1 matchAttr=CN matchPattern='^[0-9a-f]{12}$' tenantOnly=1 idem="$(uuid)"
	mark P6 "Mist 形の模型の CA を CRL なしで登録できる（$WS）" "$([ "$WS" = 200 ]; echo $?)"
	W GET /tenants/3/radsec
	mark P7 "CRL のない CA があるとテナント全体の CRL の確認が止まると画面に出る" "$(grep -q 'CRL の確認が止まっています' "$WORK/last.txt"; echo $?)"
	for i in 1 2 3; do W POST "/tenants/$i/radsec/apply"; echo "apply $i: $WS"; R $C wait-applied $i 300 | tail -1; done
	n=$(Rv $C sql "SELECT count(*) FROM placements p JOIN tenant_radsec t USING (tenant_id) WHERE p.applied_revision=t.revision AND p.apply_result='ok' AND p.deleted_at IS NULL")
	mark P8 "「反映する」で 2 台の実物に順に届く（$n / 6）" "$([ "$n" = 6 ]; echo $?)"
	# AP の役
	cat "$P/mistAp1.pem" > "$A/mist1.pem"; cat "$P/mistBad.pem" > "$A/mistbad.pem"; cat "$P/mistOther.pem" > "$A/mistother.pem"
	cat "$P/mAp1-chain.pem" > "$A/m1.pem"; cat "$P/mAp2-chain.pem" > "$A/m2.pem"; cat "$P/mOther-chain.pem" > "$A/mother.pem"
	cp "$P/mistAp1.key" "$A/mist1.key"; cp "$P/mistBad.key" "$A/mistbad.key"; cp "$P/mistOther.key" "$A/mistother.key"
	cp "$P/mAp1.key" "$A/m1.key"; cp "$P/mAp2.key" "$A/m2.key"; cp "$P/mOther.key" "$A/mother.key"
	for n in a-ap01 a-box a-fake c-ap01 c-ap02 a-ap01n a-new b-ap01; do cp "$P/$n.key" "$A/$n.key"; done
	(cd "$A" && tar cf - .) | ssh $E "tar xf - -C $REMOTE/ap"
	(cd "$A" && tar cf - .) | ssh $C "mkdir -p $REMOTE/ap && tar xf - -C $REMOTE/ap"
	R $E ap-up a1 31812 alpha 20000 a-ap01.pem a-ap01.key
	R $E ap-up box 31822 alpha 20000 a-box.pem a-box.key
	R $E ap-up fake 31832 alpha 20000 a-fake.pem a-fake.key 2
	R $E ap-up b1 31842 bravo 20001 m1.pem m1.key
	R $E ap-up b2 31852 bravo 20001 m2.pem m2.key
	R $E ap-up c1 31862 charlie 20002 mist1.pem mist1.key
	R $E ap-up ci 31872 charlie 20002 c-ap01.pem c-ap01.key
	;;
e) # 認証（AP・グループ・持ち込みの CA。名前は実物の DNS で引き、証明書の名前も照合する）
	eap E1 "AP の証明書で EAP-AKA が通る" $IA aka accept AUTH_SUCCESS $PA1
	eap E2 "AP の証明書で EAP-AKA' が通る" $IA2 prime accept AUTH_SUCCESS $PA1
	eap E3 "AP の証明書で再同期が通る" $IA aka accept EAP_RESYNC_CHALLENGE $PA1 ssid1 00000F000000
	eap E4 "グループ（用途 box）の証明書で EAP-AKA が通る" $IA aka accept AUTH_SUCCESS $PBOX
	eap E5 "グループの証明書で EAP-AKA' が通る" $IA2 prime accept AUTH_SUCCESS $PBOX
	eap E6 "Meraki 形の模型（PartialChain）で EAP-AKA が通る" $IB aka accept AUTH_SUCCESS $PB1
	eap E7 "Meraki 形の模型で EAP-AKA' が通る" $IB prime accept AUTH_SUCCESS $PB1
	eap E8 "Mist 形の模型（CRL なしと照合の形）で EAP-AKA が通る" $IC aka accept AUTH_SUCCESS $PC1
	eap E9 "Mist 形の模型で EAP-AKA' が通る" $IC prime accept AUTH_SUCCESS $PC1
	eap E10 "持ち込みの CA と同じテナントの、こちらが発行した AP でも通る" $IC aka accept AUTH_SUCCESS $PCI
	R $E tls-try "primary.alpha.$DNS_DOMAIN" 20000 a-ap01.pem a-ap01.key | tee "$WORK/n3.txt"
	mark N3 "手順書の openssl で primary の名前のサーバー証明書を確かめられる" "$(grep -q 'Verify return code: 0' "$WORK/n3.txt"; echo $?)"
	R $E tls-try "secondary.alpha.$DNS_DOMAIN" 20000 a-ap01.pem a-ap01.key | tee "$WORK/n4.txt"
	mark N4 "secondary の名前のサーバー証明書も確かめられる" "$(grep -q 'Verify return code: 0' "$WORK/n4.txt"; echo $?)"
	R $E tls-try "edge-01.$DNS_DOMAIN" 20000 a-ap01.pem a-ap01.key | tee "$WORK/n5.txt"
	mark N5 "エッジの名前では証明書の名前が合わない（AP はスロットの名前を使う）" "$(grep -q 'Verify return code: 0' "$WORK/n5.txt"; [ $? != 0 ]; echo $?)"
	# NAS-Identifier: AP はエッジが <slug>-<名前> に置き換え、グループは AP が送った値を通す
	UI policy $IA2 alpha-ap01 '*' alpha-ap01
	eap E11 "ルールの NAS-Identifier が AP の名前なら、その AP から通る" $IA2 aka accept AUTH_SUCCESS $PA1
	eap E12 "同じルールでグループからは断られる（グループの NAS-Identifier は AP が送った値）" $IA2 aka reject AUTH_POLICY_DENIED $PBOX
	UI policy $IA2 '*' '*' -
	;;
a) # Accounting: AP からエッジを通して aka-radius へ
	sid=$(ssh $C "cd $REMOTE/tools && ./stage4.sh dapi radius GET '/sessions?imsi=$IA'" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["items"][0]["id"] if d["items"] else "")')
	echo "session: $sid"
	{
		R $E acct a1 Start 0 0 0 0 $IA "$sid"
		R $E acct a1 Interim-Update 60 1000 1 500 $IA "$sid"
		R $E acct a1 Stop 90 1500 1 800 $IA "$sid"
	} > "$WORK/acct.log"
	n=$(grep -c 'Accounting-Response' "$WORK/acct.log")
	mark A1 "Accounting がエッジを通って応答が返る（$n / 3）" "$([ "$n" = 3 ]; echo $?)"
	sleep 2
	today=$(TZ=Asia/Tokyo date +%F)
	echo "$today" > "$WORK/acct-date"
	u=$(ssh $C "cd $REMOTE/tools && ./stage4.sh dapi radius GET '/usage?date=$today'" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
print([(i['tenantId'],i['sessions'],i['seconds'],i['inOctets'],i['outOctets']) for i in d['items'] if i['imsi']=='$IA'])")
	echo "usage: $u"
	mark A2 "利用の集計がエッジの刻印（テナント 1）で手の計算と合う（$u）" "$(echo "$u" | grep -q '(1, 1, 90, 4294968796, 800)'; echo $?)"
	;;
x) # 拒否（段階 3 の 81 項目のうち、経路が変わるものだけをやり直す）
	eap X1 "AP が偽の刻印（テナント 2）を付けても、他のテナントの IMSI は断られる" $IB aka reject AUTH_POLICY_DENIED $PFAKE
	eap X2 "偽の刻印はエッジが消して付け直すので、自分のテナントの IMSI は通る" $IA aka accept AUTH_SUCCESS $PFAKE
	eap X3 "他のテナントの IMSI は拒否（AP）" $IB aka reject AUTH_POLICY_DENIED $PA1
	eap X4 "他のテナントの IMSI は拒否（Meraki 形の模型）" $IA aka reject AUTH_POLICY_DENIED $PB1
	eap X5 "他のテナントの IMSI は拒否（Mist 形の模型）" $IA aka reject AUTH_POLICY_DENIED $PC1
	UI policy $IA3 '*' corp -
	eap X6 "SSID が認可ポリシーと違えば拒否" $IA3 aka reject AUTH_POLICY_DENIED $PA1
	UI state radius inactive $IA
	eap X7 "画面で radius 側を止めると拒否" $IA aka reject AUTH_SUBSCRIBER_INACTIVE $PA1
	UI state radius active $IA
	UI state vecgen inactive $IA
	eap X8 "画面で vecgen 側を止めると拒否（取得先が断る）" $IA aka reject VECTOR_REJECTED $PA1
	UI state vecgen active $IA
	eap X9 "両方を戻すと通る" $IA aka accept AUTH_SUCCESS $PA1
	tlsj X10 "Meraki 形の模型の別の組織の AP は TLS で断る" edge-01 bravo 20001 REJECT 'CN=Q2BB-BBBB-0001' mother.pem mother.key
	tlsj X11 "Mist 形の模型の別の組織の AP は TLS で断る" edge-01 charlie 20002 REJECT 'CN=d420b0000099' mistother.pem mistother.key
	tlsj X12 "Mist 形の模型の CA が出した、照合の形に合わない証明書は断る" edge-01 charlie 20002 REJECT 'CN=not-a-mac-address' mistbad.pem mistbad.key
	tlsj X13 "別のテナントの AP の証明書は断る" edge-01 alpha 20000 REJECT 'CN=charlie-ap01' c-ap01.pem c-ap01.key
	tlsj X14 "比べる基準: 正しい AP の証明書は受ける（同じ確かめ方）" edge-01 alpha 20000 ACCEPT 'CN=alpha-ap01' a-ap01.pem a-ap01.key
	;;
z) # 証明書（失効、CRL のないテナント、更新）
	# 失効が全エッジに届く
	newap 1 rev1 ap "" z-rev1
	W POST /tenants/1/radsec/apply
	Rq $C wait-applied 1 300
	tlsj Z1 "新しい AP は反映の後に edge-01 に受けられる" edge-01 alpha 20000 ACCEPT 'CN=alpha-rev1' z-rev1.pem z-rev1.key
	tlsj Z2 "新しい AP は反映の後に edge-02 にも受けられる" edge-02 alpha 20000 ACCEPT 'CN=alpha-rev1' z-rev1.pem z-rev1.key
	revoke_ap 1 rev1 keyCompromise
	echo "revoke: $WS"
	t=$(waitsql "SELECT NOT crl_dirty FROM tenant_radsec WHERE tenant_id=1" t 180)
	echo "crl delivered in ${t}s"
	tlsj Z3 "失効させた証明書は CRL の取り直しで edge-01 が断る（反映なし。${t} 秒）" edge-01 alpha 20000 REJECT 'CN=alpha-rev1' z-rev1.pem z-rev1.key
	tlsj Z4 "失効させた証明書は edge-02 も断る" edge-02 alpha 20000 REJECT 'CN=alpha-rev1' z-rev1.pem z-rev1.key
	tlsj Z5 "同じテナントのほかの AP は続けて受ける" edge-01 alpha 20000 ACCEPT 'CN=alpha-ap01' a-ap01.pem a-ap01.key
	# AP の証明書の更新（手順書 5 章）: 新旧の両方が有効な間はどちらでもつながり、古いものを失効させる
	row=$(apline 1 ap01)
	old=${row##* }
	W POST "/tenants/1/aps/${row%% *}/renew" csr="@$WORK/pki/a-ap01n.csr" idem="$(uuid)"
	pull_cert 1 ap01 a-ap01n
	sync_ap
	tlsj Z6 "更新した証明書は反映なしでつながる" edge-01 alpha 20000 ACCEPT 'CN=alpha-ap01' a-ap01n.pem a-ap01n.key
	tlsj Z7 "更新の間は古い証明書もつながる" edge-01 alpha 20000 ACCEPT 'CN=alpha-ap01' a-ap01.pem a-ap01.key
	W POST "/tenants/1/aps/${row%% *}/certs/$old/revoke" reason=superseded
	waitsql "SELECT NOT crl_dirty FROM tenant_radsec WHERE tenant_id=1" t 180 > /dev/null
	tlsj Z8 "古い証明書を失効させると断る" edge-01 alpha 20000 REJECT 'CN=alpha-ap01' a-ap01.pem a-ap01.key
	tlsj Z9 "新しい証明書は続けて受ける" edge-02 alpha 20000 ACCEPT 'CN=alpha-ap01' a-ap01n.pem a-ap01n.key
	R $E ap-up a1 $PA1 alpha 20000 a-ap01n.pem a-ap01n.key | tail -1
	eap Z10 "更新した証明書の AP で認証が通る" $IA aka accept AUTH_SUCCESS $PA1
	# CRL のないテナント（Mist 形の模型）
	revoke_ap 3 ap02 keyCompromise
	waitsql "SELECT NOT crl_dirty FROM tenant_radsec WHERE tenant_id=3" t 180 > /dev/null
	tlsj Z11 "CRL のないテナントでは、失効させてもこちらが発行した証明書が TLS を通る（画面の警告のとおり）" edge-01 charlie 20002 ACCEPT 'CN=charlie-ap02' c-ap02.pem c-ap02.key
	W POST "/tenants/3/aps/$(apline 3 ap02 | cut -d' ' -f1)/delete"
	echo "delete: $WS"
	Rq $C wait-applied 3 300
	tlsj Z12 "AP を削除するとすぐ反映し、断る" edge-01 charlie 20002 REJECT 'CN=charlie-ap02' c-ap02.pem c-ap02.key
	tlsj Z13 "edge-02 も断る" edge-02 charlie 20002 REJECT 'CN=charlie-ap02' c-ap02.pem c-ap02.key
	W POST /tenants/3/aps name=ap02 kind=ap csr="@$WORK/pki/c-ap02.csr" idem="$(uuid)"
	mark Z14 "削除した名前の使い回しを断る（$WS）" "$(grep -qE '使い回|使えません' "$WORK/last.txt" && [ "$WS" != 200 ]; echo $?)"
	# Meraki 形の模型: 業者の側で失効させ、CRL を取り直す
	tlsj Z15 "比べる基準: Meraki 形の模型の 2 台目の AP が受けられる" edge-01 bravo 20001 ACCEPT 'CN=Q2AA-AAAA-0002' m2.pem m2.key
	P=$WORK/pki
	pki_revoke featA mAp2
	pki_crl featA
	scp -q "$P/featA.crl" "$C:aka-work/stage4/fake/crl.pem"
	W POST /tenants/2/brought-cas/brought.bravo.meraki/refresh
	echo "refresh: $WS"
	# 画面の「CRL を取り直す」は radsec-ca までで、エッジは定期の取得（EDGE_CRL_INTERVAL。既定 5 分）で読む（README の「見つけたこと」）
	z16
	tlsj Z18 "同じ業者の CA の別の AP は続けて受ける" edge-01 bravo 20001 ACCEPT 'CN=Q2AA-AAAA-0001' m1.pem m1.key
	;;
z16) z16 ;;
zr) # エッジの証明書の自動の更新（SQL で期限を近づけ、毎日の処理の時刻を今の直後にする。製品に試し用の口は足さない）
	old=$(Rv $C sql "SELECT string_agg(server_serial||'/'||probe_serial, ' ' ORDER BY edge_id) FROM placements WHERE tenant_id=1 AND deleted_at IS NULL")
	echo "old: $old"
	R $C sql "UPDATE placements SET server_not_after=now()+interval '20 days', probe_not_after=now()+interval '20 days' WHERE tenant_id=1 AND deleted_at IS NULL"
	at=$(TZ=Asia/Tokyo date -d '+2 minutes' +%H:%M)
	R $C set-ossbss-env OSSBSS_RADSEC_RENEW_AT "$at" | tail -1
	for i in $(seq 40); do
		new=$(Rv $C sql "SELECT string_agg(server_serial||'/'||probe_serial, ' ' ORDER BY edge_id) FROM placements WHERE tenant_id=1 AND deleted_at IS NULL")
		[ "$new" != "$old" ] && break
		sleep 10
	done
	echo "new: $new"
	mark Z20 "期限が近いエッジの証明書を毎日の処理で出し直す" "$([ "$new" != "$old" ]; echo $?)"
	waitsql "SELECT count(*)=0 FROM placements WHERE tenant_id=1 AND deleted_at IS NULL AND (cardinality(superseded_serials)>0 OR cert_apply_needed OR renew_requested)" t 300 > /dev/null
	Rq $C wait-applied 1 300
	crl=$(ssh $C "curl -sS http://$C_ADDR:8449/crl/server.pem" | openssl crl -noout -text | tr 'A-F' 'a-f')
	revoked=0
	for s in $(echo "$old" | tr ' /' '\n\n' | sort -u); do echo "$crl" | grep -q "$(echo "$s" | sed 's/^0*//')" && revoked=$((revoked + 1)); done
	ca=$(ssh $C "curl -sS http://$C_ADDR:8449/crl/tenant.alpha.pem" | openssl crl -noout -text | tr 'A-F' 'a-f')
	for s in $(echo "$old" | tr ' /' '\n\n' | sort -u); do echo "$ca" | grep -q "$(echo "$s" | sed 's/^0*//')" && revoked=$((revoked + 1)); done
	mark Z21 "反映の後に古いサーバー証明書とヘルスチェック用の証明書を superseded で失効させる（$revoked / 4）" "$([ "$revoked" = 4 ]; echo $?)"
	for x in "primary edge-01" "secondary edge-02"; do
		set -- $x
		s=$(Rv $C sql "SELECT upper(server_serial) FROM placements WHERE tenant_id=1 AND edge_id='$2' AND deleted_at IS NULL")
		got=$(ssh $E "cd $REMOTE/ap && (sleep 1) | timeout 6 openssl s_client -connect $1.alpha.$DNS_DOMAIN:20000 -CAfile server-ca.pem -cert a-ap01n.pem -key a-ap01n.key 2> /dev/null | openssl x509 -noout -serial" | cut -d= -f2)
		echo "$2: $s / $got"
		mark "Z22$1" "$2 が新しいサーバー証明書で応える" "$([ "$(echo "$s" | sed 's/^0*//')" = "$(echo "$got" | sed 's/^0*//')" ]; echo $?)"
	done
	eap Z23 "更新の後も認証が通る" $IA aka accept AUTH_SUCCESS $PA1
	;;
s) # 送信元の範囲。別の機械からは Tailscale の MASQUERADE で実際のアドレスが見えないので、dind と同じ Docker のネットワークの AP の役で判定する（README）
	W POST /tenants/1/radsec/sources sources="$(printf '192.0.2.0/24')"
	echo "sources: $WS"
	Rq $C wait-applied 1 300
	tlsj S1 "範囲の外（別の機械からの Tailscale 越し）は断る" edge-01 alpha 20000 REJECT 'CN=alpha-ap01' a-ap01n.pem a-ap01n.key
	W POST /tenants/1/radsec/sources sources="$(printf '172.31.94.50/32\n192.0.2.0/24')"
	Rq $C wait-applied 1 300
	srcj S2 "範囲の内のアドレスから受ける（送信元がエッジの Docker の公開を通っても保たれる）" 172.31.94.50 ACCEPT
	srcj S3 "同じネットワークの範囲の外のアドレスは断る" 172.31.94.60 REJECT
	n=$(Rv $C sql "SELECT count(*) FROM placements WHERE tenant_id=1 AND deleted_at IS NULL AND apply_result='ok'")
	mark S4 "範囲の変更は人が押さなくても順に反映する（$n / 2）" "$([ "$n" = 2 ]; echo $?)"
	W POST /tenants/1/radsec/sources sources=
	Rq $C wait-applied 1 300
	tlsj S5 "範囲を空に戻すと受ける" edge-01 alpha 20000 ACCEPT 'CN=alpha-ap01' a-ap01n.pem a-ap01n.key
	;;
h) # 反映（2 台の実物で順に、途中の失敗、やり直す）
	newap 1 h1 ap "" z-h1
	UI apply 1
	R $C order-watch 1 240 | tee "$WORK/order.txt"
	mark H1 "「反映する」のボタンで primary → secondary の順に届く（2 台目が 1 台目を追い越さない）" "$(tail -1 "$WORK/order.txt" | grep -q '^order=ok'; echo $?)"
	# 途中の失敗: edge-01 の agent を止める
	R $C dind edge-01 docker stop radsec-edge-radsec-edge-agent-1 > /dev/null
	newap 1 h2 ap "" z-h2
	W POST /tenants/1/radsec/apply
	echo "apply: $WS"
	t=$(waitsql "SELECT count(*)>0 FROM placements WHERE tenant_id=1 AND edge_id='edge-01' AND deleted_at IS NULL AND apply_result NOT IN ('','ok')" t 240)
	echo "failed after ${t}s"
	s=$(Rv $C sql "SELECT string_agg(edge_id||':'||applied_revision||':'||apply_result, ' ' ORDER BY edge_id)||' want='||(SELECT requested_revision FROM tenant_radsec WHERE tenant_id=1) FROM placements WHERE tenant_id=1 AND deleted_at IS NULL")
	echo "$s"
	W GET /tenants/1/radsec
	mark H2 "agent を止めた edge-01 の反映は失敗と出る（$s）" "$(grep -q '反映に失敗しました' "$WORK/last.txt"; echo $?)"
	want=$(Rv $C sql "SELECT requested_revision FROM tenant_radsec WHERE tenant_id=1")
	a2=$(Rv $C sql "SELECT applied_revision FROM placements WHERE tenant_id=1 AND edge_id='edge-02' AND deleted_at IS NULL")
	mark H3 "途中で失敗すると 2 台目に送らない（edge-02 の版 $a2 / 求めた版 $want）" "$([ "$a2" -lt "$want" ]; echo $?)"
	R $C dind edge-01 docker start radsec-edge-radsec-edge-agent-1 > /dev/null
	sleep 90
	s2=$(Rv $C sql "SELECT apply_result||':'||applied_revision FROM placements WHERE tenant_id=1 AND edge_id='edge-01' AND deleted_at IS NULL")
	mark H4 "agent が戻っても同じ版を自動でやり直さない（$s2）" "$(case $s2 in ok:*) [ "${s2##*:}" -lt "$want" ]; echo $? ;; *) echo 0 ;; esac)"
	pid=$(Rv $C sql "SELECT id FROM placements WHERE tenant_id=1 AND edge_id='edge-01' AND deleted_at IS NULL")
	W POST "/tenants/1/radsec/placements/$pid/retry"
	echo "retry: $WS"
	Rq $C wait-applied 1 300
	n=$(Rv $C sql "SELECT count(*) FROM placements WHERE tenant_id=1 AND deleted_at IS NULL AND applied_revision>=$want AND apply_result='ok'")
	mark H5 "「やり直す」で 1 台目、続いて 2 台目に届く（$n / 2）" "$([ "$n" = 2 ]; echo $?)"
	sync_ap
	tlsj H6 "やり直しの後は足した AP が edge-01 につながる" edge-01 alpha 20000 ACCEPT 'CN=alpha-h2' z-h2.pem z-h2.key
	tlsj H7 "edge-02 にもつながる" edge-02 alpha 20000 ACCEPT 'CN=alpha-h2' z-h2.pem z-h2.key
	;;
f) # 障害（エッジを止める、中央を止める、データを失う、ずれの自動の修正）
	# エッジを止めると AP が切り替わる
	ssh $C "docker stop edge-01" > /dev/null
	t0=$SECONDS
	a=0
	for i in $(seq 1 10); do
		a=$i
		r=$(R $E eap $IA aka accept $PA1 | tail -1)
		[ "$r" = rc=0 ] && break
		sleep 3
	done
	mark F1 "edge-01 を止めると AP は secondary に切り替わり認証が続く（$a 回目、$((SECONDS - t0)) 秒）" "$([ "$r" = rc=0 ]; echo $?)"
	ssh $E "docker logs --tail 5 ap-a1 2>&1 | grep -E 'Access-Accept' | tail -1" | tee "$WORK/f1.txt"
	mark F2 "応答は secondary から返っている" "$(grep -q 'from secondary' "$WORK/f1.txt"; echo $?)"
	eap F3 "止めている間も持ち込みの CA の AP は通る" $IB aka accept AUTH_SUCCESS $PB1
	sleep 70
	OPEN '[{"id":"F4","p":"/","want":["edge-01"],"deny":["エッジの切断、反映の失敗、証明書と CRL の期限の警告はありません"],"text":"ダッシュボードにエッジの切断が出る"}]'
	# 止めている間の反映は届かないエッジを飛ばす
	newap 1 f1 ap "" z-f1
	W POST /tenants/1/radsec/apply
	want=$(Rv $C sql "SELECT requested_revision FROM tenant_radsec WHERE tenant_id=1")
	t=$(waitsql "SELECT applied_revision>=$want AND apply_result='ok' FROM placements WHERE tenant_id=1 AND edge_id='edge-02' AND deleted_at IS NULL" t 240)
	mark F5 "届かないエッジを飛ばして 2 台目に反映する（${t} 秒）" "$(case $t in timeout*) echo 1 ;; *) echo 0 ;; esac)"
	W GET /tenants/1/radsec
	mark F6 "配置の行に「エッジに届きません」と出る" "$(grep -q 'エッジに届きません' "$WORK/last.txt"; echo $?)"
	# 戻ると追いつく
	ssh $C "docker start edge-01" > /dev/null
	Rq $C wait-applied 1 420
	a1=$(Rv $C sql "SELECT applied_revision||':'||apply_result FROM placements WHERE tenant_id=1 AND edge_id='edge-01' AND deleted_at IS NULL")
	mark F7 "edge-01 が戻ると追いつく（$a1 / 求めた版 $want）" "$([ "${a1%%:*}" -ge "$want" ] && [ "${a1##*:}" = ok ]; echo $?)"
	sync_ap
	tlsj F8 "戻った後は止めている間に足した AP を edge-01 が受ける" edge-01 alpha 20000 ACCEPT 'CN=alpha-f1' z-f1.pem z-f1.key
	# 中央を止めても認証が続く
	Rq $C stop oc aka-ossbss
	Rq $C stop pc aka-provisioner
	Rq $C stop cc radsec-ca
	sleep 3
	eap F9 "中央（aka-ossbss・aka-provisioner・radsec-ca）を止めても認証が通る（AP）" $IA aka accept AUTH_SUCCESS $PA1
	eap F10 "中央を止めても認証が通る（持ち込みの CA）" $IB aka accept AUTH_SUCCESS $PB1
	Rq $C start cc radsec-ca fake-dashboard
	Rq $C start pc aka-provisioner
	Rq $C start oc aka-ossbss
	sleep 15
	OPEN '[{"id":"F11","p":"/","want":["radsec-ca","edge-01","edge-02"],"text":"中央を戻すと画面が戻る"}]'
	# ずれの自動の修正: エッジから直接テナントを消す
	R $C eapi "$C_ADDR" DELETE /tenants/3 > /dev/null
	ssh $C "docker exec edge-01 docker ps --format '{{.Names}}'" | tee "$WORK/f12.txt"
	gone=$(grep -c radsecproxy-charlie "$WORK/f12.txt")
	back=1
	for i in $(seq 1 60); do
		s=$(R $C eapi "$C_ADDR" GET /tenants/3 | python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("appliedRevision"), d.get("revision"), d.get("pending"))
except Exception: print("x")')
		case $s in *" False") back=0; break ;; esac
		sleep 5
	done
	mark F12 "エッジから直接テナントを消しても、ループが証明書から出し直して戻す（消した直後のコンテナ $gone、$((i * 5)) 秒以内、$s）" "$([ "$gone" = 0 ] && [ "$back" = 0 ]; echo $?)"
	tlsj F13 "戻した後は Mist 形の模型の AP を受ける" edge-01 charlie 20002 ACCEPT 'CN=d420b0000001' mist1.pem mist1.key
	# ずれの自動の修正: エッジの宣言の版を変える（送信元の範囲を勝手に足す）
	f14
	# エッジにしかないテナント
	R $C drift-orphan "$C_ADDR" | tail -1
	t=$(waitlog RADSEC_ORPHAN_TENANT 180)
	mark F15 "エッジにしかないテナントを RADSEC_ORPHAN_TENANT で知らせる（${t} 秒）" "$(case $t in timeout*) echo 1 ;; *) echo 0 ;; esac)"
	W GET /edges/edge-01/orphans
	mark F16 "エッジにしかないテナントが画面に出る" "$(grep -q orphan99 "$WORK/last.txt"; echo $?)"
	W POST /edges/edge-01/orphans/99/delete
	n=$(R $C eapi "$C_ADDR" GET /tenants | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for t in d["items"] if t.get("slug")=="orphan99"))')
	mark F17 "システム管理者が画面で消せる（$WS。残り $n）" "$([ "$n" = 0 ]; echo $?)"
	f_wipe
	;;
f14) f14 ;;
f-wipe) f_wipe ;;
m1) # スロットの移動の前半（運用ガイド 14.9）。今は 2 台しかなく、同じエッジに同じテナントを 2 つ置けないので、secondary を外してから primary を移す
	pid=$(Rv $C sql "SELECT id FROM placements WHERE tenant_id=1 AND slot='secondary' AND deleted_at IS NULL")
	W POST "/tenants/1/radsec/placements/$pid/remove"
	echo "remove: $WS"
	t=$(waitsql "SELECT removed_at IS NOT NULL FROM placements WHERE id=$pid" t 240)
	n=$(ssh $E "docker exec edge-02 docker ps --format '{{.Names}}'" | grep -c radsecproxy-alpha)
	mark M1 "配置を外すとエッジから消える（${t} 秒。コンテナ $n）" "$([ "$n" = 0 ]; echo $?)"
	W GET /tenants/1/radsec
	mark M2 "配置が 1 つだけだと警告が出る" "$(grep -q '配置が 1 つだけです' "$WORK/last.txt"; echo $?)"
	pid=$(Rv $C sql "SELECT id FROM placements WHERE tenant_id=1 AND slot='primary' AND deleted_at IS NULL AND replaces IS NULL")
	echo "$pid" > "$WORK/move-old"
	W POST "/tenants/1/radsec/placements/$pid/move" edge=edge-02
	echo "move: $WS"
	t=$(waitsql "SELECT applied_revision>0 AND apply_result='ok' FROM placements WHERE tenant_id=1 AND replaces=$pid AND deleted_at IS NULL" t 300)
	mark M3 "移動を始めると新しいエッジに同じスロットの配置を足して反映する（${t} 秒）" "$(case $t in timeout*) echo 1 ;; *) echo 0 ;; esac)"
	W GET /tenants/1/radsec
	mark M4 "配置の行に「移動中」と出て、DNS のレコードの表が新しいエッジを指す" "$(grep -q '移動中' "$WORK/last.txt" && grep -qE "primary.alpha.$DNS_DOMAIN[^a-z]+CNAME[^a-z]+edge-02.$DNS_DOMAIN" "$WORK/last.txt"; echo $?)"
	eap M5 "移動の途中（DNS を書き換える前）は今のエッジで認証が続く" $IA aka accept AUTH_SUCCESS $PA1
	;;
m2) # スロットの移動の後半（DNS を書き換えた後）
	v=$(dig +short @1.1.1.1 "primary.alpha.$DNS_DOMAIN" A | tail -1)
	mark M6 "公開のリゾルバーで primary.alpha が新しいエッジを指す（$v）" "$([ "$v" = "$E_ADDR" ]; echo $?)"
	R $E ap-up a1 $PA1 alpha 20000 a-ap01n.pem a-ap01n.key | tail -2 | tee "$WORK/m7.txt"
	mark M7 "AP が名前を引き直すと新しいエッジにつながる" "$(grep -E 'connection to primary' "$WORK/m7.txt" | grep -q 'edge-02'; echo $?)"
	eap M8 "移動先のエッジで認証が通る" $IA aka accept AUTH_SUCCESS $PA1
	old=$(cat "$WORK/move-old")
	new=$(Rv $C sql "SELECT id FROM placements WHERE tenant_id=1 AND replaces=$old AND deleted_at IS NULL")
	W POST "/tenants/1/radsec/placements/$new/move-finish"
	echo "finish: $WS"
	t=$(waitsql "SELECT removed_at IS NOT NULL FROM placements WHERE id=$old" t 240)
	n=$(ssh $C "docker exec edge-01 docker ps --format '{{.Names}}'" | grep -c radsecproxy-alpha)
	mark M9 "「移動を完了」で古いエッジから消える（${t} 秒。コンテナ $n）" "$([ "$n" = 0 ]; echo $?)"
	eap M10 "移動を終えた後も認証が通る" $IA aka accept AUTH_SUCCESS $PA1
	;;
k) # 課金。事実と利用と RadSec の行を SQL で固定の過去の月（2026-10）に動かして締める。alpha は移動の途中なので配置を 2 と数える
	export GNUPGHOME=$WORK/gh
	rm -rf "${GNUPGHOME:?}"
	mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
	gpg --batch --passphrase '' --quick-generate-key 'stage4 <stage4@example.com>' default default 2y 2> /dev/null
	UI charging key "$(gpg --armor --export | base64 -w0)"
	# 取り込みは前の日までを読む。Accounting を流した日が今日なら、集計のキーを昨日に移す
	[ "$(cat "$WORK/acct-date")" = "$(TZ=Asia/Tokyo date +%F)" ] && Rq $C usage-yesterday
	info charging import > /dev/null
	Rq $C shift-month
	f=$(info charging close)
	echo "files: $f"
	d=$(info charging download "$WORK/files/")
	echo "download: $d"
	rm -rf "$WORK/files/x1"
	python3 -I "$T/../charging/verify-file.py" -o "$WORK/files/x1" "$WORK/files/$d" | tail -3
	mark K2 "Cloudflare 越しにダウンロードしたファイルが verify-file.py を通る（$d）" "${PIPESTATUS[0]}"
	python3 -I - "$WORK/files/x1" "$IA" << 'PY' | tee "$WORK/k3.txt"
import csv, os, sys
d, ia = sys.argv[1:]
root = next(r for r, _, fs in os.walk(d) if "tenants.csv" in fs)
ts = {r["tenant_id"]: r for r in csv.DictReader(open(f"{root}/tenants.csv", newline=""))}
want = {"1": (6, 1, 0, 2), "2": (0, 0, 1, 2), "3": (1, 0, 1, 2)}
ok = True
for k, (a, g, b, p) in want.items():
    got = tuple(int(ts[k][c]) for c in ("aps_end", "groups_end", "brought_cas_end", "placements_end"))
    print(k, got, (a, g, b, p))
    ok = ok and got == (a, g, b, p)
print("counts", 0 if ok else 1)
lines = list(csv.DictReader(open(f"{root}/lines.csv", newline="")))
a = [l for l in lines if l["imsi"] == ia and l["tenant_id"] == "1"]
u = a and a[0]["input_octets"] == "4294968796" and a[0]["output_octets"] == "800"
print("usage", 0 if u else 1, a[0]["input_octets"] if a else "-", a[0]["output_octets"] if a else "-")
PY
	mark K3 "数量（AP・グループ・持ち込みの CA・配置）が手の計算と合い、移動中の配置を 2 と数える" "$(grep '^counts' "$WORK/k3.txt" | cut -d' ' -f2)"
	mark K4 "RadSec を通した利用が行のファイルまで届く" "$(grep '^usage' "$WORK/k3.txt" | cut -d' ' -f2)"
	;;
g) # 画面（Cloudflare を通して役割 A〜D）
	Rq $C role system_admin NULL
	OPEN '[{"id":"G1","p":"/","status":200,"want":["RadSec の受け口","radsec-ca","エッジ edge-01","エッジ edge-02"],"text":"D のダッシュボードに RadSec の欄とエッジが出る"},
	{"id":"G2","p":"/radsec","status":200,"want":["DNS に登録するレコード","alpha","bravo","charlie"],"text":"D は全テナントの RadSec の画面を開ける"},
	{"id":"G3","p":"/edges","status":200,"want":["edge-01","edge-02"],"text":"D はエッジの一覧を開ける"},
	{"id":"G4","p":"/edges/edge-02","status":200,"want":["置いているテナント","エッジにしかないテナント"],"text":"D はエッジの詳細を開ける"},
	{"id":"G5","p":"/tenants/2/brought-cas","status":200,"want":["brought.bravo.meraki","meraki"],"deny":["'"$FAKE_API_KEY"'"],"text":"D は持ち込みの CA を開け、API キーは再表示されない"},
	{"id":"G6","p":"/tenants/3/brought-cas","status":200,"want":["brought.charlie.mist"],"text":"Mist 形の模型の CA の画面"}]'
	Rq $C role operator NULL
	OPEN '[{"id":"G10","p":"/radsec","status":200,"want":["DNS に登録するレコード"],"text":"C は全テナントの RadSec の画面を開ける"},
	{"id":"G11","p":"/edges","status":200,"want":["edge-01"],"deny":["台帳に足す"],"text":"C はエッジの一覧を開けるが台帳を変えられない"},
	{"id":"G12","p":"/tenants/2/brought-cas","status":200,"want":["brought.bravo.meraki"],"deny":["このテナント専用の CA であることを確かめました"],"text":"C は持ち込みの CA を見られるが登録できない"},
	{"id":"G13","p":"/tenants/1/radsec","status":200,"want":["edge-01","反映する"],"text":"C はテナントの RadSec を操作できる"}]'
	Rq $C role tenant_admin 1
	OPEN '[{"id":"G20","p":"/radsec","status":403,"text":"B は全テナントの RadSec を開けない"},
	{"id":"G21","p":"/edges","status":403,"text":"B はエッジの一覧を開けない"},
	{"id":"G22","p":"/tenants/1/radsec","status":200,"want":["primary","反映する"],"deny":["edge-01","edge-02","有効にする"],"text":"B は自分のテナントの RadSec をスロットで見られ、エッジの ID は出ない"},
	{"id":"G23","p":"/tenants/1/aps","status":200,"want":["登録して発行する","ap01"],"text":"B は AP を登録できる"},
	{"id":"G24","p":"/tenants/2/radsec","status":404,"text":"B は他のテナントの RadSec を開けない（存在を漏らさない 404）"},
	{"id":"G25","p":"/tenants/1/brought-cas","status":403,"text":"B は持ち込みの CA を開けない"}]'
	W POST /tenants/1/radsec/placements slot=tertiary edge=edge-01
	mark G26 "B は配置を足せない（$WS）" "$([ "$WS" = 403 ]; echo $?)"
	Rq $C role tenant_user 1
	OPEN '[{"id":"G30","p":"/tenants/1/radsec","status":200,"want":["primary"],"deny":["edge-01","edge-02","反映する"],"text":"A は自分のテナントの RadSec を見られるが反映できない"},
	{"id":"G31","p":"/tenants/1/aps","status":200,"want":["ap01"],"deny":["登録して発行する"],"text":"A は AP の一覧を見られるが登録できない"},
	{"id":"G32","p":"/tenants/2/aps","status":404,"text":"A は他のテナントの AP を開けない（存在を漏らさない 404）"},
	{"id":"G33","p":"/edges","status":403,"text":"A はエッジの一覧を開けない"}]'
	W POST /tenants/1/radsec/apply
	mark G34 "A は反映を求められない（$WS）" "$([ "$WS" = 403 ]; echo $?)"
	Rq $C role system_admin NULL
	OPEN '[{"id":"G40","p":"/tenants/1/aps/seen","status":200,"want":["ap01"],"text":"接続の状態の部品が読める"}]'
	;;
l) # 記録（RADSEC_* のログ、監査ログ、エッジの Fluent Bit、秘密の値が残らないこと）
	R $C logs-check | tee "$WORK/l.txt"
	R $E edge-logs-check edge-02 alpha | tee -a "$RES"
	R $C edge-logs-check edge-01 bravo | tee -a "$RES"
	W GET /tenants/2/aps/seen
	s=$(R $C eapi "$C_ADDR" GET /tenants/2/last-seen)
	echo "last-seen: $s" | cut -c1-300
	mark L9 "fluentd ドライバーでも last-seen が読める" "$(echo "$s" | grep -q 'lastSeen\|shared\|seen'; echo $?)"
	;;
b) # 持ち込みの CA を外す（運用ガイド 14.10）
	W POST /tenants/3/brought-cas/brought.charlie.mist/remove
	echo "remove: $WS"
	t=$(waitsql "SELECT deleted_at IS NOT NULL FROM brought_cas WHERE ca_id='brought.charlie.mist'" t 300)
	mark B1 "持ち込みの CA を外すと全配置に順に反映し、その後に radsec-ca で止める（${t} 秒）" "$(case $t in timeout*) echo 1 ;; *) echo 0 ;; esac)"
	n=$(Rv $C sql "SELECT count(*) FROM audit_log WHERE action='radsec.brought.disabled' AND target='brought.charlie.mist' AND actor_email='system'")
	mark B2 "止めたことが監査ログに残る（$n）" "$([ "$n" -gt 0 ]; echo $?)"
	Rq $C wait-applied 3 300
	tlsj B3 "外した後は Mist 形の模型の AP を断る（edge-01）" edge-01 charlie 20002 REJECT 'CN=d420b0000001' mist1.pem mist1.key
	tlsj B4 "edge-02 も断る" edge-02 charlie 20002 REJECT 'CN=d420b0000001' mist1.pem mist1.key
	tlsj B5 "こちらが発行した AP は続けて受ける" edge-01 charlie 20002 ACCEPT 'CN=charlie-ap01' c-ap01.pem c-ap01.key
	c=$(ssh $C "docker exec edge-01 grep -c 'CRLCheck on' /var/lib/radsec-edge/tenants/charlie/current/radsecproxy.conf")
	mark B6 "CRL のない CA がなくなるとテナント全体の CRL の確認が戻る（$c）" "$([ "$c" = 1 ]; echo $?)"
	eap B7 "外した後も発行した AP で認証が通る" $IC aka accept AUTH_SUCCESS $PCI
	;;
shots) # ブラウザーの見た目（役割 D。手で見るための画面の写し。公開のリポジトリには入れない）
	for x in home:/ radsec:/radsec edges:/edges edge:/edges/edge-02 tenant:/tenants/2/radsec aps:/tenants/1/aps brought:/tenants/2/brought-cas; do
		PW goto "$BASE${x#*:}" > /dev/null
		PW screenshot --filename="shot-${x%%:*}.png" --full-page > /dev/null 2>&1 || PW screenshot --filename="shot-${x%%:*}.png" > /dev/null
	done
	ls "$WORK"/shot-*.png
	;;
tools) # 道具だけを送り直す
	for h in $C $E; do scp -q "$T/stage4.sh" "$T/compose.ca.yaml" "$h:aka-work/stage4/tools/"; done
	;;
ve) # エッジの管理モードの画面（確かめた内容は README。開発用の設定で一時に radsec-edge を作り直す）
	ssh $C "docker exec -i edge-01 sh -c 'cat > /tmp/ui-edge.sh'" < "$T/ui-edge.sh"
	ssh $C "docker exec edge-01 sh /tmp/ui-edge.sh" 2>&1 | cut -c1-200
	;;
end)
	PW close > /dev/null 2>&1
	echo "PASS $(grep -c $'\tPASS\t' "$RES") / FAIL $(grep -c $'\tFAIL\t' "$RES")"
	;;
teardown) # 片付け（DNS のレコードと Tunnel のトークンのファイルは残す）
	ssh $C "cd $REMOTE/ossbss && docker compose down -v --remove-orphans 2>&1 | tail -1; cd ../ca && docker compose down -v --remove-orphans 2>&1 | tail -1; cd ../prov && docker compose down -v --remove-orphans 2>&1 | tail -1; cd ../radius/deployments && docker compose down -v --remove-orphans 2>&1 | tail -1; cd ../../vecgen && docker compose down -v --remove-orphans 2>&1 | tail -1; docker rm -fv edge-01 > /dev/null; docker network rm s4edge aka-av aka-provisioner aka-radius-admin 2> /dev/null; sudo rm -rf ~/aka-work/stage4; docker image prune -af > /dev/null; docker builder prune -af > /dev/null; docker ps -a -q | wc -l; docker images -q | wc -l; docker volume ls -q | wc -l; ls ~/aka-work/ossbss-dev"
	ssh $E "docker rm -f ap-a1 ap-box ap-fake ap-b1 ap-b2 ap-c1 ap-ci > /dev/null; docker rm -fv edge-02 > /dev/null; docker network rm s4edge 2> /dev/null; rm -rf ~/aka-work/stage4; docker image prune -af > /dev/null; docker builder prune -af > /dev/null; docker ps -a -q | wc -l; docker images -q | wc -l; docker volume ls -q | wc -l"
	;;
*)
	echo "unknown: $phase" >&2
	exit 2
	;;
esac
