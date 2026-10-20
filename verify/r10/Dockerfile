# RadSec の受け口のラボ（R10）。radsecproxy を 4 つ用意する:
#   /usr/sbin/radsecproxy             Debian 13 のパッケージ（今のエッジのイメージと同じ 1.11.2-1+deb13u1）
#   /usr/local/bin/radsecproxy-1.11.4 1.11.4 のソースからビルドした無改造のもの
#   /usr/local/bin/radsecproxy-pc-all 1.11.4 に PartialChain（tls ブロックごとのオプション）だけを足したもの（CRL の確認はチェーン全体のまま）
#   /usr/local/bin/radsecproxy-pc     同じく PartialChain を足し、PartialChain on のときは CRL の確認をリーフだけにしたもの
FROM debian:13.7-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libssl-dev nettle-dev pkg-config ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY radsecproxy-1.11.4.tar.gz partialchain.patch partialchain-leafcrl.patch /src/
RUN cd /src && echo "65c269b745b77bbc5da8d4ac1318a91eca22ed879add46d5964bef370900d345  radsecproxy-1.11.4.tar.gz" | sha256sum -c - \
 && tar -xzf radsecproxy-1.11.4.tar.gz && cp -a radsecproxy-1.11.4 stock && cp -a radsecproxy-1.11.4 pcall && mv radsecproxy-1.11.4 patched \
 && cd /src/pcall && patch -p1 < ../partialchain.patch \
 && cd /src/patched && patch -p1 < ../partialchain-leafcrl.patch \
 && cd /src/stock && ./configure -q && make -s -j4 radsecproxy \
 && cd /src/pcall && ./configure -q && make -s -j4 radsecproxy \
 && cd /src/patched && ./configure -q && make -s -j4 radsecproxy

FROM debian:13.7-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends "radsecproxy=1.11.2-1+deb13u1" openssl python3 procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/stock/radsecproxy /usr/local/bin/radsecproxy-1.11.4
COPY --from=build /src/pcall/radsecproxy /usr/local/bin/radsecproxy-pc-all
COPY --from=build /src/patched/radsecproxy /usr/local/bin/radsecproxy-pc
COPY lab.sh radtool.py /lab/
WORKDIR /work
CMD ["bash", "/lab/lab.sh"]
