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
	# 見張り（確認事項 T5-16）: 監視ノードとの最後のハンドシェイクが 3 分より古ければ wg-ops を張り直す。張り直すと送信元の
	# ポートが変わり、手元の回線のルーターの NAT の対応も新しくなる（2026-11-11 に返事がないまま止まり、作り直しで戻った）。
	up=$(date +%s)
	while :; do
		sleep 60 &
		wait $!
		now=$(date +%s)
		hs=$(wg show wg-ops latest-handshakes 2> /dev/null | awk '{print $2; exit}')
		[ -n "$hs" ] || hs=0
		last=$hs
		[ "$last" = 0 ] && last=$up
		if [ $((now - last)) -gt 180 ]; then
			echo "$(date -Is) wg-ops: 最後のハンドシェイクから $((now - last)) 秒。張り直す" >&2
			wg-quick down /state/wg-ops.conf > /dev/null 2>&1 || true
			wg-quick up /state/wg-ops.conf > /dev/null 2>&1 || echo "$(date -Is) wg-ops: 張り直しに失敗" >&2
			up=$(date +%s)
		fi
	done
else
	echo "wg-ops の設定がまだない（deploy/bin/render の ops-pc/wg-ops.conf を state/ に置いて作り直す）" >&2
	trap 'exit 0' TERM INT
fi
while :; do sleep 3600 & wait $!; done
