#!/bin/sh
# ops-pc の起動（docs/deployment.md §11）。鍵がなければ作って公開鍵を出す。設定がそろっていれば wg-ops を上げる。
set -eu
umask 077
[ -s /state/wg-ops.key ] || wg genkey > /state/wg-ops.key
[ -s /state/pull_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C ops-pc-pull -f /state/pull_ed25519
echo "WGOPS_PUB_pc=$(wg pubkey < /state/wg-ops.key)"
echo "PULL_SSH_KEY=\"$(cat /state/pull_ed25519.pub)\""
if [ -s /state/wg-ops.conf ] && ! grep -q '^PublicKey = <' /state/wg-ops.conf; then
	wg-quick up /state/wg-ops.conf
	trap 'wg-quick down /state/wg-ops.conf; exit 0' TERM INT
else
	echo "wg-ops の設定がまだない（deploy/bin/render の ops-pc/wg-ops.conf を state/ に置いて作り直す）" >&2
	trap 'exit 0' TERM INT
fi
while :; do sleep 3600 & wait $!; done
