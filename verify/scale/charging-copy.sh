#!/bin/bash
# 課金の締めを、本番から切り離した写しで測る（段階 6-3 の A 案。結果は results/charging-close.txt）。
# 締めは「今の月より前の月」だけを選ぶので、今の月のデータは翌月 1 日まで締められない（試し用の口は製品に入れない）。
# そこで本番の DB の写しを一時の環境に戻し、事実・利用・RadSec の行を 1 か月前にずらして先月として締める。
# 管理面のノードの上で、作業ユーザー（aka）が動かす。置き方: ssh … aka-mgmt 'cat > /var/tmp/aka-chg.sh && chmod 700 /var/tmp/aka-chg.sh' < charging-copy.sh
#   setup <メール>   本番の DB の写し（pg_dump）、一時の KEK、ダミーの証明書、専用のネットワーク、一時の postgres に戻す。
#                    <メール> はシステム管理者のアカウント（一時の aka-ossbss の開発用の利用者にする）
#   shift            写しの事実・利用・RadSec の行を 1 か月前にずらし、先月を全部の日で取り込んだ扱いにする
#                    （データが今の月の中にだけあるとき用。前の月にもあれば、ずらした先で重なる）
#   start            一時の aka-ossbss を起動する（開発用の設定、aka-provisioner に届かない宛先）
#   key              標準入力の PGP 公開鍵（armored）を POST /charging/key で登録する
#   close            POST /charging/close（今すぐ締める）
#   wait             締めが終わるまで待つ
#   report           記録（scheduled_runs・charging_periods・charging_files・件数）
#   get <ID>         ファイルを標準出力に出す（手元で verify/charging/verify-file.py にかける）
#   stats-start | stats-stop   2 つのコンテナとホストのメモリー・CPU を続けて記録する（docker stats は 1 回約 2 秒）
#   logs [行数]      一時の aka-ossbss のログ
#   clean            一時のコンテナ・ボリューム・ネットワーク・写し・KEK を消す
# 本番から切り離す: ネットワークは --internal（外にも本番のコンテナにも届かない）、aka-provisioner の宛先は届かない
# アドレスでダミーの証明書（整合のループがエッジに反映を送らない。利用の読み直しは失敗し、取り込み済みの利用で締める）、
# KEK は一時のもの、Cloudflare のトンネルはなし、ログは Fluent Bit に送らない（本番のアプリの数に入らない）。
# HTTP は node-exporter のイメージの busybox wget を一時の aka-ossbss の名前空間で動かして送る（開発用の設定はループバックで
# だけ待ち受けるため）。busybox の wget は 303 の後も POST をやり直す（404 になるが害はない）。
set -euo pipefail
W=/var/tmp/aka-chg NET=aka-chg PG=aka-chg-pg OS=aka-chg-ossbss VOL=aka-chg-pgdata
IMG=aka-ossbss-aka-ossbss WGET=prom/node-exporter:v1.12.1 URL=http://127.0.0.1:8446
psqlc() { docker exec -i $PG psql -U ossbss -d ossbss -At -F '|' -v ON_ERROR_STOP=1 "$@"; }
http() { docker run --rm -i --user 0:0 --network container:$OS --entrypoint wget $WGET -T 60 "$@"; }
ms() { echo $((($(date +%s%N) - $1) / 1000000)); }
cmd=${1:?段を指定する}
shift
case $cmd in
setup)
	email=${1:?管理者のメール}
	[ ! -e $W ] || { echo "$W がある（clean してから）" >&2; exit 1; }
	umask 077
	mkdir -p $W/certs
	t=$(date +%s%N)
	(cd /opt/aka-ossbss && docker compose exec -T postgres pg_dump -U ossbss -d ossbss -Fc) > $W/ossbss.dump
	echo "pg_dump: $(stat -c %s $W/ossbss.dump) バイト、$(ms $t) ms"
	docker run --rm --network none $IMG gen-kek > $W/kek
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=aka-chg-dummy \
		-keyout $W/certs/key.pem -out $W/certs/cert.pem 2> /dev/null
	cat $W/certs/cert.pem $W/certs/key.pem > $W/certs/provisioner-client.pem
	mv $W/certs/cert.pem $W/certs/provisioner-server.pem
	rm $W/certs/key.pem
	pw=$(openssl rand -hex 24)
	printf 'POSTGRES_DB=ossbss\nPOSTGRES_USER=ossbss\nPOSTGRES_PASSWORD=%s\n' "$pw" > $W/pg.env
	cat > $W/os.env <<-EOF
		TZ=Asia/Tokyo
		OSSBSS_ADDR=127.0.0.1:8446
		OSSBSS_DB_ADDR=postgres:5432
		OSSBSS_DB_NAME=ossbss
		OSSBSS_DB_USER=ossbss
		OSSBSS_DB_PASSWORD=$pw
		OSSBSS_LOG_LEVEL=info
		OSSBSS_DEV_USER_EMAIL=$email
		OSSBSS_INITIAL_ADMIN_EMAIL=$email
		OSSBSS_PROVISIONER_URL=https://127.0.0.1:1/admin/v2
		OSSBSS_PROVISIONER_CLIENT_CERT=/certs/provisioner-client.pem
		OSSBSS_PROVISIONER_SERVER_CERT=/certs/provisioner-server.pem
		OSSBSS_AUDIT_DIR=/data/audit
		OSSBSS_KEK_FILE=/run/secrets/kek
	EOF
	sudo chown -R 65532:65532 $W/kek $W/certs
	docker network create --internal $NET > /dev/null
	docker run -d --name $PG --network $NET --network-alias postgres --env-file $W/pg.env -v $VOL:/var/lib/postgresql postgres:18.6 > /dev/null
	# 初期化の間の一時のサーバーはソケットだけで待ち受けるので、TCP で確かめる
	until docker exec $PG pg_isready -h 127.0.0.1 -U ossbss -d ossbss -q; do sleep 1; done
	t=$(date +%s%N)
	docker exec -i $PG pg_restore -U ossbss -d ossbss --exit-on-error < $W/ossbss.dump
	echo "pg_restore: $(ms $t) ms"
	psqlc -c "SELECT pg_size_pretty(pg_database_size('ossbss'))"
	;;
shift)
	this=$(date +%Y-%m-01)
	prev=$(date -d "$this -1 month" +%Y-%m-01)
	last=$(date -d "$this -1 day" +%F)
	echo "ずらす先: $prev〜$last"
	psqlc <<-SQL
		BEGIN;
		CREATE TABLE IF NOT EXISTS usage_daily_$(date -d "$prev" +%Y%m) PARTITION OF usage_daily FOR VALUES FROM ('$prev') TO ('$this');
		UPDATE usage_daily SET date = (date - interval '1 month')::date;
		UPDATE charging_events SET time = time - interval '1 month';
		UPDATE aps SET created_at = created_at - interval '1 month', deleted_at = deleted_at - interval '1 month';
		UPDATE brought_cas SET created_at = created_at - interval '1 month', deleted_at = deleted_at - interval '1 month';
		UPDATE placements SET created_at = created_at - interval '1 month', deleted_at = deleted_at - interval '1 month';
		-- 本番では毎日取り込むので、先月は全部の日を取り込めたものとして記録する（なければ usage_complete が false になる）
		INSERT INTO usage_import_days (date, attempted_at, imported_at, last_error)
		  SELECT d::date, now(), now(), '' FROM generate_series('$prev'::date, '$last'::date, '1 day') d ON CONFLICT (date) DO NOTHING;
		COMMIT;
		SELECT 'events', count(*), min(time), max(time) FROM charging_events;
		SELECT 'usage', count(*), min(date), max(date) FROM usage_daily;
		SELECT 'periods', count(*) FROM charging_periods;
		SELECT 'keys', count(*) FROM charging_pgp_keys;
	SQL
	;;
start)
	docker run -d --name $OS --network $NET --user 65532:65532 --env-file $W/os.env \
		-v $W/kek:/run/secrets/kek:ro -v $W/certs:/certs:ro --mount type=tmpfs,destination=/data,tmpfs-mode=1777 \
		--stop-timeout 40 $IMG serve > /dev/null
	# distroless にはシェルがないので --health-cmd（文字列の形はシェルを使う）は使わず、/healthz を直接確かめる
	for _ in $(seq 60); do
		http -q -O - $URL/healthz < /dev/null > /dev/null 2>&1 && break
		sleep 2
	done
	echo "$(docker inspect -f '{{.State.Status}}' $OS) healthz=$(http -q -O - $URL/healthz < /dev/null 2>&1 | head -c 80)"
	;;
key)
	cat > $W/key.form.tmp
	python3 -I -c 'import sys, urllib.parse; sys.stdout.write("armored=" + urllib.parse.quote(open(sys.argv[1]).read(), safe=""))' $W/key.form.tmp > $W/key.form
	rm $W/key.form.tmp
	http -S -O - --post-data "$(cat $W/key.form)" $URL/charging/key < /dev/null 2>&1 | grep -E 'HTTP/|role="alert"' | head -5
	psqlc -c "SELECT id, fingerprint, algorithm, expires_at, created_at FROM charging_pgp_keys ORDER BY id"
	;;
close)
	http -S -O /dev/null --post-data '' $URL/charging/close 2>&1 | grep -E 'HTTP/' | head -3
	psqlc -c "SELECT id, name, started_at FROM scheduled_runs ORDER BY id DESC LIMIT 1"
	;;
wait)
	until [ -n "$(psqlc -c "SELECT finished_at FROM scheduled_runs WHERE name = 'charging-close' ORDER BY id DESC LIMIT 1")" ]; do sleep 2; done
	;;
report)
	psqlc <<-'SQL'
		SELECT 'run', id, started_at, finished_at, round(extract(epoch FROM finished_at - started_at)::numeric, 1), status, detail FROM scheduled_runs WHERE name = 'charging-close' ORDER BY id DESC LIMIT 1;
		SELECT 'period', period, sequence, state, event_count, line_count, tenant_count, adj_count, missing_days, closed_at FROM charging_periods ORDER BY period;
		SELECT 'file', id, period, version, file_name, size, created_at, event_count, line_count, tenant_count, adj_count FROM charging_files ORDER BY id;
		SELECT 'lines', count(*), sum(registered_days), sum(auth_ok), count(*) FILTER (WHERE auth_ok > 0), count(DISTINCT tenant_id) FROM charging_lines;
		SELECT 'tenants', count(*), sum(lines_end), sum(aps_end), sum(placements_end), count(*) FILTER (WHERE deleted_at IS NOT NULL) FROM charging_tenants;
		SELECT 'size', pg_size_pretty(pg_database_size('ossbss'));
	SQL
	;;
get)
	http -q -O - $URL/charging/files/"${1:?ID}"
	;;
stats-start)
	nohup bash -c 'while :; do printf "%s|" "$(date +%T.%N | cut -c1-12)"; docker stats --no-stream --format "{{.Name}}={{.MemUsage}}={{.CPUPerc}}" '"$PG $OS"' | tr "\n" "|"; free -m | awk "/Mem/{printf \"used=%s|avail=%s|\", \$3, \$7}"; cut -d" " -f1-3 /proc/loadavg; done' > $W/stats.log 2>&1 < /dev/null &
	echo $! > $W/stats.pid
	;;
stats-stop)
	kill "$(cat $W/stats.pid)" && rm $W/stats.pid
	cat $W/stats.log
	;;
logs)
	docker logs $OS 2>&1 | tail -n "${1:-50}"
	;;
clean)
	[ -e $W/stats.pid ] && kill "$(cat $W/stats.pid)" 2> /dev/null || true
	docker rm -f $OS $PG 2>&1 | tail -2 || true
	docker volume rm $VOL 2>&1 || true
	docker network rm $NET 2>&1 || true
	sudo rm -rf $W
	docker ps -a --format '{{.Names}}' | grep -c aka-chg || true
	;;
*)
	echo "段: setup shift start key close wait report get stats-start stats-stop logs clean" >&2
	exit 2
	;;
esac
