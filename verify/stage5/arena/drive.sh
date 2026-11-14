#!/bin/bash
# radsecproxy のメモリーの実験（確認事項 T5-20）の手元の台本。検証機の 2 台目（simwifi2）に送って動かし、結果を手元でまとめる。
#   WORK=<手元の作業ディレクトリ> ./drive.sh push        イメージと台本を送る
#   WORK=... ./drive.sh run <段>                         検証機で lab.sh <段>（setup・up・ap・measure・status・down）
#   WORK=... ./drive.sh report                           記録を写して report.py でまとめる
#   WORK=... ./drive.sh clean                            止めて、作業ディレクトリと実験のイメージを消す
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
: "${WORK:?}"
C=simwifi2
R=aka-work/arena
IMG=radsec-edge/radsecproxy:1.11.4-pc1
PY=python:3.13.9-slim
mkdir -p "$WORK"
case ${1:-} in
push)
	set -e
	docker save "$IMG" | gzip -1 | ssh $C 'gunzip | docker load' | tail -1
	ssh $C "docker pull -q $PY && mkdir -p $R && chmod 700 $R" < /dev/null
	scp -q "$T/lab.sh" "$T/measure.py" "$T/../load-ap.py" "$T/../../edge-long/upstream.py" "$C:$R/"
	ssh $C "chmod 700 $R/lab.sh && ls $R" < /dev/null
	;;
run)
	ssh $C "cd $R && ./lab.sh $2" < /dev/null
	;;
report)
	scp -q "$C:$R/samples.jsonl" "$C:$R/ids.txt" "$WORK/"
	scp -q "$C:$R/ap-status.json" "$WORK/" 2> /dev/null
	python3 -I "$T/report.py" "$WORK/samples.jsonl" "$WORK/ap-status.json"
	;;
clean)
	ssh $C "cd $R && ./lab.sh down" < /dev/null
	ssh $C "rm -rf ./$R && docker image rm $IMG $PY > /dev/null && ls aka-work" < /dev/null
	;;
*) echo "使い方は先頭の説明を見る" >&2; exit 2 ;;
esac
