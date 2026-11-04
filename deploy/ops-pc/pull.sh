#!/bin/sh
# 各ノードの /srv/aka-pull を取りに行く（docs/deployment.md §11、確認事項 D13・D14）。検証機の crontab から docker exec で毎日動かす。
# ログと監査ログは 3 か月（概要 §13）、バックアップは 30 日持つ。各ノードの pull は rrsync -ro なので読むことしかできない。
set -u
st=0
# 取ったものは data/ の持ち主（検証機のユーザー）のものにし、本人だけが読める形にする（.env の写しなど秘密の値を含む）
own=$(stat -c %u:%g /data)
for n in $(cat /state/nodes.list); do
	mkdir -p "/data/$n" && chown "$own" "/data/$n" && chmod 700 "/data/$n"
	if rsync -a --chown="$own" --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= --timeout=300 -e "ssh -F /state/ssh_config" "aka-$n:./" "/data/$n/"; then
		echo "$(date -Is) $n ok"
	else
		echo "$(date -Is) $n 失敗" >&2
		st=1
	fi
done
find /data/*/logs -type f -mtime +92 -delete 2> /dev/null
find /data/*/backups -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2> /dev/null
date +%s > /data/last-pull
exit $st
