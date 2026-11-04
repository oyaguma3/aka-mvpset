# 監視用の PC の役（docs/deployment.md §11、確認事項 D14）。ホストに WireGuard を入れずに、wireguard-go（ユーザー空間）で wg-ops に入る。
FROM debian:13.7-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
	wireguard-tools wireguard-go iproute2 openssh-client rsync netcat-openbsd ca-certificates \
	&& rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh pull.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
