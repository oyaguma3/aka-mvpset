#!/bin/bash
# 確認事項 4-1a のためのラボ: 複数の CA の CRL の期限切れ、送信元の範囲、同じ Subject の CA。
cd /tmp; R=/tmp/r.log
res() { printf '%-6s %-60s %s\n' "$1" "$2" "$3"; }
newca() { # newca <dir> <cn>
  mkdir -p $1; : >$1/index.txt; echo 01 >$1/crlnumber; echo 01 >$1/serial
  cat >$1/c.cnf <<C
[ca]
default_ca=d
[d]
dir=$1
database=$1/index.txt
crlnumber=$1/crlnumber
serial=$1/serial
new_certs_dir=$1
default_md=sha256
default_days=30
default_crl_days=7
policy=p
unique_subject=no
[p]
commonName=supplied
[leaf]
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
C
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $1/ca.key -out $1/ca.pem -days 30 -subj "/CN=$2" -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
}
leaf() { # leaf <cadir> <name>
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $1/$2.key -out $1/$2.csr -subj "/CN=$2" 2>/dev/null
  openssl ca -batch -config $1/c.cnf -extensions leaf -in $1/$2.csr -out $1/$2.pem -cert $1/ca.pem -keyfile $1/ca.key 2>/dev/null
}
crl() { # crl <cadir> [crlsec]
  if [ -n "${2:-}" ]; then openssl ca -config $1/c.cnf -gencrl -crlsec $2 -cert $1/ca.pem -keyfile $1/ca.key -out $1/crl.pem 2>/dev/null
  else openssl ca -config $1/c.cnf -gencrl -cert $1/ca.pem -keyfile $1/ca.key -out $1/crl.pem 2>/dev/null; fi
}
conn() { # conn <cadir> <name> <秒> で裏で接続を持つ（PID を出す）
  (sleep $3 | openssl s_client -connect 127.0.0.1:2083 -cert $1/$2.pem -key $1/$2.key -quiet >/dev/null 2>&1) & echo $!
}
up() { grep -c "client $1,.* up" $R; }
lost() { grep -c "client $1 lost" $R; }
try() { # try <cadir> <name> <ブロック名>: 新しい接続が受け入れられるか
  local b=$(up $3); (sleep 1 | timeout 4 openssl s_client -connect 127.0.0.1:2083 -cert $1/$2.pem -key $1/$2.key -quiet >/dev/null 2>&1); sleep 1
  [ "$(up $3)" -gt "$b" ] && echo 受け入れ || echo 拒否
}
conf() { # conf <PartialChain 行> <own の host 行> <vendor の host 行>
  cat >/tmp/r.conf <<C
ListenTLS *:2083
LogLevel 2
tls t {
    CACertificateFile /tmp/bundle.pem
    CertificateFile /tmp/srv.pem
    CertificateKeyFile /tmp/srv.key
    CRLCheck on
    $1
    TlsVersion TLS1_2:TLS1_3
}
client own { 
    type tls
    $2
    tls t
    certificateNameCheck off
    matchCertificateAttribute CN:/^own-ap\$/
}
client vendor {
    type tls
    $3
    tls t
    certificateNameCheck off
    matchCertificateAttribute CN:/^vendor-ap\$/
}
server up { 
    type udp
    host 127.0.0.1
    port 11812
    secret testing123
}
realm * { server up }
C
}
start() { : >$R; radsecproxy -f -c /tmp/r.conf >$R 2>&1 & RP=$!; sleep 1; kill -0 $RP 2>/dev/null || { echo "起動できない"; cat $R; }; }
stop() { kill $RP 2>/dev/null; pkill -f 'openssl s_client' ; sleep 1; }
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout srv.key -out srv.pem -days 30 -subj /CN=srv 2>/dev/null
for mode in 自己署名のみ PartialChain; do
  rm -rf own vendor root; newca /tmp/own "own CA"; leaf /tmp/own own-ap; crl /tmp/own
  if [ $mode = PartialChain ]; then
    newca /tmp/root "vendor root"; newca /tmp/vendor "vendor org CA"
    openssl req -new -key vendor/ca.key -out vendor/ca.csr -subj "/CN=vendor org CA" 2>/dev/null
    cat >root/ica.ext <<C
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
C
    openssl x509 -req -in vendor/ca.csr -CA root/ca.pem -CAkey root/ca.key -CAcreateserial -days 30 -extfile root/ica.ext -out vendor/ca.pem 2>/dev/null
    PC="PartialChain on"
  else newca /tmp/vendor "vendor org CA"; PC=""; fi
  leaf /tmp/vendor vendor-ap
  crl /tmp/vendor 12   # 12 秒で期限が切れる CRL
  cat own/ca.pem own/crl.pem vendor/ca.pem vendor/crl.pem >bundle.pem
  conf "$PC" "host 0.0.0.0/0" "host 0.0.0.0/0"; start
  conn /tmp/own own-ap 60 >/dev/null; conn /tmp/vendor vendor-ap 60 >/dev/null; sleep 2
  res X1 "$mode: 両方の CA の CRL が有効で own・vendor が接続" "own up=$(up own) vendor up=$(up vendor)"
  sleep 12
  res X2a "$mode: vendor の CRL の期限が切れた後、読み直す前の既存の接続" "own lost=$(lost own) vendor lost=$(lost vendor)"
  res X2b "$mode: 読み直す前の新しい接続 own" "$(try /tmp/own own-ap own)"
  res X2c "$mode: 読み直す前の新しい接続 vendor" "$(try /tmp/vendor vendor-ap vendor)"
  kill -HUP $RP; sleep 3
  res X3a "$mode: SIGHUP の後の既存の接続（own は別の CA）" "own lost=$(lost own) vendor lost=$(lost vendor)"
  res X3b "$mode: SIGHUP の後の新しい接続 own" "$(try /tmp/own own-ap own)"
  res X3c "$mode: SIGHUP の後の新しい接続 vendor" "$(try /tmp/vendor vendor-ap vendor)"
  grep -E 'TLS connection|lost|verify error|sighup|SIGHUP|reload' $R | cut -c26-150
  stop
done
# 送信元の範囲
rm -rf own vendor; newca /tmp/own "own CA"; leaf /tmp/own own-ap; crl /tmp/own; newca /tmp/vendor "vendor org CA"; leaf /tmp/vendor vendor-ap; crl /tmp/vendor
cat own/ca.pem own/crl.pem vendor/ca.pem vendor/crl.pem >bundle.pem
conf "" "host 10.99.0.0/16
    host 127.0.0.1/32" "host 10.99.0.0/16"; start
res H1 "host を 2 行（10.99/16 と 127.0.0.1/32）のブロックに 127.0.0.1 から" "$(try /tmp/own own-ap own)"
res H2 "host が 10.99/16 だけのブロックに 127.0.0.1 から（証明書は正しい）" "$(try /tmp/vendor vendor-ap vendor)"
grep -vE ' up$|lost|Listen|listening' $R | tail -4 | cut -c1-140
stop
conf "" "host 10.99.0.0/16" "host 10.99.0.0/16"; start
b=$(echo | timeout 3 openssl s_client -connect 127.0.0.1:2083 2>&1 | grep -cE 'BEGIN CERTIFICATE|Server certificate')
res H3 "どのブロックも範囲外の送信元に TLS で応じるか（証明書を見せたら 1）" "$b"
grep -vE ' up$|lost|Listen|listening' $R | tail -3 | cut -c1-140
stop
# 同じ Subject で鍵の違う CA を 2 つ（業者の CA の入れ替え）
rm -rf a b; newca /tmp/a "same subject"; leaf /tmp/a vendor-ap; cp a/vendor-ap.pem a/ok.pem; cp a/vendor-ap.key a/ok.key
leaf /tmp/a bad-a; openssl ca -config a/c.cnf -revoke a/bad-a.pem -cert a/ca.pem -keyfile a/ca.key 2>/dev/null; crl /tmp/a
newca /tmp/b "same subject"; leaf /tmp/b vendor-ap; leaf /tmp/b bad-b; openssl ca -config b/c.cnf -revoke b/bad-b.pem -cert b/ca.pem -keyfile b/ca.key 2>/dev/null; crl /tmp/b
cat a/ca.pem a/crl.pem b/ca.pem b/crl.pem >bundle.pem
cat >/tmp/r.conf <<C
ListenTLS *:2083
LogLevel 2
tls t {
    CACertificateFile /tmp/bundle.pem
    CertificateFile /tmp/srv.pem
    CertificateKeyFile /tmp/srv.key
    CRLCheck on
    TlsVersion TLS1_2:TLS1_3
}
client vendor {
    type tls
    host 0.0.0.0/0
    tls t
    certificateNameCheck off
}
server up {
    type udp
    host 127.0.0.1
    port 11812
    secret testing123
}
realm * { server up }
C
start
res S1 "同じ Subject の CA a の正当な AP" "$(try /tmp/a vendor-ap vendor)"
res S2 "同じ Subject の CA b の正当な AP" "$(try /tmp/b vendor-ap vendor)"
res S3 "CA a の失効した AP" "$(try /tmp/a bad-a vendor)"
res S4 "CA b の失効した AP" "$(try /tmp/b bad-b vendor)"
stop
echo "== 結果の終わり"
