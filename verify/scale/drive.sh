#!/bin/bash
# 段階 6 の規模の試験（概要 §18.13 の S6-3〜S6-6、確認事項 L6-1〜L6-9）を手元から進める台本。README.md の「段」の順に動かす。
# ノードへは踏み台（監視ノード）を通した SSH（~/aka-deploy/ssh_config）、一時の VPS は aka-loadgen（ssh_config に足す）、画面は playwright-cli。
# 公開しない値（BASE・ADMIN_EMAIL）は $WORK/site.env。結果は $WORK に残し、伏せてから verify/scale/results/ に写す。
#
#   export WORK=~/aka-deploy/stage6
#   verify/scale/drive.sh <段> [引数]
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
M=$(cd "$T/../.." && pwd)
S4=$M/verify/stage4
S5=$M/verify/stage5
WORK=${WORK:?作業場所}
SSHCFG=$HOME/aka-deploy/ssh_config
LG=aka-loadgen        # 一時の VPS（ssh_config の Host）
RL=/home/debian/scale # 一時の VPS の作業場所
mkdir -p "$WORK"/{req,run,pki,csr,jobs,out}
[ -e "$WORK/site.env" ] || cp "$HOME/aka-deploy/stage5/site.env" "$WORK/site.env"
# shellcheck disable=SC1091
. "$WORK/site.env"
N() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "aka-$1" "${@:2}" < /dev/null; }
Ni() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "aka-$1" "${@:2}"; }
L() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "$LG" "$@" < /dev/null; }
Li() { ssh -o ConnectTimeout=15 -F "$SSHCFG" "$LG" "$@"; }
sql() { echo "$1" | Ni mgmt 'cd /opt/aka-ossbss && docker compose exec -T postgres psql -U ossbss -d ossbss -At -v ON_ERROR_STOP=1'; }
PW() { (cd "$WORK" && timeout "${PWT:-300}" playwright-cli -s=stage6 "$@" < /dev/null); }
# 画面の台本を __BASE__・__A1__… を置き換えて動かし、JSON の文字列の行を出す（段階 5 の drive.sh の UI と同じ）。
# 引数が @<ファイル> ならファイルの中身で置き換える（1 つの引数は 128 KiB までなので、大きい値はファイルで渡す）
UI() {
	local src=$1 f="$WORK/run-$(basename "$1")"
	shift
	python3 -I - "$src" "$f" "$BASE" "$@" << 'PY'
import sys
src, dst, base, *args = sys.argv[1:]
s = open(src, encoding="utf-8").read().replace("__BASE__", base)
for i, a in enumerate(args, 1):
    if a.startswith("@"):
        a = open(a[1:], encoding="utf-8").read().strip()
    s = s.replace(f"__A{i}__", a)
open(dst, "w", encoding="utf-8").write(s)
PY
	PW --raw run-code --filename="$(basename "$f")" 2>&1 | python3 -I -c '
import json, sys
lines = sys.stdin.read().splitlines()
js = [l for l in lines if l.startswith("\"")]
print(json.loads(js[-1]) if js else json.dumps({"s": -1, "a": "\n".join(lines)[-300:]}))'
}
# BULK <要求の JSON>: 段階 5 の ui/bulk.js でまとめて送り、結果の JSON を出す
BULK() {
	base64 -w0 "$1" > "$WORK/run/bulk.b64"
	PWT=1800 UI "$S5/ui/bulk.js" "@$WORK/run/bulk.b64"
}
# provisioner <パス>: 管理面から aka-provisioner の API を読む（クライアント証明書は aka-ossbss のもの）
provisioner() {
	N mgmt "sudo curl -sS -m 30 --cert /opt/aka-ossbss/certs/provisioner-client.pem --cacert /opt/aka-ossbss/certs/provisioner-server.pem -H 'X-Operator-Id: scale' 'https://127.0.0.1:9446/admin/v2$1'"
}
state() { sql "SELECT t.id, t.name, coalesce(r.slug, ''), coalesce(r.port::text, ''), coalesce(string_agg(p.edge_id || ':' || p.slot, ',' ORDER BY p.slot) FILTER (WHERE p.id IS NOT NULL), '')
	FROM tenants t LEFT JOIN tenant_radsec r ON r.tenant_id = t.id LEFT JOIN placements p ON p.tenant_id = t.id AND p.deleted_at IS NULL AND p.removed_at IS NULL
	WHERE t.name ~ '^sc[0-9]{4}$' AND t.deleted_at IS NULL GROUP BY t.id, t.name, r.slug, r.port ORDER BY t.name"; }
certs_tsv() { sql "SELECT t.name, t.id, r.port, a.name, a.id, c.serial FROM tenants t JOIN tenant_radsec r ON r.tenant_id = t.id JOIN aps a ON a.tenant_id = t.id AND a.deleted_at IS NULL
	JOIN LATERAL (SELECT serial FROM ap_certs WHERE ap_id = a.id AND revoked_at IS NULL ORDER BY issued_at DESC LIMIT 1) c ON true
	WHERE t.name ~ '^sc[0-9]{4}$' AND t.deleted_at IS NULL ORDER BY t.name, a.name"; }
lgctl() { L "curl -sS -m 600 -X ${2:-GET} 'http://127.0.0.1:9900$1'"; } # <パス> [POST]
step() { echo "== $(date +%T) $*"; }

case ${1:?段} in
prepare) # 種（無ければ作る。600）、scaleload（静的なバイナリ）、計画の表
	[ -s "$WORK/seed.bin" ] || (umask 077 && head -c 32 /dev/urandom > "$WORK/seed.bin")
	(cd "$T" && CGO_ENABLED=0 go build -trimpath -o "$WORK/scaleload" .) || exit 1
	ls -l "$WORK/seed.bin" "$WORK/scaleload"
	python3 -I "$T/scale.py" plan
	;;
login-start) # Access のログイン画面でメールアドレスを送る（PIN はユーザーから。10 分で切れる）
	PW open > /dev/null 2>&1
	PW goto "$BASE/" | grep -E 'Page Title'
	UI "$S5/ui/login.js" "$ADMIN_EMAIL"
	;;
login-pin) # <PIN>
	UI "$S5/ui/pin.js" "${2:?PIN}"
	;;
tenants) # テナント sc0001〜sc1000 を作る（まだないものだけ。50 件ずつ）
	state > "$WORK/run/state.tsv"
	python3 -I "$T/scale.py" tenants "$WORK/run/state.tsv" "$WORK/req/tenants-all.json"
	python3 -I - "$WORK/req/tenants-all.json" "$WORK/req/tenants-" << 'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for k in range(0, len(r), 50):
    json.dump(r[k:k + 50], open(f"{sys.argv[2]}{k // 50:03d}.json", "w"), ensure_ascii=False)
print(len(r), "件")
PY
	t0=$(date +%s)
	for f in "$WORK"/req/tenants-[0-9][0-9][0-9].json; do
		[ -e "$f" ] || break
		BULK "$f" > "${f%.json}.out.json"
		echo "$(basename "$f") $(date +%T) $(python3 -I "$T/scale.py" result "${f%.json}.out.json" | tr '\n' ' ')"
		rm -f "$f"
	done
	state > "$WORK/run/state.tsv"
	echo "テナント $(wc -l < "$WORK/run/state.tsv")、$(($(date +%s) - t0)) 秒"
	;;
jobs) # 一括投入 40 本（各側 20 本）を 1 本ずつ登録して確定する（済みのものは飛ばす）。[extra] なら ③ の sc0020 の vecgen 側 1 万件
	client=$(provisioner /vecgen/clients | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(",".join(str(c["id"]) for c in d.get("items", d) if c.get("name") == "aka-radius"))')
	source=$(provisioner /radius/sources | python3 -I -c 'import json,sys; d=json.load(sys.stdin); s=d.get("items", d); print(s[0]["id"] if s else "")')
	echo "aka-vecgen の許可クライアント: ${client:?aka-radius のクライアントがない}、aka-radius の取得先: ${source:?取得先がない}"
	state > "$WORK/run/state.tsv"
	rm -f "$WORK"/jobs/*.b64
	python3 -I "$T/scale.py" jobs "$WORK/run/state.tsv" "$WORK/run/jobs-done.txt" "$client" "$source" "$WORK/seed.bin" "$WORK/scaleload" "$WORK/jobs" ${2:-}
	for f in "$WORK"/jobs/*.b64; do
		[ -e "$f" ] || break
		name=$(basename "$f" .b64)
		r=$(PWT=600 UI "$T/ui/upload.js" "@$f")
		echo "$(date +%T) $name $r"
		if echo "$r" | python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get("job") and d.get("cs") in (200, 303) else 1)'; then
			echo "$name" >> "$WORK/run/jobs-done.txt"
		fi
		rm -f "$f"
	done
	;;
jobs-wait) # ジョブが全部終わるまで待ち（最大 2 時間）、ジョブごとの時間を出す（① 1 万件が 30 分以内）
	for _ in $(seq 1 240); do
		r=$(sql "SELECT count(*) FILTER (WHERE state IN ('queued', 'running', 'validated')) || ' ' || count(*) FILTER (WHERE state = 'completed') || ' ' || count(*) FILTER (WHERE state IN ('interrupted', 'canceled')) FROM bulk_jobs WHERE file_name ~ '^(vecgen|radius)-sc[0-9]{4}-[0-9]\\.csv$'")
		echo "$(date +%T) 待ち・実行中 / 済み / 中断・取り消し: $r"
		[ "${r%% *}" = 0 ] && break
		sleep 30
	done
	sql "SELECT id, file_name, state, total, ok_count, failed_count, coalesce(started_at::text, ''), coalesce(finished_at::text, '') FROM bulk_jobs
		WHERE file_name ~ '^(vecgen|radius)-sc[0-9]{4}-[0-9]\\.csv$' ORDER BY id" > "$WORK/run/jobs.tsv"
	python3 -I "$T/scale.py" jobs-report "$WORK/run/jobs.tsv" | tee "$WORK/run/jobs-report.txt"
	;;
radsec) # 19 テナントで RadSec を有効にし、primary・secondary に置く
	state > "$WORK/run/state.tsv"
	python3 -I "$T/scale.py" radsec "$WORK/run/state.tsv" "$WORK/req/radsec.json"
	BULK "$WORK/req/radsec.json" > "$WORK/req/radsec.out.json"
	python3 -I "$T/scale.py" result "$WORK/req/radsec.out.json"
	state > "$WORK/run/state.tsv"
	awk -F'|' '$3 != "" {print $2, $3, $4, $5}' "$WORK/run/state.tsv"
	;;
lg-setup) # 一時の VPS を整える（apt、時刻、sshd、nftables。90 秒で戻す仕掛けを止めるまでが 1 つ）
	mon=$(sed -n 's/^PUB_mon=//p' "$HOME/aka-deploy/inventory.env")
	Li "cat > /tmp/loadgen-setup.sh && sudo bash /tmp/loadgen-setup.sh ${mon:?監視ノードの公開のアドレス}" < "$T/loadgen-setup.sh" || exit 1
	sleep 5
	L "sudo systemctl stop aka-nft-rollback.timer && sudo nft list ruleset | head -20 && echo 戻す仕掛けを止めた"
	;;
lg-keys) # 一時の VPS で AP 1,000 台の鍵と CSR を作り（鍵はそこに残す）、CSR を手元に集める
	python3 -I -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("s", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
for i in range(1, m.SUBS + 1):
    for a in m.ap_names(m.tname(i)): print(f"{m.tname(i)}-{a}")' "$T/scale.py" > "$WORK/run/ap-names.txt"
	Li "mkdir -p $RL/pki && cd $RL/pki && while read -r f; do [ -s \$f.key ] || openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout \$f.key -out \$f.csr -subj /CN=\$f < /dev/null 2> /dev/null; done && chmod 600 *.key && ls *.csr | wc -l" < "$WORK/run/ap-names.txt"
	L "cd $RL/pki && tar cf - *.csr" | tar xf - -C "$WORK/csr"
	echo "CSR $(ls "$WORK"/csr/*.csr | wc -l) 件"
	;;
aps) # AP 1,000 台を画面で登録する（まだないものだけ。40 件ずつ）
	sql "SELECT t.name, t.id, coalesce(string_agg(a.name, ',' ORDER BY a.name) FILTER (WHERE a.id IS NOT NULL), '') FROM tenants t JOIN tenant_radsec r ON r.tenant_id = t.id
		LEFT JOIN aps a ON a.tenant_id = t.id AND a.deleted_at IS NULL WHERE t.name ~ '^sc[0-9]{4}$' AND t.deleted_at IS NULL GROUP BY t.id, t.name ORDER BY t.name" > "$WORK/run/aps-state.tsv"
	rm -f "$WORK"/req/aps-[0-9][0-9][0-9]*.json
	python3 -I "$T/scale.py" aps "$WORK/run/aps-state.tsv" "$WORK/csr" "$WORK/req/aps-" 40
	t0=$(date +%s)
	for f in "$WORK"/req/aps-[0-9][0-9][0-9].json; do
		[ -e "$f" ] || break
		BULK "$f" > "${f%.json}.out.json"
		echo "$(basename "$f") $(date +%T) $(python3 -I "$T/scale.py" result "${f%.json}.out.json" | tr '\n' ' ')"
	done
	echo "AP の登録 $(($(date +%s) - t0)) 秒、登録済み $(sql "SELECT count(*) FROM aps a JOIN tenants t ON t.id = a.tenant_id WHERE t.name ~ '^sc[0-9]{4}$' AND a.deleted_at IS NULL")"
	;;
radsec-apply) # 19 テナントで「反映する」を求める（配置の後に AP を登録したので、AP の client ブロックをエッジに入れる。AP の追加では自動で求めない。OB1）
	state > "$WORK/run/state.tsv"
	python3 -I "$T/scale.py" apply "$WORK/run/state.tsv" "$WORK/req/apply.json"
	BULK "$WORK/req/apply.json" > "$WORK/req/apply.out.json"
	python3 -I "$T/scale.py" result "$WORK/req/apply.out.json"
	;;
certs) # サーバー CA と AP の証明書を画面から取り、一時の VPS に送って aps.json を作る
	certs_tsv > "$WORK/run/certs.tsv"
	sql "SELECT t.name, p.slot, p.edge_id, e.public_addr FROM placements p JOIN tenants t ON t.id = p.tenant_id JOIN edges e ON e.id = p.edge_id
		WHERE t.name ~ '^sc[0-9]{4}$' AND p.deleted_at IS NULL AND p.removed_at IS NULL ORDER BY t.name, p.slot" > "$WORK/run/placements.tsv"
	rm -f "$WORK"/req/certs-*.json
	python3 -I "$T/scale.py" certs "$WORK/run/certs.tsv" "$WORK/req/certs-" 60
	outs=()
	for f in "$WORK"/req/certs-[0-9][0-9][0-9].json; do
		BULK "$f" > "${f%.json}.out.json"
		outs+=("${f%.json}.out.json")
	done
	python3 -I "$T/scale.py" save-certs "${outs[@]}" "$WORK/pki" || exit 1
	python3 -I "$T/scale.py" apsjson "$WORK/run/certs.tsv" "$WORK/run/placements.tsv" "$RL/pki" > "$WORK/run/aps.json"
	(cd "$WORK/pki" && tar cf - ./*.pem) | Li "tar xf - -C $RL/pki && chmod 644 $RL/pki/*.pem"
	Li "cat > $RL/aps.json" < "$WORK/run/aps.json"
	echo "aps.json $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORK/run/aps.json") 台"
	;;
applied) # 19 テナントの配置が全部反映されるまで待つ（新しい配置は整合のループが反映する）
	for _ in $(seq 1 60); do
		r=$(sql "SELECT count(*) FILTER (WHERE p.applied_revision = r.revision AND p.apply_result = 'ok') || '/' || count(*) || '/' || count(*) FILTER (WHERE p.apply_result NOT IN ('ok', ''))
			FROM placements p JOIN tenant_radsec r USING (tenant_id) JOIN tenants t ON t.id = p.tenant_id WHERE t.name ~ '^sc[0-9]{4}$' AND p.deleted_at IS NULL AND p.removed_at IS NULL")
		echo "$(date +%T) 反映済み/配置/失敗 $r"
		[ "$(echo "$r" | cut -d/ -f1)" = "$(echo "$r" | cut -d/ -f2)" ] && break
		sleep 20
	done
	;;
lg-push) # scaleload と種を一時の VPS に送る
	Li "cat > $RL/scaleload && chmod 755 $RL/scaleload" < "$WORK/scaleload"
	Li "umask 077 && cat > $RL/seed.bin" < "$WORK/seed.bin"
	L "ls -l $RL/scaleload $RL/seed.bin"
	;;
serve) # [AP の数（省くと全部）]: 一時の VPS で scaleload を一時の service で動かす（メモリーの上限 1 GiB、FD 16384）
	n=${2:-0}
	L "cd $RL && python3 -I -c 'import json,sys; a=json.load(open(\"aps.json\")); n=int(sys.argv[1]); json.dump(a[:n] if n else a, open(\"aps-run.json\",\"w\"))' $n"
	out="out-$(date +%Y%m%d-%H%M%S)"
	echo "$out" > "$WORK/run/serve-out"
	L "sudo systemd-run --unit=aka-scaleload --uid=debian --gid=debian -p MemoryMax=1G -p LimitNOFILE=16384 -p WorkingDirectory=$RL \
		-p StandardOutput=append:$RL/$out.log -p StandardError=append:$RL/$out.log \
		$RL/scaleload serve -aps $RL/aps-run.json -seed $RL/seed.bin -out $RL/$out -listen 127.0.0.1:9900 -dial-rate 20"
	sleep 10
	lgctl /status | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print({k: d[k] for k in ("aps", "conns_up", "dial_fail", "lost")})'
	;;
ctl) # <パス> [POST]: 操作の口（例: ctl '/load?tps=50&label=p2' POST、ctl '/sessions?tenant=sc0001&n=20000&tps=50' POST、ctl /status）
	lgctl "${2:?パス}" "${3:-GET}" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print({k: d[k] for k in ("label", "rate", "conns_up", "lost", "inflight", "sessions", "building")})
for s in (d.get("summary") or [])[-6:]:
    print(" ", s["label"], s["seconds"], "Accept", s["counts"]["accept"], "失敗", s["failures"], "TPS", s["tps"], "p95", s["latency"]["p95"], "p99", s["latency"]["p99"], "acct", s["counts"]["acct_ok"], "/", s["counts"]["acct_sent"])'
	;;
stop) # [stop_sessions]: scaleload を止め（stop_sessions なら全セッションに Accounting-Stop を送ってから）、記録を手元に写す
	q=""
	[ "${2:-}" = stop_sessions ] && q="?stop_sessions=1&tps=100"
	lgctl "/stop$q" POST > /dev/null
	sleep 15
	out=$(cat "$WORK/run/serve-out")
	L "cd $RL && tar cf - $out $out.log" | tar xf - -C "$WORK/out"
	"$WORK/scaleload" report "$WORK/out/$out"
	;;
measure-start) # データ面で 10 秒ごとの測定を一時の service で始め、aka-vecgen の Valkey の遅れの記録（LATENCY）を一時的に 5 ms で入れる
	Ni data "sudo install -d -m 700 /var/tmp/aka-scale && sudo tee /var/tmp/aka-scale/measure.py > /dev/null" < "$T/measure.py"
	N data "pw=\$(sudo sed -n 's/^VALKEY_PASSWORD=//p' /opt/aka-vecgen/.env); docker exec aka-vecgen-valkey-1 valkey-cli -a \"\$pw\" --no-auth-warning CONFIG SET latency-monitor-threshold 5
		sudo systemd-run --unit=aka-scale-measure python3 -I /var/tmp/aka-scale/measure.py /var/tmp/aka-scale/data.jsonl && echo 始めた"
	;;
measure-stop) # 測定を止め、Valkey の遅れの記録を既定（0。測らない）に戻し、記録を手元に写す
	N data "sudo systemctl stop aka-scale-measure; pw=\$(sudo sed -n 's/^VALKEY_PASSWORD=//p' /opt/aka-vecgen/.env); docker exec aka-vecgen-valkey-1 valkey-cli -a \"\$pw\" --no-auth-warning CONFIG SET latency-monitor-threshold 0"
	N data "sudo cat /var/tmp/aka-scale/data.jsonl" > "$WORK/run/data-$(date +%Y%m%d-%H%M).jsonl"
	ls -l "$WORK"/run/data-*.jsonl | tail -1
	;;
ui-timing) # [回数]: 画面の応答の時間（⑤）。一覧・IMSI の検索・加入者の詳細・sc0001 のセッションの一覧・ダッシュボード
	n=${2:-20}
	t1=$(sql "SELECT id FROM tenants WHERE name = 'sc0001' AND deleted_at IS NULL")
	list=$(python3 -I -c 'import json,sys,base64; t=sys.argv[1]; print(base64.b64encode(json.dumps([
		{"k": "一覧", "p": "/subscribers?tenant=" + t}, {"k": "IMSI の検索", "p": "/subscribers?prefix=44010800001"},
		{"k": "加入者の詳細", "p": "/subscribers/440108000012345"}, {"k": "セッション", "p": "/sessions?tenant=" + t}, {"k": "ダッシュボード", "p": "/"}]).encode()).decode())' "$t1")
	f="$WORK/run/ui-timing-$(date +%Y%m%d-%H%M).json"
	PWT=1800 UI "$T/ui/timing.js" "$list" "$n" > "$f"
	python3 -I "$T/scale.py" timing "$f"
	;;
prom) # <始め> <終わり>（date -d が読める時刻）: Prometheus から試験の間の数を取り出す（30 秒ごと）
	s=$(date -d "${2:?始め}" +%s) e=$(date -d "${3:?終わり}" +%s)
	f="$WORK/run/prom-$(date -d "@$s" +%Y%m%d-%H%M).json"
	{
		echo "{"
		first=1
		while IFS='|' read -r k q; do
			[ $first = 1 ] || echo ","
			first=0
			printf '"%s": ' "$k"
			N mon "curl -s -G --data-urlencode 'query=$q' --data-urlencode start=$s --data-urlencode end=$e --data-urlencode step=30 http://10.82.0.1:9090/api/v1/query_range"
		done << 'Q'
cpu|1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[1m]))
mem_used|node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
auth_success|aka:auth_success:rate5m
auth_reject|aka:auth_reject_by_reason:rate5m
acct|sum by (event_id) (rate(aka_acct_log_events_total{event_id=~"ACCT_START|ACCT_INTERIM|ACCT_STOP"}[1m]))
vecgen|sum by (event_id) (rate(aka_vecgen_log_events_total{event_id=~"AV_.*"}[1m]))
overload|sum by (__name__) ({__name__=~"aka_(auth|acct)_log_events_total", event_id="RADIUS_OVERLOAD"})
probe|aka_probe_duration_seconds
alerts|ALERTS
Q
		echo "}"
	} > "$f"
	ls -l "$f"
	;;
scheduled) # ⑥ 毎日の処理と課金の締めの時間（DB の記録）
	sql "SELECT name, started_at, finished_at, round(extract(epoch FROM finished_at - started_at)::numeric, 1), status, left(detail, 120) FROM scheduled_runs WHERE started_at > now() - interval '2 days' ORDER BY started_at" | tee "$WORK/run/scheduled-$(date +%Y%m%d).tsv"
	;;
lg-clean) # 一時の VPS の鍵・種・記録を消す（記録は stop の段で写してから）。VPS とセキュリティグループはユーザーが消す
	L "sudo systemctl stop aka-scaleload 2> /dev/null; rm -rf $RL && echo 消した"
	;;
*)
	echo "段は README.md の表を参照" >&2
	exit 2
	;;
esac
