#!/bin/bash
# 規模の試験の道具（scaleload）の手元の通し（確認事項 L6-7）。手元の Docker に aka-vecgen・aka-radius（versions.env の固定のコミット）と、
# エッジの代わりの radsecproxy（本物のエッジと同じイメージ。TLS で受けて刻印を付け、UDP で auth・acct へ）を立てる。
# 手元には sudo がないので、コンテナ（UID 65532・10083）が読み書きするファイルは試しの間だけ 644・777 にする（CLAUDE.md の「検証のしかた」）。
#
#   export WORK=<作業場所>（消してよい新しいディレクトリ）
#   verify/scale/lab/lab.sh up            # 立てる（イメージは deploy/bin/build-images で作っておく）
#   verify/scale/lab/lab.sh subs <数>     # IMSI の番号 1〜<数> を両側に登録する（種は $WORK/seed.bin）
#   verify/scale/lab/lab.sh aps <数> <加入者の数>  # AP の一覧 $WORK/aps.json（テナント lab1・lab2 に半分ずつ）
#   verify/scale/lab/lab.sh logs          # aka-radius・aka-vecgen の WARN・ERROR の数
#   verify/scale/lab/lab.sh down          # 片付ける（作業場所は残す）
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
M=$(cd "$T/../../.." && pwd)
WORK=${WORK:?作業場所}
# shellcheck source=../../../versions.env
. "$M/versions.env"
V=$WORK/vecgen
R=$WORK/radius/deployments
P=$WORK/pki
export SCALE_LAB=$T SCALE_PKI=$P
vc() { (cd "$V" && docker compose -p scalevecgen -f compose.yaml -f "$T/compose.vecgen.yaml" "$@"); }
rc() { (cd "$R" && docker compose -p scaleradius -f docker-compose.yml -f docker-compose.aka-av.yml -f "$T/compose.radius.yaml" "$@"); }
vapi() { curl -sS --cacert "$P/vecgen-admin.pem" --cert "$P/prov.pem" --key "$P/prov.key" -H X-Operator-Id:scale -H Content-Type:application/json -X "$1" "https://localhost:9443/admin/v2$2" ${3:+-d "$3"} "${@:4}"; }
rapi() { curl -sS --cacert "$R/certs/admin/server.pem" --cert "$P/prov.pem" --key "$P/prov.key" -H X-Operator-Id:scale -H Content-Type:application/json -X "$1" "https://localhost:9444/admin/v2$2" ${3:+-d "$3"} "${@:4}"; }
cert() { # <名前> <CN> [SAN]: 試しの CA で署名した証明書（EC P-256）
	openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$2" -keyout "$P/$1.key" -out "$P/$1.csr" 2> /dev/null
	openssl x509 -req -in "$P/$1.csr" -CA "$P/ca.pem" -CAkey "$P/ca.key" -days 7 -out "$P/$1.pem" ${3:+-extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$3")} 2> /dev/null
}
step() { echo "== $*"; }

case ${1:?段} in
up)
	mkdir -p "$WORK" "$P"
	[ -s "$WORK/seed.bin" ] || head -c 32 /dev/urandom > "$WORK/seed.bin"
	step "リポジトリの中身（固定のコミット）"
	rm -rf "${WORK:?}/vecgen" "${WORK:?}/radius"
	mkdir -p "$V" "$WORK/radius"
	git -C "$HOME/projects/aka-vecgen" archive "$VECGEN_REF" | tar -x -C "$V"
	git -C "$HOME/projects/aka-radius" archive "$RADIUS_REF" | tar -x -C "$WORK/radius"

	step "試しの PKI（CA、エッジのサーバー証明書、AP の証明書 1 つを全 AP で使う、aka-radius・管理のクライアント）"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 -subj /CN=scale-lab-ca -keyout "$P/ca.key" -out "$P/ca.pem" 2> /dev/null
	cert edge scale-lab-edge "IP:127.0.0.1,DNS:edge"
	cert ap scale-lab-ap
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 -subj /CN=provisioner -addext extendedKeyUsage=clientAuth -keyout "$P/prov.key" -out "$P/prov.pem" 2> /dev/null
	chmod 644 "$P"/*.pem "$P"/*.key

	step "aka-vecgen"
	cd "$V" || exit 1
	cp .env.example .env
	sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD=scale-vecgen-valkey|' .env
	echo "VECGEN_SHARED_NETWORK=scale-av" >> .env
	mkdir -p secrets audit
	openssl rand -hex 32 > secrets/kek
	# 先にファイルを作る（ないと Docker が同じ名前のディレクトリを作る）
	touch secrets/admin-clients
	fp=$(vc run --rm --no-deps -T aka-vecgen fingerprint < "$P/prov.pem" 2> /dev/null)
	echo "prov=$fp" > secrets/admin-clients
	: "${fp:?}"
	chmod 644 secrets/kek secrets/admin-clients
	chmod 777 audit
	vc up -d --no-build --wait --wait-timeout 120 || exit 1
	vc exec -T aka-vecgen /aka-vecgen admin-cert > "$P/vecgen-admin.pem"

	step "aka-radius"
	cd "$R" || exit 1
	cp .env.example .env
	sed -i 's|^VALKEY_PASSWORD=.*|VALKEY_PASSWORD=scale-radius-valkey|' .env
	printf 'RADIUS_VERSION=%s\nAKA_SHARED_NETWORK=scale-av\n' "${RADIUS_REF:0:7}" >> .env
	mkdir -p sources certs/admin secrets audit backups logs_on_host
	cp sources/sources.example.json sources/sources.json
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 -subj /CN=aka-radius -addext extendedKeyUsage=clientAuth \
		-keyout sources/vecgen-client.key -out sources/vecgen-client.pem 2> /dev/null
	VCLIENT=$(vc exec -T aka-vecgen /aka-vecgen client add -name aka-radius -cert - < sources/vecgen-client.pem)
	VCLIENT_ID=$(echo "$VCLIENT" | sed -n 's/^client \([0-9]*\) added.*/\1/p')
	echo "$VCLIENT_ID" > "$WORK/vecgen-client-id"
	vc exec -T aka-vecgen /aka-vecgen av-cert > sources/vecgen-av-server.pem
	touch secrets/admin-clients
	fp=$(rc run --rm --no-deps -T admin fingerprint < "$P/prov.pem" 2> /dev/null)
	echo "provisioner=$fp" > secrets/admin-clients
	chmod -R a+rX sources
	chmod 644 secrets/admin-clients
	chmod 777 audit backups logs_on_host certs/admin
	rc run --rm --no-deps -v ./certs/admin:/out admin admin-cert create -hosts aka-radius-admin,localhost,127.0.0.1 -out /out -operator scale > /dev/null
	rc up -d --no-build --wait --wait-timeout 180 || exit 1
	echo "scale-edge-secret-0123456789" | rc exec -T admin aka-radius client add -ip 172.30.251.42 -name edge-lab -trust-stamp true -operator scale
	rc ps --format '{{.Service}} {{.Status}}'
	vc ps --format '{{.Service}} {{.Status}}'
	;;
subs) # <数>
	n=${2:?数}
	id=$(cat "$WORK/vecgen-client-id")
	step "IMSI の番号 1〜$n を aka-vecgen と aka-radius に登録する"
	bin=$WORK/scaleload
	(cd "$M/verify/scale" && go build -o "$bin" .) || exit 1
	export -f vapi rapi
	export P R
	for ((from = 1; from <= n; from += 10000)); do
		"$bin" csv -seed "$WORK/seed.bin" -kind vecgen -from "$from" -to $((from + 9999 < n ? from + 9999 : n))
	done | grep -v '^imsi' | awk -F, -v id="$id" '{printf "{\"imsi\":\"%s\",\"ki\":\"%s\",\"opc\":\"%s\",\"sqnType\":\"inc32\",\"state\":\"active\",\"allowedClientIds\":[%s]}\n", $1, $2, $3, id}' |
		xargs -P 8 -d '\n' -I{} bash -c 'vapi POST /subscribers '"'"'{}'"'"' -o /dev/null -w "%{http_code}\n"' | sort | uniq -c
	seq 1 "$n" | while read -r i; do printf '{"imsi":"%s%08d","state":"active","sourceId":"vecgen","rules":[{"tenantId":42,"nasId":"*","ssids":["scale"]}]}\n' 4401080 "$i"; done |
		xargs -P 8 -d '\n' -I{} bash -c 'rapi POST /subscribers '"'"'{}'"'"' -o /dev/null -w "%{http_code}\n"' | sort | uniq -c
	vapi GET /status | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("aka-vecgen の加入者", d.get("subscriberCount"))'
	rapi GET /status | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("aka-radius の加入者", d.get("subscriberCount"))'
	;;
aps) # <AP の数> <加入者の数>
	n=${2:?AP の数}
	s=${3:?加入者の数}
	python3 -I - "$n" "$s" "$P" > "$WORK/aps.json" << 'PY'
import json, sys
n, s, p = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
h = s // 2
out = []
for i in range(n):
    t = "lab1" if i < n // 2 else "lab2"
    lo, hi = (1, h) if t == "lab1" else (h + 1, s)
    out.append({"tenant": t, "name": f"ap{i + 1:04d}", "addr": "127.0.0.1:12083", "cert": f"{p}/ap.pem", "key": f"{p}/ap.key", "ca": f"{p}/ca.pem", "from": lo, "to": hi})
json.dump(out, sys.stdout, indent=1)
PY
	echo "$WORK/aps.json: AP $n（lab1・lab2 に半分ずつ、加入者 $s）"
	;;
logs)
	for svc in auth acct; do
		echo "$svc: WARN・ERROR $(rc logs --no-color "$svc" 2> /dev/null | grep -cE '"level":"(WARN|ERROR)"')"
		rc logs --no-color "$svc" 2> /dev/null | grep -oE '"event_id":"[A-Z_]+"' | sort | uniq -c | sort -rn | head -8
	done
	echo "aka-vecgen: WARN・ERROR $(vc logs --no-color aka-vecgen 2> /dev/null | grep -cE '"level":"(WARN|ERROR)"')"
	vc logs --no-color aka-vecgen 2> /dev/null | grep -oE '"event_id":"[A-Z_]+"' | sort | uniq -c | sort -rn | head -5
	echo "edge: $(rc logs --no-color edge 2> /dev/null | grep -ciE 'error|fail')"
	;;
down)
	rc down -v 2>&1 | tail -1
	vc down -v 2>&1 | tail -1
	# UID 65532 などが作ったファイルは手元のユーザーで消せないので、コンテナで消す
	docker run --rm -v "$WORK:/w" busybox:1.37.0 sh -c 'rm -rf /w/vecgen /w/radius /w/pki' 2> /dev/null
	;;
*)
	echo "段は up・subs・aps・logs・down" >&2
	exit 2
	;;
esac
