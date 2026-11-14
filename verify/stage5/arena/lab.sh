#!/bin/bash
# radsecproxy のメモリーの増え方の実験（確認事項 T5-20）。検証機の 2 台目（simwifi2）の ~/aka-work/arena で動かす。
# 段階 5 の 150 テナントの試験で、テナントの radsecproxy が AP のつなぎ直しのたびに glibc の malloc の arena を膨らませる見込みが出たので、
# 本物のテナントの設定とコンテナの起動の形を写した radsecproxy を 6 個置き、既定と MALLOC_ARENA_MAX=2・=1 を 2 個ずつ比べる。
#
#   ./lab.sh setup     PKI（CA・CRL・サーバー・AP の証明書）とテナントの設定を作る
#   ./lab.sh up        上流の代わりと radsecproxy 6 個を起動する
#   ./lab.sh ap        AP の役（../load-ap.py）を始める（テナントあたり毎秒 1 本のつなぎ直し、RADIUS 毎秒 1 件）
#   ./lab.sh measure   測定を始める（1 分ごとに samples.jsonl に 1 行）
#   ./lab.sh status    最後の測定と AP の役の状態
#   ./lab.sh down      止めて消す（結果のファイルは残す）
set -uo pipefail
W=$(cd "$(dirname "$0")" && pwd)
IMG=radsec-edge/radsecproxy:1.11.4-pc1
PY=python:3.13.9-slim
NET=arena SUB=172.30.99.0/24 UP=172.30.99.2
SECRET=arena-upstream-secret-0123
# 実験のテナント: 名前:MALLOC_ARENA_MAX（空は既定）
TENANTS="t1: t2: t3:2 t4:2 t5:1 t6:1"
APS="ap1 ap2 ap3 ap4 ap5 probe"

cert() { # <名前> <SAN の行> <EKU>
	openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" < /dev/null 2> /dev/null
	printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=%s\nsubjectAltName=%s\n' "$3" "$2" > "$1.ext"
	openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -sha256 -extfile "$1.ext" -out "$1.pem" 2> /dev/null
	rm -f "$1.csr" "$1.ext"
}

case ${1:-} in
setup)
	set -e
	mkdir -p "$W/pki" "$W/tenants" "$W/crl/crl"
	cd "$W/pki"
	if [ ! -s ca.pem ]; then
		openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca.key -out ca.pem -days 3650 -subj /CN=arena-ca \
			-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2> /dev/null
		: > index.txt
		echo 01 > crlnumber
		printf '[ca]\ndefault_ca=c\n[c]\ndatabase=%s/index.txt\ncrlnumber=%s/crlnumber\ndefault_md=sha256\ndefault_crl_days=3650\n' "$PWD" "$PWD" > ca.cnf
		openssl ca -config ca.cnf -gencrl -keyfile ca.key -cert ca.pem -out crl.pem 2> /dev/null
		cert server DNS:arena.test serverAuth
		for t in $TENANTS; do
			for a in $APS; do cert "${t%%:*}-$a" "URI:urn:arena:nas:${t%%:*}:$a" clientAuth; done
		done
	fi
	for t in $TENANTS; do
		n=${t%%:*} d=$W/tenants/${t%%:*}
		mkdir -p "$d"
		cat ca.pem crl.pem > "$d/ca-bundle.pem"
		cp server.pem server.key "$d/"
		{
			# 本物のテナントの設定（radsec-edge の rsconf のひな形。2026-11-12 の e0edf4b の ld001）を写した。値だけ実験のものにした
			printf 'ListenTLS *:2083\nLogLevel 2\n\n'
			printf 'tls tenant {\n    CACertificateFile  /conf/current/ca-bundle.pem\n    CertificateFile    /conf/current/server.pem\n    CertificateKeyFile /conf/current/server.key\n    CRLCheck on\n    TlsVersion TLS1_2:TLS1_3\n}\n\n'
			for a in $APS; do
				printf "rewrite nasid-%s-%s {\n    removeVendorAttribute 32473:1\n    addVendorAttribute 32473:1:'%s\n    removeAttribute 32\n    addAttribute 32:'%s-%s\n    supplementAttribute 1:'%s-%s\n}\n" "$n" "$a" "${n#t}" "$n" "$a" "$n" "$a"
				printf 'client %s-%s {\n    type tls\n    host 0.0.0.0/0\n    tls tenant\n    certificateNameCheck off\n    TCPKeepalive on\n    matchCertificateAttribute SubjectAltName:URI:/^urn:arena:nas:%s:%s$/\n    rewriteIn nasid-%s-%s\n}\n\n' "$n" "$a" "$n" "$a" "$n" "$a"
			done
			for s in auth:1812 acct:1813; do
				printf 'server upstream-%s {\n    type udp\n    host %s\n    port %s\n    secret %s\n    statusServer on\n}\n' "${s%%:*}" "$UP" "${s#*:}" "$SECRET"
			done
			printf 'realm * {\n    server upstream-auth\n    accountingServer upstream-acct\n}\n'
		} > "$d/radsecproxy.conf"
		chmod 755 "$d"
		chmod 644 "$d"/*
	done
	# AP の役の一覧（ポート 証明書 鍵 CA slug AP）。probe の client ブロックは本物と同じく置くが、つながない
	i=0
	for t in $TENANTS; do
		i=$((i + 1))
		for a in ap1 ap2 ap3 ap4 ap5; do echo "$((21400 + i)) $W/pki/${t%%:*}-$a.pem $W/pki/${t%%:*}-$a.key $W/pki/ca.pem ${t%%:*} $a"; done
	done > "$W/aps.txt"
	docker run --rm -v "$W/tenants/t1:/conf/current:ro" "$IMG" radsecproxy -p -c /conf/current/radsecproxy.conf > /dev/null && echo "設定の構文 OK"
	wc -l < "$W/aps.txt"
	;;
up)
	docker network inspect "$NET" > /dev/null 2>&1 || docker network create --subnet "$SUB" "$NET" > /dev/null
	docker rm -f arena-upstream > /dev/null 2>&1
	docker run -d --name arena-upstream --network "$NET" --ip "$UP" --user "$(id -u):$(id -g)" -v "$W:/w" "$PY" python -I /w/upstream.py /w "$SECRET" 0.0.0.0 > /dev/null
	i=0
	: > "$W/ids.txt"
	for t in $TENANTS; do
		i=$((i + 1))
		n=${t%%:*} v=${t#*:}
		docker rm -f "arena-$n" > /dev/null 2>&1
		# 本物のテナントのコンテナと同じ起動の形（agent のひな形: init、読み取り専用、権限をすべて落とす、UID 10083）
		docker run -d --name "arena-$n" --network "$NET" --init --read-only --cap-drop ALL --security-opt no-new-privileges --user 10083:10083 \
			-p "127.0.0.1:$((21400 + i)):2083" -v "$W/tenants/$n:/conf/current:ro" ${v:+-e MALLOC_ARENA_MAX=$v} \
			--log-opt max-size=10m --log-opt max-file=2 "$IMG" radsecproxy -f -c /conf/current/radsecproxy.conf > /dev/null
		echo "$(docker inspect -f '{{.Id}}' "arena-$n") $n ${v:-既定}" >> "$W/ids.txt"
	done
	sleep 3
	docker ps --filter name=arena- --format '{{.Names}} {{.Status}}'
	;;
ap)
	pkill -f '^python3 -I [^ ]*/[l]oad-ap.py' 2> /dev/null
	rm -f "$W/ap-status.json" "$W/ap-status.jsonl"
	nohup python3 -I "$W/load-ap.py" "$W" 127.0.0.1 6 6 > "$W/ap.log" 2>&1 < /dev/null &
	sleep 1
	pgrep -af '^python3 -I [^ ]*/[l]oad-ap.py'
	;;
measure)
	docker rm -f arena-measure > /dev/null 2>&1
	docker run -d --name arena-measure --pid=host --privileged --cgroupns=host -v "$W:/w" "$PY" python -I /w/measure.py /w 60 > /dev/null
	sleep 2
	docker ps --filter name=arena-measure --format '{{.Names}} {{.Status}}'
	;;
status)
	tail -1 "$W/samples.jsonl" 2> /dev/null | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
for n, p in sorted(d["procs"].items()):
    print(n, p["variant"], "PSS", p["pss_kb"], "anon", p["anon_kb"], "arena", p["arenas"], "threads", p["threads"], "conns", p["conns"])'
	cat "$W/ap-status.json" 2> /dev/null
	echo
	;;
down)
	pkill -f '^python3 -I [^ ]*/[l]oad-ap.py' 2> /dev/null
	docker rm -f arena-measure arena-upstream $(for t in $TENANTS; do echo "arena-${t%%:*}"; done) > /dev/null 2>&1
	docker network rm "$NET" > /dev/null 2>&1
	docker ps -a --filter name=arena- --format '{{.Names}}'
	;;
*) echo "使い方は先頭の説明を見る" >&2; exit 2 ;;
esac
