# 配置のリハーサル（検証機）

段階 5 の手順 5-1 で、VPS を契約する前に `deploy/` の部品と [配置の手順書](../../docs/deployment.md) の流れを検証機の 2 台目で確かめた道具と結果です。確認事項 D16（概要 §18.11 の後の 5-1 の記録）によります。

## 作り

```
検証機の 2 台目（ホストの設定は変えない）
 ├─ rh-inet 172.30.0.0/24（インターネットの代わり。ゲートウェイ .1 がホスト＝手元の回線の代わり）
 │    rh-data .10・rh-mgmt .11・rh-mon .12・rh-edge-01 .21・rh-edge-02 .22（Debian 13、VPS の代わり。sshd が動く）
 │    rh-ap .30（インターネットの AP の代わり）
 │    ops-pc .100（deploy/ops-pc のイメージ。監視用の PC の役）
 ├─ rh-int-<ノード>（ノードごと）: rh-<ノード>-svc（Docker が公開するポートの先のコンテナの代わり）
 └─ 監視の compose（rh-monitor。ホストの Docker で動かす）と、偽の Slack の受け口
```

- WireGuard は各コンテナの中の wireguard-go（Debian のパッケージ）で、wg-quick がカーネルのモジュールの代わりに使う。nftables は各コンテナのネットワークの名前空間の中だけに当たる。
- Docker の公開ポートの代わりに、ノードの中で prerouting の DNAT を置き、別のネットワークの受け口のコンテナへ送る（表 `ip rhnat`。リハーサルだけ）。実物の Docker と同じく forward を通るので、表 `inet aka` の `published` の鎖を確かめられる。
- `bootstrap.sh` と `apply-host.sh` は `AKA_NO_SYSTEMD=1` で動かす（systemd がないので、wg-quick と nft を直接動かし、docker・node・monitor の段は飛ばす）。`bootstrap.sh` は `docker exec` で root として動かす（VPS では KAGOYA の鍵で SSH）。
- 監視は、ホストの Docker で `deploy/monitor/compose.yaml` を起動し、ホストの textfile を読む node_exporter を重ねた（`compose.rehearsal.yaml`。リハーサルの中で作る）。`textfile.sh` をホストで動かし、止めたコンテナの警告が Alertmanager から偽の Slack の受け口に届くまでを見る。

| ファイル | 内容 |
|---|---|
| `rehearsal.sh` | 台本（`all`・`up`・`boot`・`apply`・`test`・`rollback`・`close`・`pull`・`monitor`・`teardown`） |
| `Dockerfile.node`・`node-entry.sh` | ノードの役のイメージ（Debian 13.7、sshd） |
| `svc.py` | 受け口（TCP・UDP で返事をする）と試し |
| `results/` | 結果 |

## 動かし方

検証機の 2 台目の `~/aka-work/deploy-rehearsal/repo` に、本リポジトリの `deploy/` と `verify/deploy-rehearsal/` と `versions.env` を置く。

```bash
cd ~/aka-work/deploy-rehearsal && repo/verify/deploy-rehearsal/rehearsal.sh all > run-all.log 2>&1
```

結果は `work/results.tsv`。片付けは `rehearsal.sh teardown` の後に `work` を消し、`docker image prune -af`・`docker builder prune -af`。

## 結果（2026-11-05）

**62 項目すべて PASS**（`results/results.tsv` の 64 行。描き出し `R-render` は 3 回。片付けた後に最初から `all` で通した）。

| 番号 | 確かめたこと |
|---|---|
| B | `bootstrap.sh` が 5 ノードで終わる。`PermitRootLogin no`。作業ユーザー `aka` で公開のアドレスに入れる |
| R・A | 描き出し。`apply-host.sh`（files・wg・nft）が 5 ノードで終わり、規則を当てた後に新しい SSH で確かめられる |
| W | `wg-svc`: データ面と管理面がそれぞれ 3 つとハンドシェイクする。`wg-ops`: 監視ノードが 5 つとハンドシェイクする。エッジどうしはつながらない。監視ノードは中継しない |
| P | 公開ポート（DNAT の後）: RADIUS はエッジからだけ、aka-vecgen・aka-radius の管理API は管理面からだけ、CRL の配布はエッジからだけ、エッジの管理API は管理面からだけ、テナントのポートはインターネットから、監視の画面は ops-pc からだけ。インターネットからの RADIUS とエッジの管理API は断る |
| I | node_exporter は監視ノードからだけ。インターネットからの SSH（手元のアドレス以外）と 9100、`wg-svc` からの SSH は断る |
| S | 手元から ops-pc と監視ノードを踏み台にしてデータ面・エッジに入れる |
| N | 規則を当てて確かめないと、60 秒で前の規則に戻る（閉め出されたときの戻り道） |
| C | `BOOTSTRAP_SSH_FROM` を空にして `wg-ops` を通して送り直すと、公開のアドレスへの SSH は断られ、`wg-ops` を通しては入れる |
| G | ops-pc の `pull.sh` が 5 ノードから取りに行ける。`pull` は書けない・シェルを動かせない・踏み台の転送は各ノードの 22 番だけ |
| M | 描き出した `prometheus.yml` と `rules.yml` が promtool、`alertmanager.yml` が amtool の検査を通る。監視の compose が healthy、Grafana のダッシュボード。`textfile.sh` → node_exporter → Prometheus → 警告（`ContainerNotRunning`）→ Alertmanager → Slack の形の通知 |

## 試して分かったこと（部品を直した）

- **規則が返事のパケットを落としていた**: `published` の鎖は DNAT 済みの接続の両方向に当たる。実物の Docker では返事はコンテナの橋（`br-*`）から来て通るが、規則としては許した接続への返事を明示して通すのが正しいので、先頭に `ct direction reply accept` を足した。
- **OpenSSH 10 の `PerSourcePenalties` で締め出された**: 認証しないまま閉じた接続（台本の `nc -z` の確かめ）があると、その送信元をしばらく断る（`Not allowed at this time`）。配置では SSH はどれも 1 つの送信元（監視ノードへは ops-pc、各ノードへは監視ノード）から届くので、締め出されると入口がなくなる。nftables で絞ってある送信元だけを `PerSourcePenaltyExemptList` で外すようにした（`render` が描き出す）。
- **取ったファイルが検証機のユーザーから読めなかった**: ops-pc の中の root で書くため。`pull.sh` が `data/` の持ち主に合わせ、本人だけが読める形にした。
- `sudo` を通すと `AKA_NO_SYSTEMD` が渡らないので、`push-host` が渡すようにした（リハーサルだけで使う切り替え）。
- 確認事項 D13 の「ACL で読み取りだけを与える」は、各ノードがファイルを 600 で作ると効かないので、`backup.sh` が root で `/srv/aka-pull` に写す形に改めた（手順書 §10）。

## 確かめていないもの（5-3〜5-6 で VPS の上で確かめる）

- systemd の単位（`wg-quick@`、nftables、docker の起動の順、timer）の実際の動き。`systemd-analyze verify` は手元で文法だけを見た。
- docker-ce の導入と `daemon.json`、node_exporter の `network_mode: host`、各ノードの導入、`certs.sh`・`backup.sh` の実物での動き（`certs.sh` の mTLS の口からの読み取りは、手元の Go のサーバーで確かめた）。
- KAGOYA のセキュリティグループ（ポートの範囲、外向きの通信）、インターネット越しの AP と実際の送信元のアドレス、外形監視、Slack の本物の webhook、`build-images` の束を VPS で読み込むこと。
