# deploy/

VPS への配置の部品。手順は [docs/deployment.md](../docs/deployment.md)、ユーザーの作業は [docs/deployment-console.md](../docs/deployment-console.md)。

| パス | 内容 |
|---|---|
| `inventory.env.example` | 手元の値の例（写して作業ディレクトリの `inventory.env` にする。リポジトリに本物の値を入れない） |
| `bin/render` | `inventory.env` から各ノードの設定（WireGuard、nftables、systemd、監視の対象、`.env` のヒント）と SSH の設定を描き出す |
| `bin/build-images` | `versions.env` のコミットからイメージをビルドし、役ごとの束と `git archive`、`SHA256SUMS` を作る（リリースの束は CI の `.github/workflows/build-images.yml` が同じものを作る） |
| `bin/push-host` | 描き出した設定と部品をノードに送り、`host/apply-host.sh` を動かす |
| `host/bootstrap.sh` | 作ったばかりの VPS で root として 1 回だけ動かす（ユーザー、SSH、パッケージ、WireGuard の鍵） |
| `host/apply-host.sh` | 段（files・wg・nft・docker・node・monitor）ごとにホストに置く |
| `host/aka-nft-apply`・`aka-nft-confirm` | nftables を当て、60 秒の内に確かめがなければ戻す |
| `host/` のほか | `nftables.conf`、`daemon.json`、エッジの sysctl、logrotate |
| `node/` | textfile のスクリプト（数値・証明書）、バックアップ、起動のときの `docker compose up`（`compose-up.sh`）、systemd の単位と timer、node_exporter の compose |
| `node/metrics/` | データ面・管理面の Fluent Bit に重ねる、ログの `event_id` ごとの行数を数える設定と compose の重ね合わせ（アプリの数。docs/deployment.md §9.5） |
| `monitor/` | 監視ノードの compose（Prometheus・Alertmanager・Grafana・blackbox_exporter）、警告の規則、ダッシュボード |
| `monitor-tests/` | 警告の規則の試験（promtool。監視ノードには写さない） |
| `probe/` | 外形監視（AP の役の radsecproxy と eapaka_test） |
| `ops-pc/` | 監視用の PC の役（検証機の 2 台目のコンテナ。wireguard-go、ログとバックアップの取得） |

検証機でのリハーサルは [verify/deploy-rehearsal/](../verify/deploy-rehearsal/)。
