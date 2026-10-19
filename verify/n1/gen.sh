#!/usr/bin/env bash
# N1 の計測用の PKI と radsecproxy の設定を作る（radsec-edge の rsconf のひな形と同じ形）。
# 使い方: gen.sh <作業ディレクトリ> <テナント数> <テナントあたりの AP 数> <重いテナントの AP 数> <上流の IP>
set -euo pipefail
W=$1 NT=$2 K=$3 H=$4 UP=$5
P=$W/pki T=$W/tenants
mkdir -p "$P" "$T"

ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }

ec "$P/sca.key"
openssl req -x509 -new -key "$P/sca.key" -subj /CN=n1-server-ca -days 30 -out "$P/sca.pem" \
	-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null

# gen_tenant <slug> <AP 数>
gen_tenant() {
	local s=$1 n=$2
	local d=$T/$s/current c=$P/$s
	mkdir -p "$d" "$c"
	ec "$c/ca.key"
	openssl req -x509 -new -key "$c/ca.key" -subj "/CN=$s-client-ca" -days 30 -out "$c/ca.pem" \
		-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
	: >"$c/index.txt"
	echo 01 >"$c/crlnumber"
	printf '[ca]\ndefault_ca=d\n[d]\ndatabase=%s\ncrlnumber=%s\ndefault_md=sha256\ndefault_crl_days=7\n' \
		"$c/index.txt" "$c/crlnumber" >"$c/ca.cnf"
	openssl ca -config "$c/ca.cnf" -gencrl -keyfile "$c/ca.key" -cert "$c/ca.pem" -out "$c/crl.pem" 2>/dev/null
	cat "$c/ca.pem" "$c/crl.pem" >"$d/ca-bundle.pem"
	ec "$d/server.key"
	openssl req -new -key "$d/server.key" -subj "/CN=$s.radsec.test" 2>/dev/null |
		openssl x509 -req -CA "$P/sca.pem" -CAkey "$P/sca.key" -CAserial "$P/sca.srl" -CAcreateserial -days 30 \
			-extfile <(printf 'subjectAltName=DNS:%s.radsec.test\nextendedKeyUsage=serverAuth\n' "$s") -out "$d/server.pem" 2>/dev/null
	{
		printf 'ListenTLS *:2083\nLogLevel 2\n\ntls tenant {\n    CACertificateFile  /conf/current/ca-bundle.pem\n'
		printf '    CertificateFile    /conf/current/server.pem\n    CertificateKeyFile /conf/current/server.key\n'
		printf '    CRLCheck on\n    TlsVersion TLS1_2:TLS1_3\n}\n'
		for i in $(seq 1 "$n"); do
			local nas=$s-ap-$i uri=urn:example:$s:ap-$i a=$c/ap-$i
			ec "$a.key"
			openssl req -new -key "$a.key" -subj "/CN=$nas" 2>/dev/null |
				openssl x509 -req -CA "$c/ca.pem" -CAkey "$c/ca.key" -CAserial "$c/ca.srl" -CAcreateserial -days 30 \
					-extfile <(printf 'subjectAltName=URI:%s\nextendedKeyUsage=clientAuth\n' "$uri") -out "$a.pem" 2>/dev/null
			printf '\nrewrite nasid-%s {\n    removeAttribute 32\n    addAttribute 32:'"'"'%s\n    supplementAttribute 1:'"'"'%s\n}\n' "$nas" "$nas" "$nas"
			printf 'client %s {\n    type tls\n    host 0.0.0.0/0\n    tls tenant\n    certificateNameCheck off\n' "$nas"
			printf '    matchCertificateAttribute SubjectAltName:URI:/^%s$/\n    rewriteIn nasid-%s\n}\n' "$uri" "$nas"
		done
		printf '\nserver upstream-auth {\n    type udp\n    host %s\n    port 11812\n    secret n1-secret\n    statusServer on\n}\n' "$UP"
		printf 'server upstream-acct {\n    type udp\n    host %s\n    port 11813\n    secret n1-secret\n    statusServer on\n}\n' "$UP"
		printf '\nrealm * {\n    server upstream-auth\n    accountingServer upstream-acct\n}\n'
	} >"$d/radsecproxy.conf"
}

for t in $(seq 1 "$NT"); do gen_tenant "t$(printf %03d "$t")" "$K"; done
gen_tenant heavy "$H"
chmod -R a+rX "$W/tenants" "$W/pki"
echo "gen: tenants=$NT aps=$K heavy=$H"
