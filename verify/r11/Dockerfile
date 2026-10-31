FROM debian:13.7-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libssl-dev nettle-dev pkg-config ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY partialchain-leafcrl.patch /src/
RUN cd /src && curl -fsSLO https://github.com/radsecproxy/radsecproxy/releases/download/1.11.4/radsecproxy-1.11.4.tar.gz \
 && echo "65c269b745b77bbc5da8d4ac1318a91eca22ed879add46d5964bef370900d345  radsecproxy-1.11.4.tar.gz" | sha256sum -c - \
 && tar -xzf radsecproxy-1.11.4.tar.gz && cd radsecproxy-1.11.4 && patch -p1 < ../partialchain-leafcrl.patch && ./configure -q && make -s -j4 radsecproxy
FROM debian:13.7-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssl libnettle8t64 procps && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/radsecproxy-1.11.4/radsecproxy /usr/local/bin/radsecproxy
COPY lab.sh /lab.sh
CMD ["bash","/lab.sh"]
