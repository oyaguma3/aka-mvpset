#!/bin/sh
# エッジの管理モードの画面の確かめ（dind の中で動かす）。開発用の設定で一時に radsec-edge を作り直し、ループバックの画面を読む。終わったら元に戻す。
cd /edge || exit 1
cat > /edge/devui.yaml <<'YAML'
services:
  radsec-edge:
    environment:
      EDGE_GUI_ADDR: "127.0.0.1:8447"
      EDGE_DEV_USER_EMAIL: stage4@example.com
      EDGE_ACCESS_TEAM_DOMAIN: ""
      EDGE_ACCESS_AUD: ""
YAML
export COMPOSE_FILE=compose.yaml:compose.managed.yaml:compose.fluent-bit.yaml:devui.yaml
docker compose up -d --no-build --wait --wait-timeout 90 radsec-edge 2>&1 | tail -1
pid=$(docker inspect -f '{{.State.Pid}}' radsec-edge-radsec-edge-1)
get() { nsenter -t "$pid" -n wget -q -O - "http://127.0.0.1:8447$1" 2>&1; }
echo "== /tenants"; get /tenants | sed 's/<[^>]*>/ /g' | tr -s ' \n' | grep -E 'bravo|charlie|管理|中央' | head -6
get /tenants/2 > /tmp/t2.html
echo "== /tenants/2"; sed 's/<[^>]*>/ /g' /tmp/t2.html | tr -s ' ' | grep -E '管理モード|中央|版|反映|再起動|停止|CRL|持ち込み|brought|照合|送信元|コンテナ|running|動' | head -24
echo "== forms"; grep -oE 'hx-post="[^"]*"' /tmp/t2.html | sort -u
echo "== post"; for p in /tenants/2/update /tenants/2/client-ca /tenants/2/aps; do nsenter -t "$pid" -n wget -S -q -O /dev/null --post-data 'x=1' "http://127.0.0.1:8447$p" 2>&1 | grep -E 'HTTP/' | head -1; done
unset COMPOSE_FILE
rm -f /edge/devui.yaml
docker compose up -d --no-build --wait --wait-timeout 90 radsec-edge 2>&1 | tail -1
