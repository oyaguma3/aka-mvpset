#!/usr/bin/env bash
# 1 時間ごとに、サーバー証明書の期限と、エッジの CRL の次の更新を textfile collector に書く（docs/deployment.md §9.2、確認事項 D12）。
# 口は /etc/aka/tls-targets（名前 アドレス:ポート）。mTLS の口でも、TLS 1.3 ではクライアント証明書を求められる前にサーバー証明書が届くので読める。
set -uo pipefail
dir=/var/lib/aka-textfile
tmp=$(mktemp "$dir/.certs.XXXXXX")
trap 'rm -f "$tmp"' EXIT
role=$(cat /etc/aka/role)
enddate() { # 標準入力の PEM の証明書の期限（UNIX 時刻）
	local d
	d=$(openssl x509 -noout -enddate 2> /dev/null | cut -d= -f2) || return 1
	[ -n "$d" ] && date -d "$d" +%s
}
{
	echo "# HELP aka_cert_not_after_seconds サーバー証明書の期限（UNIX 時刻）"
	echo "# TYPE aka_cert_not_after_seconds gauge"
	echo "# HELP aka_cert_probe_ok 証明書を読めたか"
	echo "# TYPE aka_cert_probe_ok gauge"
	while read -r name addr; do
		[ -n "${name:-}" ] || continue
		if t=$(timeout 10 openssl s_client -connect "$addr" < /dev/null 2> /dev/null | enddate); then
			echo "aka_cert_not_after_seconds{cert=\"$name\"} $t"
			echo "aka_cert_probe_ok{cert=\"$name\"} 1"
		else
			echo "aka_cert_probe_ok{cert=\"$name\"} 0"
		fi
	done < /etc/aka/tls-targets
	if [ "$role" = mgmt ]; then
		# radsec-ca の管理API はホストに公開しない（共有の Docker のネットワーク）ので、コマンドで取り出す
		if t=$(timeout 20 docker exec radsec-ca-radsec-ca-1 /radsec-ca server-cert 2> /dev/null | enddate); then
			echo "aka_cert_not_after_seconds{cert=\"radsec-ca-admin\"} $t"
			echo "aka_cert_probe_ok{cert=\"radsec-ca-admin\"} 1"
		else
			echo "aka_cert_probe_ok{cert=\"radsec-ca-admin\"} 0"
		fi
	fi
	if [ "$role" = edge ]; then
		echo "# HELP aka_crl_next_update_seconds テナントの CA の束に入っている CRL の次の更新（UNIX 時刻）"
		echo "# TYPE aka_crl_next_update_seconds gauge"
		for d in /var/lib/radsec-edge/tenants/*/current; do
			[ -d "$d" ] || continue
			slug=$(basename "$(dirname "$d")")
			if t=$(enddate < "$d/server.pem"); then echo "aka_cert_not_after_seconds{cert=\"tenant-$slug\"} $t"; fi
			python3 - "$d/ca-bundle.pem" "$slug" << 'PY'
import re, subprocess, sys, datetime
text = open(sys.argv[1]).read()
for i, block in enumerate(re.findall(r"-----BEGIN X509 CRL-----.*?-----END X509 CRL-----", text, re.S)):
    out = subprocess.run(["openssl", "crl", "-noout", "-nextupdate", "-hash"], input=block, capture_output=True, text=True).stdout
    nxt = re.search(r"nextUpdate=(.+)", out)
    h = out.splitlines()[0].strip() if out else str(i)
    if nxt:
        t = datetime.datetime.strptime(nxt.group(1).strip(), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
        print(f'aka_crl_next_update_seconds{{tenant="{sys.argv[2]}",issuer_hash="{h}"}} {int(t.timestamp())}')
PY
		done
	fi
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$dir/certs.prom"
trap - EXIT
