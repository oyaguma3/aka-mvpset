#!/usr/bin/env bash
# 最初の導入（docs/deployment.md §3）。作ったばかりの VPS で root として 1 回だけ動かす。KAGOYA の Debian 13 は
# ユーザー debian（sudo はパスワードなし）で入る作り（root で入ろうとすると案内の文が返る）。
#   ssh -i <KAGOYA の鍵> debian@<公開のアドレス> "sudo bash -s -- <ノード> '<作業ユーザーの公開鍵>'" < deploy/host/bootstrap.sh
# ノードは data・mgmt・mon・edge-NN。やること: 時刻とホスト名、パッケージ、作業ユーザー aka と pull、
# WireGuard の鍵（秘密鍵はこのノードから出さない。公開鍵を最後に出す）、SSH を鍵だけ・root 不可にする（D4・D5・D7）。
set -euo pipefail
NOSD=${AKA_NO_SYSTEMD:-0} # 1 のときはリハーサルのコンテナ（systemd がない）

node=${1:?ノード（data・mgmt・mon・edge-NN）}
admin_key=${2:?作業ユーザーの公開鍵の 1 行}
case $node in data | mgmt | mon | edge-[0-9][0-9]) ;; *) echo "ノードの名前が違う: $node" >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "root で動かす" >&2; exit 2; }
. /etc/os-release
[ "${VERSION_ID:-}" = 13 ] || { echo "Debian 13 ではない: ${PRETTY_NAME:-?}" >&2; exit 2; }
case $admin_key in ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-*) ;; *) echo "公開鍵の形でない" >&2; exit 2 ;; esac

echo "== 時刻とホスト名"
if [ "$NOSD" = 1 ]; then
	hostname "aka-$node" 2> /dev/null || true
	ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
else
	hostnamectl set-hostname "aka-$node"
	timedatectl set-timezone Asia/Tokyo
fi

echo "== パッケージ"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get full-upgrade -y -q
apt-get install -y -q --no-install-recommends \
	sudo wireguard-tools nftables rsync acl unattended-upgrades ca-certificates curl gnupg jq openssl \
	logrotate python3 netcat-openbsd systemd-timesyncd
if [ "$NOSD" != 1 ]; then
	systemctl enable --now systemd-timesyncd
	# 入れた直後は timedated が timesyncd を知らず「NTP not supported」を返すことがある（KAGOYA の Debian 13 で起きた）。timesyncd は有効にしてある
	timedatectl set-ntp true 2> /dev/null || true
fi

echo "== 自動の更新（セキュリティだけ。自動の再起動はしない）"
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/51aka-unattended << 'EOF'
// aka-mvpset（docs/deployment.md §3）。docker-ce は版を固定しているので上がらない（apt-mark hold）。
Unattended-Upgrade::Automatic-Reboot "false";
EOF

echo "== 作業ユーザー aka と取得のユーザー pull"
id aka > /dev/null 2>&1 || useradd -m -s /bin/bash aka
install -d -o aka -g aka -m 700 /home/aka/.ssh
printf '%s\n' "$admin_key" > /home/aka/.ssh/authorized_keys
chown aka:aka /home/aka/.ssh/authorized_keys
chmod 600 /home/aka/.ssh/authorized_keys
printf 'aka ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/aka
chmod 440 /etc/sudoers.d/aka
visudo -cq
getent group pull > /dev/null || groupadd --system pull
id pull > /dev/null 2>&1 || useradd --system -g pull -d /var/lib/aka-pull -m -s /bin/sh pull
install -d -o pull -g pull -m 700 /var/lib/aka-pull/.ssh
install -d -o root -g pull -m 750 /srv/aka-pull /srv/aka-pull/logs /srv/aka-pull/backups
install -d -m 755 /etc/aka /var/lib/aka-textfile

echo "== WireGuard の鍵"
ifaces="wg-svc wg-ops"
[ "$node" = mon ] && ifaces="wg-ops"
install -d -m 700 /etc/wireguard
for i in $ifaces; do
	[ -s "/etc/wireguard/$i.key" ] || (umask 077 && wg genkey > "/etc/wireguard/$i.key")
done

echo "== SSH（鍵だけ、root では入らせない。D4）"
cat > /etc/ssh/sshd_config.d/10-aka.conf << 'EOF'
# aka-mvpset（docs/deployment.md §3）
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers aka pull
X11Forwarding no
EOF
sshd -t
if [ "$NOSD" = 1 ]; then pkill -HUP -x sshd || true; else systemctl reload ssh; fi

k=${node//-/_}
echo
echo "== inventory.env に貼る行（このノードの WireGuard の公開鍵）"
for i in $ifaces; do
	v=WGSVC
	[ "$i" = wg-ops ] && v=WGOPS
	echo "${v}_PUB_$k=$(wg pubkey < "/etc/wireguard/$i.key")"
done
echo
echo "次は手元から ssh aka-$node-pub で入れることを確かめる（root と debian では入れなくなった。AllowUsers aka pull）。"
