#!/usr/bin/env bash
# 毎日 2:30 に、このノードのバックアップを取り、ログと監査ログの圧縮したものと一緒に /srv/aka-pull に置く（docs/deployment.md §10、
# 確認事項 D13・S5-14）。ops-pc が pull で取りに行く。ノードには 3 日分だけ残す。KEK と Tunnel のトークンは入れない（別に保管する）。
set -uo pipefail
role=$(cat /etc/aka/role)
day=$(date +%Y%m%d)
base=/srv/aka-pull
out=$base/backups/$day
state=/var/lib/aka-textfile/backup.state
umask 027
mkdir -p "$out"
touch "$state"
ok=() ng=()
run() { # <項目> <コマンド ...>
	local item=$1
	shift
	if "$@"; then ok+=("$item"); else ng+=("$item"); echo "失敗: $item" >&2; fi
}
files() { # <tar の名前> <基のディレクトリ> <パス ...>（ないパスは飛ばす）
	local name=$1 dir=$2 p have=()
	shift 2
	for p in "$@"; do [ -e "$dir/$p" ] && have+=("$p"); done
	[ ${#have[@]} -gt 0 ] && tar -C "$dir" -czf "$out/$name.tgz" "${have[@]}"
}
valkey() { # <compose のディレクトリ> <スクリプト> <出力>
	(cd "$1" && "$2" "$3")
}

case $role in
data)
	run aka-radius-valkey valkey /opt/aka-radius/deployments ../scripts/backup-valkey.sh "$out/aka-radius-valkey.rdb"
	run aka-radius-files files aka-radius-files /opt/aka-radius/deployments .env sources certs/admin secrets/admin-clients
	run aka-vecgen-valkey valkey /opt/aka-vecgen scripts/backup-valkey.sh "$out/aka-vecgen-valkey.rdb"
	run aka-vecgen-files files aka-vecgen-files /opt/aka-vecgen .env secrets/admin-clients
	;;
mgmt)
	run aka-provisioner-valkey valkey /opt/aka-provisioner scripts/backup-valkey.sh "$out/aka-provisioner-valkey.rdb"
	run aka-provisioner-files files aka-provisioner-files /opt/aka-provisioner .env downstreams secrets/admin-clients
	run aka-ossbss-db sh -c "cd /opt/aka-ossbss && scripts/backup-db.sh '$out/aka-ossbss.dump'"
	run aka-ossbss-files files aka-ossbss-files /opt/aka-ossbss .env certs
	ca_db() {
		(cd /opt/radsec-ca &&
			docker compose exec -T radsec-ca /radsec-ca backup -out "/data/backup-$day.db" &&
			docker compose cp "radsec-ca:/data/backup-$day.db" "$out/radsec-ca.db")
		local r=$?
		# distroless なのでコンテナの中では消せない。ボリュームを別のコンテナで開いて消す
		docker run --rm -v radsec-ca_ca-data:/data busybox:1.37.0 sh -c 'rm -f /data/backup-*.db' || true
		return $r
	}
	run radsec-ca-db ca_db
	run radsec-ca-files files radsec-ca-files /opt/radsec-ca .env secrets/admin-clients
	;;
edge)
	edge_data() {
		# 止めている間も、テナントのコンテナと AP の接続は続く（管理API と整合のループだけが止まる）
		(cd /opt/radsec-edge && docker compose stop radsec-edge) || return 1
		tar -C /var/lib/radsec-edge -czf "$out/radsec-edge-data.tgz" data
		local r=$?
		(cd /opt/radsec-edge && docker compose start radsec-edge) || r=1
		return $r
	}
	run radsec-edge-data edge_data
	run radsec-edge-files files radsec-edge-files /opt/radsec-edge .env secrets/admin-clients
	;;
mon)
	run aka-monitor-files files aka-monitor-files /opt/aka-monitor .env prometheus alertmanager blackbox grafana compose.yaml
	;;
esac

# ログと監査ログ（圧縮した前の日までのもの）を写す
while read -r name path; do
	[ -n "${name:-}" ] || continue
	[ -d "$path" ] || continue
	run "logs-$name" rsync -a --delete --include='*.gz' --exclude='*' "$path/" "$base/logs/$name/"
done < /etc/aka/export.list

chgrp -R pull "$base/backups" "$base/logs"
chmod -R g+rX,o-rwx "$base/backups" "$base/logs"
# ノードには 3 日分だけ
ls -1d "$base"/backups/2* 2> /dev/null | sort | head -n -3 | xargs -r rm -rf

now=$(date +%s)
for i in "${ok[@]}"; do
	grep -v "^$i " "$state" > "$state.new"
	echo "$i $now" >> "$state.new"
	mv "$state.new" "$state"
done
{
	echo "# HELP aka_backup_last_success_seconds 項目ごとの最後に成功した時刻（UNIX 時刻）"
	echo "# TYPE aka_backup_last_success_seconds gauge"
	awk '{printf "aka_backup_last_success_seconds{item=\"%s\"} %s\n", $1, $2}' "$state"
	echo "# HELP aka_backup_last_run_failed 最後の実行で失敗した項目の数"
	echo "# TYPE aka_backup_last_run_failed gauge"
	echo "aka_backup_last_run_failed ${#ng[@]}"
} > /var/lib/aka-textfile/.backup.prom
chmod 644 /var/lib/aka-textfile/.backup.prom
mv /var/lib/aka-textfile/.backup.prom /var/lib/aka-textfile/backup.prom
echo "成功 ${#ok[@]}: ${ok[*]}"
[ ${#ng[@]} -eq 0 ] || { echo "失敗 ${#ng[@]}: ${ng[*]}" >&2; exit 1; }
