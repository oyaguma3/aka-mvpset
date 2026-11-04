#!/usr/bin/env bash
# 1 分ごとに、node_exporter の textfile collector に数値を書く（docs/deployment.md §9.2、確認事項 D12）。
# コンテナの状態と healthcheck、dockerd と containerd の RSS、WireGuard のハンドシェイクの経過。
set -uo pipefail
dir=${AKA_TEXTFILE_DIR:-/var/lib/aka-textfile}
tmp=$(mktemp "$dir/.aka.XXXXXX")
trap 'rm -f "$tmp"' EXIT
now=$(date +%s)
{
	echo "# HELP aka_docker_up Docker Engine に届くか"
	echo "# TYPE aka_docker_up gauge"
	if ids=$(timeout 20 docker ps -aq 2> /dev/null); then
		echo "aka_docker_up 1"
		echo "# HELP aka_container_running 再起動の方針のあるコンテナが動いているか（捨てるコンテナは数えない）"
		echo "# TYPE aka_container_running gauge"
		echo "# HELP aka_container_healthy healthcheck が healthy か（healthcheck のないものは出さない）"
		echo "# TYPE aka_container_healthy gauge"
		if [ -n "$ids" ]; then
			# shellcheck disable=SC2086
			timeout 30 docker inspect --format '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.HostConfig.RestartPolicy.Name}}' $ids 2> /dev/null |
				while read -r name state health policy; do
					[ "$policy" = no ] && continue
					name=${name#/}
					r=0
					[ "$state" = running ] && r=1
					echo "aka_container_running{container=\"$name\"} $r"
					case $health in
					healthy) echo "aka_container_healthy{container=\"$name\"} 1" ;;
					none) ;;
					*) echo "aka_container_healthy{container=\"$name\"} 0" ;;
					esac
				done
		fi
	else
		echo "aka_docker_up 0"
	fi
	echo "# HELP aka_process_rss_bytes 常駐のメモリー（dockerd と containerd。決定事項 28）"
	echo "# TYPE aka_process_rss_bytes gauge"
	for p in dockerd containerd; do
		pid=$(pidof -s "$p" 2> /dev/null) || continue
		kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2> /dev/null) || continue
		[ -n "$kb" ] && echo "aka_process_rss_bytes{process=\"$p\"} $((kb * 1024))"
	done
	echo "# HELP aka_wg_handshake_age_seconds 最後のハンドシェイクからの秒数（一度もなければ -1。180 秒を超えたら異常。概要 §14）"
	echo "# TYPE aka_wg_handshake_age_seconds gauge"
	wg show all dump 2> /dev/null | awk -v now="$now" 'NF == 9 {
		age = ($6 == 0) ? -1 : now - $6
		printf "aka_wg_handshake_age_seconds{interface=\"%s\",peer=\"%s\"} %d\n", $1, $5, age
	}'
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$dir/aka.prom"
trap - EXIT
