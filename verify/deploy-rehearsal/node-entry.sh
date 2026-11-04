#!/bin/sh
# リハーサルのノードの起動: sshd を動かして待つ（VPS の代わり）
ssh-keygen -A > /dev/null
mkdir -p /run/sshd
/usr/sbin/sshd -D -e &
trap 'exit 0' TERM INT
while :; do sleep 3600 & wait $!; done
