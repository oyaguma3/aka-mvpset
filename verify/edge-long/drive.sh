#!/bin/bash
# 長い時間の試験（概要 §16.4、S4-11）の手元の台本。  WORK=<手元の作業ディレクトリ> ./drive.sh <段> [引数]
# 段: prepare | inotify <値> | start <テナント数> [記録の間隔の秒] | status | fetch | report [始めの時間] | restart | stop | teardown
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
. "$T/refs.env"
: "${WORK:?}"
H=simwifi2
REMOTE='~/aka-work/edge-long'
phase=${1:?}
shift
case $phase in
prepare)
	set -e
	B=$WORK/build
	rm -rf "${B:?}"
	mkdir -p "$B"
	git -C ~/projects/radsec-edge archive "$EDGE_REF" | tar x -C "$B"
	docker build -q --build-arg VERSION="${EDGE_REF:0:7}" -t radsec-edge:long "$B"
	docker image inspect radsec-edge/radsecproxy:1.11.4-pc1 > /dev/null 2>&1 || docker build -q -t radsec-edge/radsecproxy:1.11.4-pc1 "$B/images/radsecproxy"
	docker pull -q fluent/fluent-bit:4.2.8 > /dev/null
	docker pull -q docker:29.9.2-dind > /dev/null
	docker pull -q python:3.13.9-slim > /dev/null
	ssh $H "mkdir -p $REMOTE/tools $REMOTE/edge"
	git -C ~/projects/radsec-edge archive "$EDGE_REF" | ssh $H "tar x -C $REMOTE/edge"
	docker save radsec-edge:long radsec-edge/radsecproxy:1.11.4-pc1 fluent/fluent-bit:4.2.8 | gzip -1 | ssh $H "gunzip > $REMOTE/edge-images.tar"
	docker save docker:29.9.2-dind python:3.13.9-slim | gzip -1 | ssh $H 'gunzip | docker load' | tail -2
	"$0" tools
	;;
tools)
	(cd "$T" && tar cf - run.sh long.py upstream.py ap.py measure.py sample.sh report.py) | ssh $H "tar xf - -C $REMOTE/tools"
	;;
start)
	ssh $H "cd $REMOTE/tools && nohup bash run.sh start $* > ../start.log 2>&1 < /dev/null &"
	;;
status)
	ssh $H "cd $REMOTE; tail -3 start.log 2> /dev/null; tail -1 setup.log 2> /dev/null; wc -l run/samples.jsonl 2> /dev/null; cat run/ap-status.json run/run-status.json run/upstream-status.json 2> /dev/null; echo; tail -2 run/events.jsonl 2> /dev/null | cut -c1-200; docker exec edge-long docker ps -q --filter label=radsec-edge.tenant | wc -l"
	;;
fetch)
	ssh $H "cd $REMOTE/run && tar cf - samples.jsonl events.jsonl restart.txt 2> /dev/null; true" | tar xf - -C "$WORK"
	ssh $H "cd $REMOTE && cat setup.log | tail -3" > "$WORK/setup-tail.txt"
	;;
report)
	"$0" fetch
	python3 -I "$T/report.py" "$WORK/samples.jsonl" "$@"
	;;
restart)
	ssh $H "cd $REMOTE/tools && nohup bash run.sh restart > ../restart.log 2>&1 < /dev/null &"
	;;
stop) ssh $H "cd $REMOTE/tools && bash run.sh stop" ;;
inotify) # <値>: fs.inotify.max_user_instances を変える（再起動すると既定に戻る。運用ガイド 10.1 の値は 1024。既定は 128）。
	# sudo のパスワードは環境変数 SUDO_PW で渡す（公開のリポジトリに書かない）
	printf '%s\n' "${SUDO_PW:?}" | ssh $H "sudo -S -p '' sysctl -w fs.inotify.max_user_instances=$1"
	;;
teardown)
	ssh $H "cd $REMOTE/tools && bash run.sh teardown"
	"$0" inotify 128
	;;
*)
	echo "unknown: $phase" >&2
	exit 2
	;;
esac
