#!/usr/bin/env bash
# RadSec の受け口のラボ（aka-mvpset の R10）。コンテナの中で動かし、結果を /work/results.tsv に書く。
# 業者の CA は公開の情報をもとにした模型（Meraki の PureCA の 5 段、Mist の組織の自己署名 CA）で、実物ではない。
set -uo pipefail
W=/work
cd "$W" || exit 1
mkdir -p pki crl run
RES=$W/results.tsv
: >"$RES"
STOCK=/usr/local/bin/radsecproxy-1.11.4
PC=/usr/local/bin/radsecproxy-pc
PCALL=/usr/local/bin/radsecproxy-pc-all
DEB=/usr/sbin/radsecproxy

record() { # <ID> <期待> <結果> <説明>
	local ok=NG
	[ "$2" = "$3" ] && ok=OK
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$ok" "$4" | tee -a "$RES"
}

# ---------------------------------------------------------------- PKI
key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "pki/$1.key" 2>/dev/null; }
mkroot() { # <名前> <Subject>
	key "$1"
	openssl req -x509 -new -key "pki/$1.key" -subj "$2" -days 3650 -out "pki/$1.pem" \
		-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
	mkdir -p "run/ca-$1"
	: >"run/ca-$1/index.txt"
	echo 01 >"run/ca-$1/crlnumber"
	printf '[ca]\ndefault_ca=d\n[d]\ndatabase=%s\ncrlnumber=%s\ndefault_md=sha256\ndefault_crl_days=7\n' \
		"$W/run/ca-$1/index.txt" "$W/run/ca-$1/crlnumber" >"run/ca-$1/ca.cnf"
}
mkca() { # <名前> <Subject> <発行する CA>
	key "$1"
	openssl req -new -key "pki/$1.key" -subj "$2" 2>/dev/null |
		openssl x509 -req -CA "pki/$3.pem" -CAkey "pki/$3.key" -CAserial "run/$3.srl" -CAcreateserial -days 3650 \
			-extfile <(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n') \
			-out "pki/$1.pem" 2>/dev/null
	mkdir -p "run/ca-$1"
	: >"run/ca-$1/index.txt"
	echo 01 >"run/ca-$1/crlnumber"
	printf '[ca]\ndefault_ca=d\n[d]\ndatabase=%s\ncrlnumber=%s\ndefault_md=sha256\ndefault_crl_days=7\n' \
		"$W/run/ca-$1/index.txt" "$W/run/ca-$1/crlnumber" >"run/ca-$1/ca.cnf"
}
mkleaf() { # <名前> <Subject> <発行する CA> [SAN]
	key "$1"
	openssl req -new -key "pki/$1.key" -subj "$2" 2>/dev/null |
		openssl x509 -req -CA "pki/$3.pem" -CAkey "pki/$3.key" -CAserial "run/$3.srl" -CAcreateserial -days 730 \
			-extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth,serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n%s' "${4:+subjectAltName=$4}") \
			-out "pki/$1.pem" 2>/dev/null
}
revoke() { openssl ca -config "run/ca-$1/ca.cnf" -keyfile "pki/$1.key" -cert "pki/$1.pem" -revoke "pki/$2.pem" 2>/dev/null; }
mkcrl() { openssl ca -config "run/ca-$1/ca.cnf" -keyfile "pki/$1.key" -cert "pki/$1.pem" -gencrl -out "crl/$1.pem" 2>/dev/null; }
cat_files() { # 束を作る: <出力> <pki か crl の名前（crl: を付けると CRL）>...
	local out=$1
	shift
	: >"$out"
	for x in "$@"; do
		case $x in
		crl:*) cat "crl/${x#crl:}.pem" >>"$out" ;;
		*) cat "pki/$x.pem" >>"$out" ;;
		esac
	done
}

echo "== PKI"
# Meraki の PureCA の模型: 共通のルート → 2 段の共通の中間 → 組織の CA → RadSec 用の CA → AP
mkroot mroot "/CN=Lab Meraki Dashboard Root CA"
mkca msub "/CN=Lab Meraki Dashboard Cluster SubCA" mroot
mkca mcluster "/CN=Lab Meraki.com Cluster CA" msub
mkca orgA "/CN=1608009" mcluster
mkca featA "/CN=radsec-1608009" orgA
mkleaf apA "/CN=Q2AA-AAAA-0001" featA
mkleaf apA2 "/CN=Q2AA-AAAA-0002" featA
mkca orgB "/CN=2700001" mcluster
mkca featB "/CN=radsec-2700001" orgB
mkleaf apB "/CN=Q2BB-BBBB-0001" featB
mkca extra "/CN=Lab Extra Tier CA" featA
mkleaf apDeep "/CN=Q2AA-DEEP-0001" extra
cat_files pki/chainA.pem featA orgA mcluster msub
cat_files pki/chainB.pem featB orgB mcluster msub
cat_files pki/chainDeep.pem extra featA orgA mcluster msub
# Mist の模型: 組織ごとの自己署名 CA → AP（CN は MAC の 12 桁）
mkroot mistA "/O=Mist/OU=OrgCA/CN=11111111-aaaa-4bbb-8ccc-000000000001"
mkleaf mistApA "/CN=d420b0000001" mistA
mkroot mistB "/O=Mist/OU=OrgCA/CN=22222222-aaaa-4bbb-8ccc-000000000002"
mkleaf mistApB "/CN=d420b0000099" mistB
# こちらのテナントのクライアントCA（テナントごとの自己署名）と、そこから発行する証明書
mkroot tenB "/CN=tenant-b client CA"
mkleaf grp1 "/CN=tenant-b-hq-unifi" tenB "URI:urn:example:grp:tenant-b:hq-unifi"
mkleaf grp1new "/CN=tenant-b-hq-unifi" tenB "URI:urn:example:grp:tenant-b:hq-unifi"
mkleaf grpX "/CN=tenant-b-unknown" tenB "URI:urn:example:grp:tenant-b:unknown"
mkleaf ap1 "/CN=tenant-b-ap-001" tenB "URI:urn:example:nas:tenant-b:ap-001"
mkroot tenC "/CN=tenant-c client CA"
mkleaf grpC "/CN=tenant-c-hq" tenC "URI:urn:example:grp:tenant-c:hq"
# エッジのサーバー証明書
mkroot srvca "/CN=Lab RadSec server CA"
mkleaf srv "/CN=primary.tenant-b.radsec.test" srvca "DNS:primary.tenant-b.radsec.test"
# CRL（失効なし）
for c in mroot msub mcluster orgA featA orgB featB tenB tenC mistA; do mkcrl "$c"; done
cp crl/featA.pem crl/featA-clean.pem
cp crl/tenB.pem crl/tenB-clean.pem
# 失効させた CRL（featA で apA2、tenB で grp1）は、使う場面で作る

# ---------------------------------------------------------------- エッジの役
EPID=
OFFSET=0
edge_start() { # <バイナリ> <CA の束> <CRLCheck on|off> <PartialChain on|off|none> <client ブロックの本文のファイル>
	local bin=$1 bundle=$2 crlc=$3 pcopt=$4 blocks=$5
	edge_stop
	{
		echo "ListenTLS 127.0.0.1:2083"
		echo "LogLevel 3"
		echo "tls tenant {"
		echo "    CACertificateFile $W/$bundle"
		echo "    CertificateFile $W/pki/srv.pem"
		echo "    CertificateKeyFile $W/pki/srv.key"
		echo "    CRLCheck $crlc"
		[ "$pcopt" != none ] && echo "    PartialChain $pcopt"
		echo "}"
		cat "$blocks"
		printf 'server up-auth {\n    type udp\n    host 127.0.0.1\n    port 11812\n    secret upstream-secret\n}\n'
		printf 'server up-acct {\n    type udp\n    host 127.0.0.1\n    port 11813\n    secret upstream-secret\n}\n'
		printf 'realm * {\n    server up-auth\n    accountingServer up-acct\n}\n'
	} >run/edge.conf
	"$bin" -f -c run/edge.conf >run/edge.log 2>&1 &
	EPID=$!
	for _ in $(seq 30); do
		kill -0 "$EPID" 2>/dev/null || break
		timeout 0.2 bash -c '</dev/tcp/127.0.0.1/2083' 2>/dev/null && break
		sleep 0.1
	done
	sleep 0.3
	OFFSET=$(wc -l <run/edge.log)
	kill -0 "$EPID" 2>/dev/null || return 1
	return 0
}
edge_stop() {
	[ -n "$EPID" ] && kill "$EPID" 2>/dev/null && wait "$EPID" 2>/dev/null
	EPID=
}
newlog() { tail -n +"$((OFFSET + 1))" run/edge.log; }
judge() { # 新しいログから ACCEPT:<client> か REJECT:<理由> を出す
	local acc
	acc=$(newlog | grep -oE 'TLS connection from [^,]+, client [^,]+' | tail -1 | sed 's/.*client //')
	if [ -n "$acc" ]; then
		echo "ACCEPT:$acc"
	else
		local why
		why=$(newlog | grep -oiE 'no matching TLS client|certificate chain too long|unable to get local issuer certificate|unable to get issuer certificate|unable to get certificate CRL|CRL signature failure|certificate revoked' | head -1)
		[ -z "$why" ] && why="other:$(newlog | grep -iE 'error|fail|ignoring' | head -1 | cut -c1-100)"
		echo "REJECT:$why"
	fi
}
tls_try() { # <証明書> <チェーンのファイル|-> → ACCEPT/REJECT
	local cert=$1 chain=$2 opt=()
	[ "$chain" != - ] && opt=(-cert_chain "pki/$chain.pem")
	OFFSET=$(wc -l <run/edge.log)
	(sleep 1.2) | timeout 4 openssl s_client -connect 127.0.0.1:2083 -cert "pki/$cert.pem" -key "pki/$cert.key" "${opt[@]}" \
		-CAfile pki/srvca.pem -quiet >/dev/null 2>&1
	sleep 0.4
	judge
}
blk_any() { # 照合の条件のない共通のブロック 1 つ（信頼の起点の場面用）
	printf 'client any {\n    type tls\n    host 0.0.0.0/0\n    tls tenant\n    certificateNameCheck off\n}\n' >run/blk-any.conf
}
blk_any

echo "== P: 信頼の起点とチェーン"
t() { # <ID> <期待> <バイナリ> <束の中身（, 区切り）> <CRLCheck> <PartialChain> <証明書> <チェーン> <説明>
	local id=$1 exp=$2 bin=$3 parts=$4 crlc=$5 pcopt=$6 cert=$7 chain=$8 note=$9 r
	IFS=, read -r -a arr <<<"$parts"
	cat_files run/bundle.pem "${arr[@]}"
	if edge_start "$bin" run/bundle.pem "$crlc" "$pcopt" "${BLK:-run/blk-any.conf}"; then
		r=$(tls_try "$cert" "$chain")
	else
		r="START_FAILED:$(tail -2 run/edge.log | tr '\n' ' ' | cut -c1-120)"
	fi
	record "$id" "$exp" "$r" "$note"
}
t P1 ACCEPT:any "$STOCK" mroot off none apA chainA "無改造・共通のルートを信頼・組織 A"
t P2 ACCEPT:any "$STOCK" mroot off none apB chainB "無改造・共通のルートを信頼・他の組織 B（通ってしまう）"
t P3 "REJECT:unable to get issuer certificate" "$STOCK" featA off none apA chainA "無改造・RadSec 用の CA だけを信頼"
t P4 ACCEPT:any "$PC" featA off on apA chainA "PartialChain・RadSec 用の CA を起点・組織 A"
t P5 ACCEPT:any "$PC" featA off on apA - "PartialChain・RadSec 用の CA を起点・リーフだけ送る"
t P6 "REJECT:unable to get local issuer certificate" "$PC" featA off on apB chainB "PartialChain・RadSec 用の CA を起点・他の組織 B"
t P7 ACCEPT:any "$PC" orgA off on apA chainA "PartialChain・組織の CA を起点・組織 A"
t P8 "REJECT:unable to get local issuer certificate" "$PC" orgA off on apB chainB "PartialChain・組織の CA を起点・他の組織 B"
t P9 "REJECT:unable to get issuer certificate" "$PC" featA off none apA chainA "パッチ版でもオプションを書かなければ無改造と同じ"
t P10 "REJECT:certificate chain too long" "$STOCK" mroot off none apDeep chainDeep "無改造・共通のルート・1 段深いチェーン"
t P11 ACCEPT:any "$PC" featA off on apDeep chainDeep "PartialChain・RadSec 用の CA を起点・1 段深いチェーン"
t P12 ACCEPT:any "$PC" mroot off on apB chainB "PartialChain でも共通のルートを置けば他の組織を通す"
t P13 ACCEPT:any "$DEB" mroot off none apA chainA "Debian の 1.11.2 で共通のルート（今のイメージ）"
t P14 ACCEPT:any "$STOCK" mistA off none mistApA - "Mist の模型・組織の自己署名 CA・無改造"
t P15 "REJECT:unable to get local issuer certificate" "$STOCK" mistA off none mistApB - "Mist の模型・他の組織の AP"

echo "== C: CRL"
t C1a "REJECT:unable to get certificate CRL" "$PCALL" featA,crl:featA on on apA chainA "PartialChain だけの版・RadSec 用の CA と、その CRL（起点の CA 自身の CRL を求められる）"
t C2a "REJECT:CRL signature failure" "$PCALL" featA,crl:featA,orgA,crl:orgA on on apA chainA "PartialChain だけの版・組織の CA とその CRL も置く（起点の上の CRL の署名を確かめられない）"
t C1 ACCEPT:any "$PC" featA,crl:featA on on apA chainA "PartialChain・RadSec 用の CA と、その CRL だけ"
t C2 ACCEPT:any "$PC" featA,crl:featA,orgA,crl:orgA on on apA chainA "PartialChain・RadSec 用の CA と組織の CA と、その 2 つの CRL"
revoke featA apA2
mkcrl featA
cp crl/featA.pem crl/featA-revoked.pem
t C3 "REJECT:certificate revoked" "$PC" featA,crl:featA-revoked,orgA,crl:orgA on on apA2 chainA "PartialChain・失効させた AP（CRL に載せた）"
t C3b ACCEPT:any "$PC" featA,crl:featA-revoked,orgA,crl:orgA on on apA chainA "同じ CRL で、失効させていない AP"
t C4 ACCEPT:any "$PC" orgA,crl:orgA,crl:featA-clean on on apA chainA "PartialChain・組織の CA を起点・組織の CA の CRL と RadSec 用の CA の CRL"
t C4b "REJECT:unable to get certificate CRL" "$PC" orgA,crl:orgA on on apA chainA "PartialChain・組織の CA を起点・RadSec 用の CA の CRL がない"
t C5 ACCEPT:any "$STOCK" mroot,msub,mcluster,orgA,featA,crl:mroot,crl:msub,crl:mcluster,crl:orgA,crl:featA-clean on none apA chainA "無改造・5 段すべてと 5 つの CRL"
t C6 "REJECT:unable to get certificate CRL" "$STOCK" mroot,msub,mcluster,orgA,featA,crl:mroot,crl:mcluster,crl:orgA,crl:featA-clean on none apA chainA "無改造・共通の中間 CA の CRL が 1 つ欠ける"
t C7 "REJECT:unable to get certificate CRL" "$PC" tenB,crl:tenB-clean,mistA on on mistApA - "CRLCheck on・CRL のない持ち込みの CA の AP"
t C7b ACCEPT:any "$PC" tenB,crl:tenB-clean,mistA on on grp1 - "同じ束で、CRL のあるこちらの CA の証明書"
t C7c ACCEPT:any "$STOCK" tenB,crl:tenB-clean,mistA on none grp1 - "無改造（チェーン全体の確認）でも、CRL のない CA の巻き添えにはならない（拒否はその CA の証明書だけ）"
t C8 ACCEPT:any "$PC" tenB,crl:tenB-clean,featA,crl:featA-revoked on on apA chainA "混在の束（こちらの CA と Meraki の模型）・Meraki の AP"
t C8b "REJECT:unable to get local issuer certificate" "$PC" tenB,crl:tenB-clean,featA,crl:featA-revoked on on apB chainB "混在の束・他の組織の Meraki の AP"
t C8c "REJECT:certificate revoked" "$PC" tenB,crl:tenB-clean,featA,crl:featA-revoked on on apA2 chainA "混在の束・失効させた Meraki の AP"
t C8d ACCEPT:any "$PC" tenB,crl:tenB-clean,featA,crl:featA-revoked on on grp1 - "混在の束・こちらのグループの証明書"

echo "== B: client ブロック（こちらの CA の証明書）"
blk_group() { # <ファイル> <ブロックの名前と SAN の組...>（名前=SAN）
	local f=$1
	shift
	: >"$f"
	for pair in "$@"; do
		local n=${pair%%=*} san=${pair#*=}
		printf 'client %s {\n    type tls\n    host 0.0.0.0/0\n    tls tenant\n    certificateNameCheck off\n    matchCertificateAttribute SubjectAltName:URI:/^%s$/\n}\n' "$n" "$san" >>"$f"
	done
}
blk_group run/blk-b1.conf "grp-hq-unifi=urn:example:grp:tenant-b:hq-unifi" "probe=urn:example:nas:tenant-b:probe"
BLK=run/blk-b1.conf
t B1 ACCEPT:grp-hq-unifi "$PC" tenB,crl:tenB-clean on on grp1 - "登録したグループの証明書"
t B1b "REJECT:no matching TLS client" "$PC" tenB,crl:tenB-clean on on grpX - "同じ CA で、登録していないグループの証明書（共通のブロックなし）"
t B1c "REJECT:unable to get local issuer certificate" "$PC" tenB,crl:tenB-clean on on grpC - "別のテナントの CA の証明書"
t B1d "REJECT:no matching TLS client" "$PC" tenB,crl:tenB-clean on on ap1 - "同じ CA で、登録していない AP の証明書"
blk_group run/blk-b2.conf "probe=urn:example:nas:tenant-b:probe"
BLK=run/blk-b2.conf
t B2 "REJECT:no matching TLS client" "$PC" tenB,crl:tenB-clean on on grp1 - "グループのブロックを消すと、失効の前でもつながらない"
BLK=run/blk-b1.conf
t B3 ACCEPT:grp-hq-unifi "$PC" tenB,crl:tenB-clean on on grp1new - "同じ SAN の新しい証明書"
# B3c/B3d: 古い証明書を失効させて SIGHUP で CRL を読み直す
cat_files run/bundle.pem tenB crl:tenB-clean
edge_start "$PC" run/bundle.pem on on run/blk-b1.conf
revoke tenB grp1
mkcrl tenB
cat_files run/bundle.pem tenB crl:tenB
kill -HUP "$EPID"
sleep 1
record B3c "REJECT:certificate revoked" "$(tls_try grp1 -)" "古い証明書を失効させて SIGHUP（新しい接続）"
record B3d ACCEPT:grp-hq-unifi "$(tls_try grp1new -)" "SIGHUP の後も新しい証明書はつながる"
edge_stop
cp crl/tenB.pem crl/tenB-revoked.pem

echo "== M: CRL のない持ち込みの CA（Mist の模型）を CRLCheck off で受け、共通のブロックを CN の形で絞る"
blk_group run/blk-m.conf "grp-hq-unifi=urn:example:grp:tenant-b:hq-unifi"
printf 'client shared {\n    type tls\n    host 0.0.0.0/0\n    tls tenant\n    certificateNameCheck off\n    matchCertificateAttribute CN:/^[0-9a-f]{12}$/\n}\n' >>run/blk-m.conf
BLK=run/blk-m.conf
t M1 ACCEPT:shared "$PC" tenB,mistA off on mistApA - "Mist の模型の AP は共通のブロック"
t M2 ACCEPT:grp-hq-unifi "$PC" tenB,mistA off on grp1new - "こちらのグループの証明書はグループのブロック"
t M3 "REJECT:no matching TLS client" "$PC" tenB,mistA off on grpX - "登録していないこちらの証明書は、共通のブロックにも入らない"
t M4 "REJECT:unable to get local issuer certificate" "$PC" tenB,mistA off on mistApB - "他の組織の Mist の AP"
t M5 ACCEPT:grp-hq-unifi "$PC" tenB,mistA off on grp1 - "CRLCheck off では失効させた証明書もつながる（ブロックの削除で止める必要）"
BLK=

echo "== V: テナントの刻印と NAS-Identifier（AP の役の radsecproxy → エッジ → 上流）"
python3 /lab/radtool.py dump --out run/dump.jsonl &
DPID=$!
sleep 0.5
cat >run/blk-v.conf <<'EOF'
rewrite r-ap-001 {
    removeVendorAttribute 32473:1
    addVendorAttribute 32473:1:'42
    removeAttribute 32
    addAttribute 32:'tenant-b-ap-001
    supplementAttribute 1:'tenant-b-ap-001
}
client tenant-b-ap-001 {
    type tls
    host 0.0.0.0/0
    tls tenant
    certificateNameCheck off
    matchCertificateAttribute SubjectAltName:URI:/^urn:example:nas:tenant-b:ap-001$/
    rewriteIn r-ap-001
}
rewrite r-grp-hq-unifi {
    removeVendorAttribute 32473:1
    addVendorAttribute 32473:1:'42
    supplementAttribute 32:'tenant-b-hq-unifi
    supplementAttribute 1:'tenant-b-hq-unifi
}
client grp-hq-unifi {
    type tls
    host 0.0.0.0/0
    tls tenant
    certificateNameCheck off
    matchCertificateAttribute SubjectAltName:URI:/^urn:example:grp:tenant-b:hq-unifi$/
    rewriteIn r-grp-hq-unifi
}
rewrite r-shared {
    removeVendorAttribute 32473:1
    addVendorAttribute 32473:1:'42
    supplementAttribute 32:'tenant-b
    supplementAttribute 1:'tenant-b
}
client shared {
    type tls
    host 0.0.0.0/0
    tls tenant
    certificateNameCheck off
    rewriteIn r-shared
}
EOF
APID=
ap_start() { # <証明書> [チェーン]（AP の役。UDP 127.0.0.1:1812 で受けてエッジへ RadSec で送る）
	[ -n "$APID" ] && kill "$APID" 2>/dev/null && wait "$APID" 2>/dev/null
	cat "pki/$1.pem" >run/apcert.pem
	[ -n "${2:-}" ] && cat "pki/$2.pem" >>run/apcert.pem
	cat >run/ap.conf <<EOF
ListenUDP 127.0.0.1:1812
LogLevel 3
client local {
    type udp
    host 127.0.0.1
    secret ap-local-secret
}
tls ap {
    CACertificateFile $W/pki/srvca.pem
    CertificateFile $W/run/apcert.pem
    CertificateKeyFile $W/pki/$1.key
}
server edge {
    type tls
    host 127.0.0.1
    port 2083
    tls ap
    certificateNameCheck off
}
realm * {
    server edge
    accountingServer edge
}
EOF
	"$PC" -f -c run/ap.conf >run/ap.log 2>&1 &
	APID=$!
	sleep 0.7
}
seen() { # <User-Name> → 上流に届いたものの要約
	sleep 2
	python3 - "$1" <<'PY'
import json, sys
u = sys.argv[1]
rows = [json.loads(l) for l in open("/work/run/dump.jsonl", encoding="utf-8") if l.strip()]
rows = [r for r in rows if r["user"] == u]
if not rows:
    print("NOT_FORWARDED"); sys.exit()
r = rows[0]
stamp = ",".join(s["value"] for s in r["stamp"]) or "none"
other = "kept" if any(v["vendor"] == 9 for v in r["vsa"]) else "none"
print(f"code={r['code']};nas={r['nas']};stamp={stamp};vsa9={other}")
PY
}
v() { # <ID> <期待> <エッジのバイナリ> <PartialChain> <証明書> <チェーン> <kind> <User-Name> <NAS-Identifier|-> <説明>
	local id=$1 exp=$2 bin=$3 pcopt=$4 cert=$5 chain=$6 kind=$7 user=$8 nas=$9 note=${10} nasopt=()
	[ "$nas" != - ] && nasopt=(--nas "$nas")
	ap_start "$cert" "$chain"
	python3 /lab/radtool.py send --kind "$kind" --port 1812 --secret ap-local-secret --user "$user" "${nasopt[@]}" --spoof --other-vsa
	record "$id" "$exp" "$(seen "$user")" "$note"
}
cat_files run/bundle-v.pem tenB crl:tenB-revoked featA crl:featA-revoked orgA crl:orgA
edge_start "$PC" run/bundle-v.pem on on run/blk-v.conf
v V1 "code=1;nas=tenant-b-ap-001;stamp=42;vsa9=kept" "$PC" on ap1 "" auth u-v1 spoofed-nas "AP のブロック: NAS-Identifier を置き換え、偽の刻印を消して付け直す。他の業者の VSA は残る"
v V2 "code=1;nas=ap-hq-01;stamp=42;vsa9=kept" "$PC" on grp1new "" auth u-v2 ap-hq-01 "グループのブロック: NAS-Identifier はそのまま、刻印は付け直す"
v V3 "code=1;nas=tenant-b-hq-unifi;stamp=42;vsa9=kept" "$PC" on grp1new "" auth u-v3 - "グループのブロック: NAS-Identifier がなければ補う"
v V4 "code=4;nas=tenant-b-hq-unifi;stamp=42;vsa9=kept" "$PC" on grp1new "" acct u-v4 - "Accounting にも刻印が付く"
v V5 "code=1;nas=Q2AA:office;stamp=42;vsa9=kept" "$PC" on apA chainA auth u-v5 Q2AA:office "持ち込みの CA（Meraki の模型）の AP は共通のブロック"
edge_stop
cat_files run/bundle-v.pem tenB crl:tenB-revoked
edge_start "$DEB" run/bundle-v.pem on none run/blk-v.conf
v V6 "code=1;nas=tenant-b-ap-001;stamp=42;vsa9=kept" "$DEB" none ap1 "" auth u-v6 spoofed-nas "Debian の 1.11.2 でも同じ書き方が効く（AP のブロック）"
v V7 "code=1;nas=tenant-b-hq-unifi;stamp=42;vsa9=kept" "$DEB" none grp1new "" auth u-v7 - "Debian の 1.11.2（グループのブロック）"
edge_stop
[ -n "$APID" ] && kill "$APID" 2>/dev/null
kill "$DPID" 2>/dev/null

echo "== 結果"
printf '%s 件中 OK %s 件\n' "$(wc -l <"$RES")" "$(grep -c $'\tOK\t' "$RES")"
cp run/edge.log run/edge-last.log 2>/dev/null
