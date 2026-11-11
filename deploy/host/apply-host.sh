#!/usr/bin/env bash
# 描き出した設定と deploy/ の部品をホストに置く（docs/deployment.md §4〜§9）。deploy/bin/push-host が送って sudo で動かす。
#   sudo /tmp/aka-deploy/host/apply-host.sh [段 ...]
# 段（省くと全部、この順）: files wg nft docker node monitor
#   files   /etc・/opt の設定、ノードのスクリプトと systemd の単位、logrotate、pull の鍵
#   wg      wg-svc・wg-ops を有効にする（公開鍵がそろっていなければ止める）
#   nft     nftables を当てる。60 秒の内に aka-nft-confirm を動かさなければ前の規則に戻す
#   docker  docker-ce（版を固定）、daemon.json、エッジの sysctl
#   node    node_exporter と textfile の timer、バックアップの timer
#   monitor 監視ノードだけ。Prometheus・Alertmanager・Grafana・blackbox_exporter
# AKA_NO_SYSTEMD=1 のとき（リハーサルのコンテナ）は systemd を使わずに wg-quick と nft を直接動かし、docker・node・monitor は飛ばす。
set -euo pipefail

D=$(cd "$(dirname "$0")/.." && pwd) # 送った束（root/ と deploy の部品）
ROOT=$D/root
DOCKER_VERSION=5:29.9.2-1~debian.13~trixie
NOSD=${AKA_NO_SYSTEMD:-0}
[ "$(id -u)" = 0 ] || { echo "sudo で動かす" >&2; exit 2; }
role=$(cat "$ROOT/etc/aka/role")
node=$(cat "$ROOT/etc/aka/node")
log() { echo "== [$node] $*"; }

step_files() {
	log "設定のファイル"
	(cd "$ROOT" && find . -type f) | while read -r f; do
		install -D -m "$(stat -c %a "$ROOT/$f")" "$ROOT/$f" "/${f#./}"
	done
	chmod 700 /etc/wireguard
	install -m 644 "$D/host/nftables.conf" /etc/nftables.conf
	install -d -m 755 /usr/local/lib/aka
	install -m 755 "$D/node/textfile.sh" "$D/node/certs.sh" "$D/node/backup.sh" "$D/node/compose-up.sh" /usr/local/lib/aka/
	install -m 755 "$D/host/aka-nft-apply" "$D/host/aka-nft-confirm" /usr/local/sbin/
	if [ -f "$D/host/logrotate/$role" ]; then install -m 644 "$D/host/logrotate/$role" /etc/logrotate.d/aka; fi
	install -d -o pull -g pull -m 700 /var/lib/aka-pull/.ssh
	install -o pull -g pull -m 600 /etc/aka/pull_authorized_keys /var/lib/aka-pull/.ssh/authorized_keys
	install -d -m 755 /opt/aka-node
	install -m 644 "$D/node/compose.node-exporter.yaml" /opt/aka-node/compose.yaml
	sshd -t
	if [ "$NOSD" = 1 ]; then pkill -HUP -x sshd || true; else systemctl reload ssh; fi
	if [ "$NOSD" != 1 ]; then
		install -m 644 "$D"/node/systemd/*.service "$D"/node/systemd/*.timer /etc/systemd/system/
		systemctl daemon-reload
	fi
}

step_wg() {
	local ifs=wg-svc i
	[ "$role" = mon ] && ifs=""
	for i in $ifs wg-ops; do
		if grep -q '^PublicKey = <' "/etc/wireguard/$i.conf"; then
			echo "$i: 公開鍵がそろっていない（inventory.env に貼って描き直す）" >&2
			exit 1
		fi
		[ -s "/etc/wireguard/$i.key" ] || { echo "$i: 秘密鍵がない（bootstrap.sh を先に）" >&2; exit 1; }
		log "WireGuard $i"
		if [ "$NOSD" = 1 ]; then
			wg-quick down "$i" > /dev/null 2>&1 || true
			wg-quick up "$i"
		else
			systemctl enable "wg-quick@$i"
			systemctl restart "wg-quick@$i"
		fi
	done
}

step_nft() {
	log "nftables（60 秒の内に別の SSH から sudo aka-nft-confirm）"
	[ "$NOSD" = 1 ] || systemctl enable nftables
	/usr/local/sbin/aka-nft-apply
}

step_docker() {
	[ "$NOSD" = 1 ] && return
	if ! dpkg -s docker-ce > /dev/null 2>&1; then
		log "docker-ce $DOCKER_VERSION"
		install -d -m 755 /etc/apt/keyrings
		curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
		chmod 644 /etc/apt/keyrings/docker.asc
		echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list
		apt-get update -q
		install -d -m 755 /etc/docker
		install -m 644 "$D/host/daemon.json" /etc/docker/daemon.json
		# docker-ce の推奨の docker-ce-rootless-extras も同じ版にする（省くと最新が入る）
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q "docker-ce=$DOCKER_VERSION" "docker-ce-cli=$DOCKER_VERSION" \
			"docker-ce-rootless-extras=$DOCKER_VERSION" containerd.io docker-compose-plugin
		apt-mark hold docker-ce docker-ce-cli docker-ce-rootless-extras
		usermod -aG docker aka
	fi
	if ! cmp -s "$D/host/daemon.json" /etc/docker/daemon.json; then
		log "daemon.json（dockerd を再起動する）"
		install -m 644 "$D/host/daemon.json" /etc/docker/daemon.json
		systemctl daemon-reload
		systemctl restart docker
	fi
	if [ "$role" = edge ]; then
		install -m 644 "$D/host/sysctl-edge.conf" /etc/sysctl.d/90-radsec-edge.conf
		sysctl -q --system
	fi
	docker version --format 'docker {{.Server.Version}}'
	docker compose version
}

step_node() {
	[ "$NOSD" = 1 ] && return
	log "node_exporter と timer"
	(cd /opt/aka-node && docker compose up -d --wait)
	systemctl enable --now aka-textfile.timer aka-certs.timer aka-backup.timer
	systemctl enable aka-compose-up.service # 起動のときだけ動く（T5-15）
	/usr/local/lib/aka/textfile.sh
}

step_monitor() {
	[ "$role" = mon ] || return 0
	[ "$NOSD" = 1 ] && return
	log "監視"
	install -d -m 755 /opt/aka-monitor /opt/aka-monitor/secrets
	cp -r "$D"/monitor/. /opt/aka-monitor/
	cp "$ROOT/opt/aka-monitor/prometheus/prometheus.yml" /opt/aka-monitor/prometheus/prometheus.yml
	if [ ! -s /opt/aka-monitor/secrets/slack-webhook ]; then
		echo "Slack の webhook の URL がまだない: /opt/aka-monitor/secrets/slack-webhook（§9.3）。それまでは通知が送れない" >&2
		printf 'https://hooks.slack.com/services/UNSET\n' > /opt/aka-monitor/secrets/slack-webhook
	fi
	[ -s /opt/aka-monitor/secrets/grafana-admin ] || (umask 077 && openssl rand -hex 16 > /opt/aka-monitor/secrets/grafana-admin)
	# Alertmanager は nobody（65534）、Grafana は 472 で動く
	chown 65534:65534 /opt/aka-monitor/secrets/slack-webhook
	chown 472:472 /opt/aka-monitor/secrets/grafana-admin
	chmod 600 /opt/aka-monitor/secrets/slack-webhook /opt/aka-monitor/secrets/grafana-admin
	(cd /opt/aka-monitor && docker compose up -d --wait)
}

steps=${*:-files wg nft docker node monitor}
for s in $steps; do "step_$s"; done
log "済み: $steps"
