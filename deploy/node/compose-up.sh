#!/usr/bin/env bash
# 起動のときに、このノードに置いたスタックを docker compose up -d --no-build で起こす（aka-compose-up.service。docs/deployment.md §8）。
# docker compose kill -s HUP（設定の読み直し）を受けたコンテナには Docker が「手で止めた」の印を付け、unless-stopped でも
# 起動のときに起こし直さない（確認事項 T5-15）。動いているコンテナには何もしない。対象は /etc/aka/compose-stacks（ディレクトリ [サービス ...]）。
set -uo pipefail
st=0
while read -r dir services; do
	[ -n "${dir:-}" ] || continue
	case $dir in \#*) continue ;; esac
	if [ ! -e "$dir/compose.yaml" ] && [ ! -e "$dir/docker-compose.yml" ]; then
		echo "$dir: compose のファイルがない（まだ置いていない）。飛ばす"
		continue
	fi
	# shellcheck disable=SC2086
	out=$(cd "$dir" && docker compose up -d --no-build $services 2>&1)
	rc=$?
	# 起こしたコンテナだけを出す（動いていたものの行は省く）
	printf '%s\n' "$out" | grep -E 'Started|Created|Recreated|rror' || true
	if [ $rc = 0 ]; then
		echo "$dir: 済み${services:+（$services）}"
	else
		echo "$dir: 失敗" >&2
		st=1
	fi
done < /etc/aka/compose-stacks
exit $st
