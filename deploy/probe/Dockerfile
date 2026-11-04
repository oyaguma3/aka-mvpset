# 外形監視の AP の役（docs/deployment.md §9.4）。Debian の radsecproxy で十分（AP の側なので PartialChain のパッチは要らない）。
FROM debian:13.7-slim
RUN apt-get update && apt-get install -y --no-install-recommends radsecproxy ca-certificates && rm -rf /var/lib/apt/lists/*
USER nobody
ENTRYPOINT ["radsecproxy", "-f", "-c"]
