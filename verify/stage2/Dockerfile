# 段階 2 の通しの道具（エッジの代わりの radsecproxy と radclient）。
# radsecproxy は今のエッジのイメージと同じ Debian 13 のパッケージ（1.11.2）。UDP で受けて UDP で送るので、
# PartialChain のパッチ（TLS の受け口のためのもの。verify/r10）は使わない（確認事項 M7）。
FROM debian:13.7-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends "radsecproxy=1.11.2-1+deb13u1" freeradius-utils \
 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
