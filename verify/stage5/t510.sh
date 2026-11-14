#!/bin/bash
# 段階 5 の T5-10（と T5-24）: edge-02 の dockerd の再起動と、docker-ce・containerd.io の更新を、
# AP の負荷（T5-23 の aka-loadgen。740 本）をかけたまま確かめる。手元で動かす。
#   WORK=<手元の作業ディレクトリ> ./t510.sh snap <名前>        edge-02 の今の状態を $WORK/t510/<名前>.txt に残す
#   WORK=... ./t510.sh restart                                 snap → systemctl restart docker → 戻るまでの時間 → snap → 比べる
#   WORK=... ./t510.sh upgrade <docker-ce の版> <containerd.io の版>
#                                                              同じく apt で上げる（hold を外して入れ、containerd.io も含めて hold し直す）
#   WORK=... ./t510.sh apply <テナントの ID>                    aka-provisioner を通して反映し、終わるまで待つ
#   WORK=... ./t510.sh diff <名前 1> <名前 2>                   コンテナの起動の時刻・再起動の回数が変わったものを出す
# 確かめること: コンテナが作り直されない（live-restore）、AP の接続が保たれる、agent がつなぎ直す、反映が通る、ログが届き続ける。
# 1 時間の測定は edge-02 の 10 分ごとの測定（load-measure.py）を使う。
set -uo pipefail
: "${WORK:?}"
T=$(cd "$(dirname "$0")" && pwd)
S="ssh -o ConnectTimeout=15 -F $HOME/aka-deploy/ssh_config"
E=edge-02
OUT=$WORK/t510
mkdir -p "$OUT"
PROV="sudo curl -sS -m 40 --cert /opt/aka-ossbss/certs/provisioner-client.pem --cacert /opt/aka-ossbss/certs/provisioner-server.pem -H 'X-Operator-Id: deploy'"
BASE=https://127.0.0.1:9446/admin/v2/edges/$E

status() { # aka-provisioner を通して読んだエッジの /status の要点
	$S aka-mgmt "$PROV '$BASE/status'" < /dev/null 2> /dev/null | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin); a = d.get("agent", {})
    print("agent ok=%s docker=%s used=%s" % (a.get("ok"), a.get("dockerOk"), d.get("capacity", {}).get("used")))
except Exception as e:
    print("status を読めない", e)'
}

snap() { # <名前>
	local f=$OUT/$1.txt
	{
		echo "# $1 $(date '+%F %T')"
		# bash -s に流す（中で標準入力を読むコマンドは使わない）
		$S aka-$E 'sudo bash -s' << 'EOF'
echo "versions: dockerd $(docker version -f '{{.Server.Version}}') containerd $(containerd --version | cut -d' ' -f3) dpkg $(dpkg-query -W -f='${Package}=${Version} ' docker-ce containerd.io)"
echo "hold: $(apt-mark showhold | tr '\n' ' ')"
echo "running: $(docker ps -q | wc -l) all: $(docker ps -aq | wc -l)"
echo "conntrack-estab（テナントのポート宛て）: $(conntrack -L -p tcp --state ESTABLISHED 2> /dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^dport=/) {split($i, a, "="); if (a[2] >= 20000 && a[2] <= 21999) c++; break}} END {print c + 0}')"
echo "log-bytes: $(stat -c %s /var/lib/radsec-edge/logs/radsecproxy.log)"
echo "log-last: $(tail -n 1 /var/lib/radsec-edge/logs/radsecproxy.log | cut -c1-160)"
echo "dockerd: $(systemctl show docker -p ActiveEnterTimestamp --value) containerd: $(systemctl show containerd -p ActiveEnterTimestamp --value)"
docker ps -aq | xargs docker inspect -f 'started {{.Name}} {{.State.StartedAt}} {{.RestartCount}} {{.State.Status}}' | sort
EOF
		echo "edge: $(status)"
		echo "loadgen: $($S aka-loadgen 'cat ~/load/ap-status.json' < /dev/null)"
	} > "$f"
	grep -v '^started' "$f"
}

cmp_snap() { # <名前 1> <名前 2>
	python3 -I - "$OUT/$1.txt" "$OUT/$2.txt" << 'EOF'
import sys
def read(p):
    return {l.split()[1]: l.split()[2:] for l in open(p, encoding="utf-8") if l.startswith("started ")}
a, b = read(sys.argv[1]), read(sys.argv[2])
changed = [n for n in sorted(set(a) | set(b)) if a.get(n) != b.get(n)]
print(f"コンテナ {len(a)} → {len(b)}、起動の時刻・再起動の回数・状態が変わったもの {len(changed)}")
for n in changed:
    print(" ", n, a.get(n), "→", b.get(n))
EOF
}

wait_back() { # <始めた時刻（秒）> dockerd と agent が戻るまで待って時間を出す
	local t0=$1 t1 t2
	until $S aka-$E 'sudo docker info -f "{{.ServerVersion}}"' > /dev/null 2>&1 < /dev/null; do sleep 1; done
	t1=$(date +%s.%N)
	until status | grep -q 'agent ok=True docker=True'; do sleep 2; done
	t2=$(date +%s.%N)
	printf 'dockerd が応えるまで %.1f 秒、agent が ok になるまで %.1f 秒（手元から測った）\n' "$(echo "$t1 - $t0" | bc)" "$(echo "$t2 - $t0" | bc)"
}

case ${1:-} in
snap) snap "$2" ;;
diff) cmp_snap "$2" "$3" ;;
restart)
	snap before-restart
	t0=$(date +%s.%N)
	echo "== systemctl restart docker（$(date +%T)）"
	$S aka-$E 'sudo systemctl restart docker' < /dev/null
	wait_back "$t0" | tee "$OUT/restart-time.txt"
	echo "== 60 秒待つ"
	sleep 60
	snap after-restart
	cmp_snap before-restart after-restart
	;;
upgrade)
	dv=$2 cv=$3
	snap before-upgrade
	t0=$(date +%s.%N)
	echo "== docker-ce $dv・containerd.io $cv（$(date +%T)）"
	$S aka-$E "sudo apt-mark unhold docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io > /dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o Dpkg::Options::=--force-confold docker-ce=$dv docker-ce-cli=$dv docker-ce-rootless-extras=$dv containerd.io=$cv 2>&1 | grep -E '^(Setting up|Unpacking|E:|W:)'; sudo apt-mark hold docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io" < /dev/null
	wait_back "$t0" | tee "$OUT/upgrade-time.txt"
	echo "== 60 秒待つ"
	sleep 60
	snap after-upgrade
	cmp_snap before-upgrade after-upgrade
	;;
apply)
	id=$2
	t=$(date -u +%Y-%m-%dT%H:%M:%S)
	echo "== テナント $id を反映（$(date +%T)）: $($S aka-mgmt "$PROV -w '\n%{http_code}\n' -H 'Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)' -X POST '$BASE/tenants/$id/apply'" < /dev/null | tail -1)"
	for i in $(seq 1 40); do
		sleep 3
		j=$($S aka-mgmt "$PROV '$BASE/tenants/$id'" < /dev/null)
		echo "$j" | python3 -I -c 'import json, sys; a = json.load(sys.stdin)["apply"]; sys.exit(0 if a["state"] == "idle" and a.get("lastFinishedAt", "") >= sys.argv[1] else 1)' "$t" && break
	done
	echo "$j" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(json.dumps({k: d.get(k) for k in ("id", "slug", "revision", "appliedRevision", "pending", "configHash", "apply")}, ensure_ascii=False))'
	;;
*) echo "使い方は先頭の説明を見る" >&2; exit 2 ;;
esac
