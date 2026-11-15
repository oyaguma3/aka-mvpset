#!/bin/bash
# 規模の試験の一時の VPS（aka-loadgen）を整える（確認事項 L6-8。段階 5 の T5-23 の aka-loadgen と同じ形）。root で 1 回動かす。
#   sudo bash loadgen-setup.sh <監視ノードの公開のアドレス>
# KAGOYA の Debian 13（ユーザー debian、sudo はパスワードなし）。セキュリティグループで監視ノードからの TCP 22 だけを許した状態で動かし、
# 整えた後、負荷の前にユーザーがセキュリティグループを外す（K1 と同じ。AP 1,000 本の接続を KAGOYA の接続の追跡に載せない）。
# WireGuard・監視・bootstrap はしない一時の機械。nftables は 90 秒で戻す仕掛けをつけて当てるので、新しい SSH で
#   sudo systemctl stop aka-nft-rollback.timer
# を動かす（drive.sh の lg-setup の段がする）。
set -euo pipefail
MON=${1:?監視ノードの公開のアドレス}
export DEBIAN_FRONTEND=noninteractive

echo "== apt（セキュリティの更新。新しい依存が要るもの（cloud-init など）は上げない）"
apt-get update -q
apt-get -y -q upgrade
apt-get -y -q install --no-install-recommends nftables systemd-timesyncd openssl python3 curl
timedatectl set-timezone Asia/Tokyo
timedatectl set-ntp true || true

echo "== sshd（鍵だけ、root は入れない、監視ノードを罰の対象から外す）"
cat > /etc/ssh/sshd_config.d/01-aka-loadgen.conf << EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
ClientAliveInterval 30
ClientAliveCountMax 4
PerSourcePenaltyExemptList $MON
EOF
sshd -t
systemctl reload ssh

echo "== 使わない待ち受けを止める（avahi・cups）"
systemctl disable --now avahi-daemon.socket avahi-daemon.service cups.service cups-browsed.service 2> /dev/null || true
systemctl mask avahi-daemon.service 2> /dev/null || true

echo "== nftables（入力は既定で捨て、lo・確立済み・監視ノードからの 22・ICMP の要るものだけ。外へは通す）"
[ -e /etc/nftables.conf.orig ] || cp /etc/nftables.conf /etc/nftables.conf.orig
cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
flush ruleset
table inet loadgen {
	chain input {
		type filter hook input priority filter; policy drop;
		iif lo accept
		ct state established,related accept
		ct state invalid drop
		ip saddr $MON tcp dport 22 accept comment "SSH（監視ノードを踏み台に）"
		meta l4proto icmp icmp type { echo-request, destination-unreachable, time-exceeded } limit rate 10/second accept
		meta l4proto ipv6-icmp accept
	}
	chain forward {
		type filter hook forward priority filter; policy drop;
	}
}
EOF
nft -c -f /etc/nftables.conf
systemctl stop aka-nft-rollback.timer 2> /dev/null || true
systemd-run --unit=aka-nft-rollback --on-active=90 /usr/sbin/nft flush ruleset
nft -f /etc/nftables.conf
systemctl enable nftables
echo "当てた。90 秒の内に新しい SSH で sudo systemctl stop aka-nft-rollback.timer（しなければ規則を消す）"

echo "== 状態"
uname -r
[ -e /var/run/reboot-required ] && echo "再起動が要る（カーネルが上がった）。戻す仕掛けを止めてから sudo reboot" || true
ss -ltnp | sed -n '1,10p'
