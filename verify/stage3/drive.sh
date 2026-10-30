#!/bin/bash
# 段階 3 の終わりの通し（概要 §18.7 の Q8）の台本。手元で動かす。検証機は stage3.sh を ssh で呼び、画面は playwright-cli で開く。
#
#   SITE=<site.env のパス> WORK=<手元の作業ディレクトリ> ./drive.sh <段>
#
# 段: prepare setup login-start login-pin <PIN> u e b k m o c end teardown
# site.env（公開しない）: BASE（公開ホスト名の URL）、OSSBSS_ACCESS_TEAM_DOMAIN、OSSBSS_ACCESS_AUD、ADMIN_EMAIL、TOKEN_FILE
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
. "${SITE:?}"
: "${WORK:?}"
mkdir -p "$WORK/files"
RES=$WORK/results.tsv
HOSTNAME_SSH=${SSH_HOST:-simwifi}
REMOTE='~/aka-work/stage3'
A=440100000000001 B=440100000000002 C=440100000000003
PW() { (cd "$WORK" && playwright-cli -s=stage3 "$@"); }
# R <サブコマンド> [引数]: 検証機で stage3.sh を動かす。PASS / FAIL の行を結果に足す
R() {
	local q="" a
	for a in "$@"; do q="$q $(printf '%q' "$a")"; done
	ssh "$HOSTNAME_SSH" "cd $REMOTE/tools && ./stage3.sh$q" 2>&1 | tee -a "$WORK/remote.log" | tee >(grep -E $'^[A-Z][0-9]+\t(PASS|FAIL)\t' >> "$RES")
	sleep 0.2
}
Rq() { R "$@" > /dev/null; }
Rv() { R "$@" | tail -1; } # 最後の行（値）だけ
# UI <台本> [引数...]: 画面の台本を動かす。__A1__ などを置き換える
UI() {
	local name=$1 i=1 f="$WORK/run-$1.js" out
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
info() { UI "$@" | grep -E $'\tINFO\t' | tail -1 | cut -f3-; }

# 止めたときの画面の文（o の一部。これだけをやり直せるように分ける）
o_stop() {
	Rq stop pc aka-provisioner
	UI errors O7 '解決できません' / 'aka-provisioner が止まるとダッシュボードに出る'
	UI opfail O8 $A radius
	n=$(Rv sql "SELECT check_needed FROM subscribers WHERE imsi='$A'")
	Rq mark O9 "結果が分からない操作は印が立つ（$n）" "$([ "$n" = t ]; echo $?)"
	Rq start pc aka-provisioner
	sleep 10
	UI errors O10 "$A" "/subscribers/$A" '詳細を開くと読み直す'
	n=$(Rv sql "SELECT check_needed||'/'||radius_state FROM subscribers WHERE imsi='$A'")
	Rq mark O11 "aka-provisioner が戻ると印が下りる（$n）" "$([ "$n" = false/active ]; echo $?)"
	Rq stop rc admin
	sleep 2
	UI opfail O12 $A radius
	Rq start rc admin
	sleep 10
	UI errors O13 "$A" "/subscribers/$A" '下流が戻ると詳細を開ける'
	n=$(Rv sql "SELECT check_needed||'/'||radius_state FROM subscribers WHERE imsi='$A'")
	Rq mark O14 "下流が戻ると印が下りる（$n）" "$(case $n in false/*) echo 0 ;; *) echo 1 ;; esac)"
}

phase=${1:?}
shift
case $phase in
prepare)
	. "$T/refs.env"
	set -e
	B0=$WORK/build
	mkdir -p "$B0"
	ssh "$HOSTNAME_SSH" "mkdir -p $REMOTE/vecgen $REMOTE/radius $REMOTE/prov $REMOTE/ossbss $REMOTE/tools"
	for x in "aka-vecgen $VECGEN_REF vecgen s3vecgen-aka-vecgen:latest" "aka-radius $RADIUS_REF radius aka-radius:dev" \
		"aka-provisioner $PROVISIONER_REF prov aka-provisioner:dev" "aka-ossbss $OSSBSS_REF ossbss s3ossbss-aka-ossbss:latest"; do
		set -- $x
		git -C ~/projects/"$1" archive "$2" | ssh "$HOSTNAME_SSH" "tar x -C $REMOTE/$3"
		rm -rf "${B0:?}/$1"
		mkdir -p "$B0/$1"
		git -C ~/projects/"$1" archive "$2" | tar x -C "$B0/$1"
		docker build -q --build-arg VERSION="${2:0:7}" -t "$4" "$B0/$1"
	done
	docker build -q -t stage2-tools:dev "$T/../stage2"
	(cd ~/projects/eapaka_test && CGO_ENABLED=0 go build -o "$WORK/eapaka_test" ./cmd/eapaka_test 2> /dev/null || CGO_ENABLED=0 go build -o "$WORK/eapaka_test" .)
	scp -q "$WORK/eapaka_test" "$T/stage3.sh" "$T/compose.radius.yaml" "$T/edge-t1.conf" "$T/edge-t2.conf" "$HOSTNAME_SSH:aka-work/stage3/tools/"
	grep -E '^(OSSBSS_ACCESS_TEAM_DOMAIN|OSSBSS_ACCESS_AUD|ADMIN_EMAIL|TOKEN_FILE)=' "$SITE" | ssh "$HOSTNAME_SSH" "umask 077; cat > $REMOTE/site.env"
	docker save s3vecgen-aka-vecgen:latest aka-radius:dev aka-provisioner:dev s3ossbss-aka-ossbss:latest stage2-tools:dev | gzip -1 | ssh "$HOSTNAME_SSH" 'gunzip | docker load' | tail -5
	;;
k6) # 下流からの削除だけをやり直す
	info reconcile act 440100009000002 delete
	c=$(ssh "$HOSTNAME_SSH" "cd $REMOTE/tools && ./stage3.sh dapi radius GET /subscribers/440100009000002" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status"))')
	Rq mark K6 "台帳にない IMSI を下流から削除できる（$c）" "$([ "$c" = 404 ]; echo $?)"
	;;
o-stop)
	o_stop
	UI state radius inactive $A
	UI state radius active $A
	R trace-check O1
	;;
tools) # 道具だけを送り直す
	scp -q "$T/stage3.sh" "$T/compose.radius.yaml" "$T/edge-t1.conf" "$T/edge-t2.conf" "$HOSTNAME_SSH:aka-work/stage3/tools/"
	;;
setup)
	: > "$RES"
	R setup
	# ログインしていない要求は Cloudflare で止まる
	loc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/")
	case $loc in
	30*cloudflareaccess.com*) r=0 ;;
	*) r=1 ;;
	esac
	Rq mark C0 "ログインしていない要求は Access のログインへ送られる（${loc%% *}）" $r
	;;
login-start)
	PW open > /dev/null
	PW goto "$BASE/" | grep -E 'Page URL|Page Title' | sed -E 's#https?://[^ ]*#<url>#'
	;;
u) UI u ;;
e)
	R eap E1 "画面で登録した加入者の EAP-AKA が通る（刻印はテナント 1）" $A aka accept AUTH_SUCCESS
	R eap E2 "EAP-AKA' が通る" $B prime accept AUTH_SUCCESS
	R eap E3 "再同期で通る" $A aka accept EAP_RESYNC_CHALLENGE 11812 00000F000000
	R eap E4 "SSID が認可ポリシーと違えば拒否" $C aka reject AUTH_POLICY_DENIED
	R eap E5 "別のテナントのエッジからは拒否" $A aka reject AUTH_POLICY_DENIED 21812
	UI state radius inactive $A
	R eap E6 "画面で radius 側を止めると拒否" $A aka reject AUTH_SUBSCRIBER_INACTIVE
	UI state radius active $A
	UI state vecgen inactive $A
	R eap E7 "画面で vecgen 側を止めると拒否（取得先が断る）" $A aka reject VECTOR_REJECTED
	UI state vecgen active $A
	R eap E8 "両方を戻すと通る" $A aka accept AUTH_SUCCESS
	R acct-start $A
	UI sessions $A
	R acct-stop $A
	;;
b)
	python3 -I - "$WORK/files" << 'PY'
import sys
d = sys.argv[1]
K = "465b5ce8b199b49faa5f0a2ee238a6bc,cd63cb71954a9f4e48a5994e37a02baf,,"
with open(f"{d}/v.csv", "w") as f:
    f.write("imsi,ki,opc,amf,sqn\n")
    for i in range(10000):
        f.write(f"44010{1000000 + i:010d},{K}\n")
with open(f"{d}/r.csv", "w") as f:
    f.write("imsi\n")
    for i in range(10000):
        f.write(f"44010{1000000 + i:010d}\n")
with open(f"{d}/r2.csv", "w") as f:
    f.write("imsi\n")
    for i in range(3000):
        f.write(f"44010{2000000 + i:010d}\n")
PY
	v=$(info job vecgen.create "$WORK/files/v.csv")
	r=$(info job radius.create "$WORK/files/r.csv")
	echo "job: $v / $r"
	R jobs-wait bulk
	R bulk-check "${v%% *}" "${r%% *}"
	R eap B3 "一括投入の加入者が通る（EAP-AKA）" 440100001000000 aka accept AUTH_SUCCESS
	R eap B4 "一括投入の加入者が通る（EAP-AKA'）" 440100001009999 prime accept AUTH_SUCCESS
	# 同じファイルの投入し直し: 全部「既にある」
	x=$(info job radius.create "$WORK/files/r.csv")
	echo "job: $x"
	R jobs-wait again > /dev/null
	n=$(Rv sql "SELECT ok_count||'/'||exists_count||'/'||state FROM bulk_jobs WHERE id=${x%% *}")
	Rq mark B5 "同じファイルの投入し直しは全部「既にある」で下流を呼ばない（$n）" "$([ "$n" = "0/10000/completed" ]; echo $?)"
	# 下流を止めて自動の中断、同じファイルで残りだけ
	y=$(info job radius.create "$WORK/files/r2.csv")
	Rq stop rc admin
	R jobs-wait interrupt > /dev/null
	n=$(Rv sql "SELECT state||'/'||ok_count||'/'||unprocessed_count FROM bulk_jobs WHERE id=${y%% *}")
	echo "interrupted: $n"
	Rq mark B6 "下流が止まると自動で中断する（$n）" "$(case $n in interrupted/*) echo 0 ;; *) echo 1 ;; esac)"
	Rq start rc admin
	sleep 8
	z=$(info job radius.create "$WORK/files/r2.csv")
	R jobs-wait resume > /dev/null
	n=$(Rv sql "SELECT state||'/'||ok_count||'/'||exists_count||'/'||failed_count||'/'||total FROM bulk_jobs WHERE id=${z%% *}")
	echo "resumed: $n"
	Rq mark B7 "同じファイルで残りだけ処理される（$n）" "$(echo "$n" | awk -F/ '{exit !($1=="completed" && $2+$3==$5 && $4==0 && $3>0)}'; echo $?)"
	;;
k)
	n=$(Rv drift-state 5)
	info reconcile run > /dev/null
	s=$(Rv run-state)
	echo "run: $s"
	Rq mark K1 "状態のずれ $n 件を自動で直す（$s）" "$(echo "$s" | awk -F'|' '{exit !($1=="completed" && $3==5)}'; echo $?)"
	n=$(Rv drift-state 1001)
	info reconcile run > /dev/null
	s=$(Rv run-state)
	echo "run: $s"
	Rq mark K2 "$n 件は上限を超えるので何も直さず保留（$s）" "$(echo "$s" | awk -F'|' '{exit !($1=="held" && $3==0)}'; echo $?)"
	info reconcile approve > /dev/null
	s=$(Rv run-state)
	echo "run: $s"
	Rq mark K3 "承認すると直す（$s）" "$(echo "$s" | awk -F'|' '{exit !($1=="completed" && $3==1001)}'; echo $?)"
	n=$(Rv sql "SELECT count(*) FROM subscribers WHERE radius_state='inactive' AND imsi BETWEEN '440100001000000' AND '440100001999999'")
	Rq mark K4 "台帳の radius 側の停止中が 1,006 件（$n）" "$([ "$n" = 1006 ]; echo $?)"
	Rq drift-new 440100009000001 440100009000002
	info reconcile run > /dev/null
	info reconcile act 440100009000001 import
	info reconcile act 440100009000002 delete
	n=$(Rv sql "SELECT tenant_id||'/'||radius_state FROM subscribers WHERE imsi='440100009000001'")
	Rq mark K5 "台帳にない IMSI を取り込める（$n）" "$([ "$n" = "1/inactive" ]; echo $?)"
	c=$(ssh "$HOSTNAME_SSH" "cd $REMOTE/tools && ./stage3.sh dapi radius GET /subscribers/440100009000002" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status"))')
	Rq mark K6 "台帳にない IMSI を下流から削除できる（$c）" "$([ "$c" = 404 ]; echo $?)"
	Rv sql "SELECT 'reconcile 1 万件の時間（秒）: '||round(extract(epoch FROM finished_at-started_at)::numeric,1) FROM reconcile_runs WHERE state='completed' ORDER BY id DESC LIMIT 1"
	;;
m)
	export GNUPGHOME=$WORK/gh
	rm -rf "${GNUPGHOME:?}"
	mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
	gpg --batch --passphrase '' --quick-generate-key 'stage3 <stage3@example.com>' default default 2y 2> /dev/null
	UI charging key "$(gpg --armor --export | base64 -w0)"
	R backup-db backups/pre-close.dump
	Rq usage-yesterday
	info charging import > /dev/null
	Rq shift-month
	f=$(info charging close)
	echo "files: $f"
	d=$(info charging download "$WORK/files/")
	echo "download: $d"
	rm -rf "$WORK/files/x1"
	python3 -I "$T/../charging/verify-file.py" -o "$WORK/files/x1" "$WORK/files/$d" | tail -3
	Rq mark M2 "Cloudflare 越しにダウンロードしたファイルが verify-file.py を通る（$d）" "${PIPESTATUS[0]}"
	python3 -I - "$WORK/files/x1" << 'PY' > "$WORK/m3.txt"
import csv, sys, os
d = sys.argv[1]
root = next(r for r, _, fs in os.walk(d) if "lines.csv" in fs)
lines = list(csv.DictReader(open(f"{root}/lines.csv", newline="")))
a = [l for l in lines if l["imsi"] == "440100000000001" and l["tenant_id"] == "1"]
ok = len(a) == 1 and a[0]["input_octets"] == "4294968796" and a[0]["output_octets"] == "800" and a[0]["session_count"] == "1" \
    and a[0]["line_external_id"] == "LINE-001" and a[0]["tenant_external_id"] == "CUST-001" and len(lines) >= 13000 and a[0]["usage_complete"] == "true"
print(0 if ok else 1, len(lines), a[0]["usage_complete"] if a else "-")
PY
	read -r rc nl uc < "$WORK/m3.txt"
	Rq mark M3 "行 $nl 件。A の利用（in 4294968796・out 800・1 回）と外部の番号が手の計算と合う（usage_complete=$uc）" "$rc"
	f=$(info charging rebuild)
	echo "files: $f"
	d2=$(info charging download "$WORK/files/")
	rm -rf "$WORK/files/x2"
	python3 -I "$T/../charging/verify-file.py" -o "$WORK/files/x2" "$WORK/files/$d2" | tail -1
	Rq mark M4 "作り直しで版が上がり、同じ通し番号で通る（$d2）" "$(case $d2 in *_v2.zip.pgp) echo 0 ;; *) echo 1 ;; esac)"
	n=$(Rv sql "SELECT count(*) FROM audit_log WHERE action='charging.download'")
	Rq mark M5 "ダウンロードは毎回監査ログに残る（$n）" "$([ "$n" = 2 ]; echo $?)"
	echo "$d" > "$WORK/first-file"
	;;
o)
	R logs-check O2 O3 O4
	Rq stop oc postgres
	UI errors O5 'データベースに接続できません' / 'DB が止まると 503 の文'
	Rq start oc postgres
	sleep 8
	UI errors O6 'システム管理者' / 'DB が戻ると画面が戻る'
	o_stop
	# 届いた操作を 1 つ行ってからたどる
	UI state radius inactive $A
	UI state radius active $A
	R trace-check O1
	R remote-check C4
	R backup-valkey-prov | tail -2
	n=$(R check-downstream | grep -c '接続できました')
	Rq mark O15 "aka-provisioner の Valkey のバックアップと戻しの後も下流につながる（$n）" "$([ "$n" = 2 ]; echo $?)"
	# DB の戻し（締めより前の写しに戻すと、同じ通し番号でファイルができる。ガイドの 11.2）
	R restore-db backups/pre-close.dump | tail -1
	R up-ossbss | tail -1
	sleep 8
	n=$(Rv sql "SELECT count(*) FROM charging_periods")
	Rq mark O16 "締めより前の写しに戻すと締めが消える（$n）" "$([ "$n" = 0 ]; echo $?)"
	info reconcile run > /dev/null
	s=$(Rv run-state)
	Rq mark O17 "戻した後に突き合わせを動かせる（$s）" "$(echo "$s" | awk -F'|' '{exit !($1=="completed" || $1=="held")}'; echo $?)"
	Rq usage-yesterday
	info charging import > /dev/null
	Rq shift-month
	info charging close > /dev/null
	d=$(info charging download "$WORK/files/again-")
	echo "again: $d / first: $(cat "$WORK/first-file")"
	Rq mark O18 "締め直すと同じ通し番号のファイルができる（ガイドの 11.2 のとおり）" "$([ "$d" = "$(cat "$WORK/first-file")" ]; echo $?)"
	;;
c)
	Rq role tenant_user 1
	UI role tenant_user
	Rq role operator NULL
	UI role operator
	Rq role system_admin NULL true
	UI errors C5 '登録されていません' / '無効のアカウントは 403 の文'
	Rq role system_admin NULL false
	UI errors C5b 'システム管理者' / '有効に戻すと次の要求から使える'
	R bad-aud | tail -1
	UI errors C11 'Cloudflare Access を通して開いてください' / 'AUD が合わなければ 401 の文'
	R bad-team | tail -1
	UI errors C12 '公開鍵を取得できません' / 'Access の公開鍵を取れなければ 503 の文'
	R restore-access | tail -1
	sleep 3
	UI errors C13 'システム管理者' / '設定を戻すと画面が戻る'
	;;
end)
	UI logout
	echo ==== 結果; cat "$RES"
	echo "PASS $(grep -c $'\tPASS\t' "$RES") / FAIL $(grep -c $'\tFAIL\t' "$RES")"
	;;
teardown)
	R teardown | tail -6
	ssh "$HOSTNAME_SSH" 'sudo rm -rf ~/aka-work/stage3; docker image prune -af > /dev/null; docker builder prune -af > /dev/null; docker ps -a -q | wc -l'
	;;
*)
	echo "unknown: $phase" >&2
	exit 2
	;;
esac
