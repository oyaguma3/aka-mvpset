# 配置の手順書（VPS）

- 状態: 段階 5 の手順 5-1 で書いた（2026-11-05）。検証機のリハーサル（`verify/deploy-rehearsal/`）で WireGuard・nftables・SSH・取得の流れを確かめた。VPS の上の確かめは 5-3〜5-6 で行い、分かったことで直す。
- 位置づけ: MVP セットのノードを VPS に置く手順の正本。各ノードの中の導入は各ノードの運用ガイドに従い、本書は VPS とノードの間（ホスト、WireGuard、nftables、Docker、イメージ、監視、ログとバックアップの取得）を受け持つ。決めたことは要件と構成の概要（以下「概要」）§18.11 の S5-1〜S5-17 と、5-1 の確認事項 D1〜D16（概要 §18.11 の後の記録）。
- ユーザー（事業者の契約者）の作業は [deployment-console.md](deployment-console.md) に分けた。
- 部品は `deploy/`（[deploy/README.md](../deploy/README.md)）。本物の値（公開のアドレス、ドメイン、WireGuard の公開鍵）は手元の `inventory.env` に書き、リポジトリに入れない。

## 1. 構成とアドレス

| ノード | 名前（SSH） | 置くもの | 大きさ（KAGOYA） |
|---|---|---|---|
| データ面 | `aka-data` | aka-radius（auth・acct・admin、Valkey、Fluent Bit）、aka-vecgen（Valkey） | 4 GB（4 コア・600 GB） |
| 管理面 | `aka-mgmt` | aka-ossbss（PostgreSQL、cloudflared）、aka-provisioner（Valkey、管理面の Fluent Bit）、radsec-ca | 4 GB |
| エッジ | `aka-edge-01`・`aka-edge-02` | radsec-edge（管理モード、テナントごとの radsecproxy、Fluent Bit） | 4 GB |
| 監視 | `aka-mon` | Prometheus、Alertmanager、Grafana、blackbox_exporter、外形監視、踏み台 | 2 GB（2 コア・200 GB） |
| 監視用の PC | `ops-pc` | 検証機の 2 台目のコンテナ。ログとバックアップを取りに行き、Claude の作業の入口になる | — |

どのノードにも node_exporter を置く。

**WireGuard**（D1・D2。概要 §5.3）:

| | `wg-svc`（サービス用） | `wg-ops`（運用用） |
|---|---|---|
| アドレス | 10.81.0.0/24。データ面 .1、管理面 .2、エッジ .11 から順に | 10.82.0.0/24。監視 .1、データ面 .2、管理面 .3、エッジ .11 から順に、ops-pc .100 |
| ポート | UDP 51820 | UDP 51821 |
| つなぎ方 | ハブを置かない。エッジ → データ面、エッジ → 管理面、管理面 → データ面（つなぎに行く側が Endpoint と 25 秒ごとの keepalive を持つ）。エッジどうしはつながない | 全員が監視ノードへつなぐ。監視ノードは中継しない（SSH は監視ノードを踏み台にする） |
| 通すもの | RADIUS（エッジ → aka-radius 1812・1813）、管理API（aka-provisioner → aka-vecgen 9443・aka-radius 9444・エッジ 9447）、CRL の取得（エッジ → radsec-ca 8449） | SSH、node_exporter（9100）、ログとバックアップの取得、監視の画面（3000・9090・9093） |

**公開する口**（インターネット側）: 全ノードの WireGuard の UDP（`wg-svc` は監視ノード以外、`wg-ops` は全ノード）と、エッジのテナントのポート（TCP 20000〜21999）だけ。最初の導入の間だけ、手元の回線のアドレスから SSH（22）を受ける（D4）。

**手元の値**: `deploy/inventory.env.example` を作業ディレクトリに写して `inventory.env` にし、公開のアドレスなどを書く。`deploy/bin/render inventory.env out` が `out/<ノード>/` に各ノードに置く設定を、`out/ssh_config` に手元の SSH の設定を描き出す。秘密鍵は描き出さない（WireGuard の秘密鍵は各ノードの `/etc/wireguard/<if>.key` を `PostUp` で読む）。

## 2. ユーザーの作業

[deployment-console.md](deployment-console.md) のとおり、ユーザーが KAGOYA のコントロールパネルで、ログイン用認証キー、セキュリティグループ、インスタンス 5 台を作り、公開のアドレスと鍵のファイルの置き場所を Claude に渡す。DNS のレコードはテナントを置くとき（§8.4）にユーザーが登録する。

- KAGOYA のセキュリティグループは宛先ポートを 1 つしか書けない（範囲は不可）。外向き・内向きを分ける設定もない（2026-11 にユーザーが確かめた）。そのため次のように扱う。
  - エッジのテナントのポート（TCP 20000〜21999）はセキュリティグループに書かない。エッジはテナントを置く前にセキュリティグループを外し、ホストの nftables だけで守る（確認事項 K1。§8.3）。
  - インスタンスを作ったら、最初に各ノードで、外向きの通信への応答（apt、名前の解決、HTTPS、WireGuard）が通るかを確かめる。断られていたら、全ノードからセキュリティグループを外す（確認事項 K2。§3）。

## 3. 最初の導入（各ノード）

1. 手元で作業用の SSH の鍵を作る（初めてのときだけ）。

   ```bash
   ssh-keygen -t ed25519 -C aka-mvp -f ~/.ssh/aka_mvp_ed25519
   ```

2. `inventory.env` の `ADMIN_SSH_KEY` に公開鍵を、`BOOTSTRAP_SSH_FROM` に手元の回線の公開のアドレスを書き、描き出す。手元の `~/.ssh/config` の先頭に `Include <作業>/out/ssh_config` を足す。

   ```bash
   deploy/bin/render "$WORK/inventory.env" "$WORK/out"
   ```

3. 各ノードで `bootstrap.sh` を root として 1 回動かす。KAGOYA の Debian 13 はユーザー `debian`（sudo はパスワードなし）で入る作りなので、KAGOYA の鍵で `debian` として入り `sudo` で動かす（この 1 回だけ。最後に `AllowUsers aka pull` で `debian` と root では入れなくなる。2 回動かしても同じ結果になる）。時刻（Asia/Tokyo と NTP）、ホスト名、パッケージ、自動の更新（セキュリティだけ、自動の再起動なし）、作業ユーザー `aka`（sudo はパスワードなし。段階 5 の間だけ）、取得のユーザー `pull`、WireGuard の鍵を作る。

   ```bash
   ssh -i ~/.ssh/<KAGOYA の鍵>.key debian@<公開のアドレス> "sudo bash -s -- data '$(cat ~/.ssh/aka_mvp_ed25519.pub)'" < deploy/host/bootstrap.sh
   ```

   最後に出る `WGSVC_PUB_*`・`WGOPS_PUB_*` の行を `inventory.env` に貼る。bootstrap の `apt-get` が通らなければ、セキュリティグループが外向きの通信への応答を断っている（K2）。ユーザーに全ノードから外してもらってやり直す。続けて `ssh aka-data-pub` で `aka` として入れることを確かめる。

4. 検証機の 2 台目で ops-pc を起動し（§11）、出る `WGOPS_PUB_pc` と `PULL_SSH_KEY` を `inventory.env` に貼って、もう一度描き出す。

SSH は鍵だけで、root では入らせない。`AllowUsers aka pull`。最初の導入が終わったら、SSH は `wg-ops` からだけ（nftables）受け、セキュリティグループの 22 番も閉じる（§4.3）。

- SSH はどれも 1 つの送信元から届く（監視ノードへは ops-pc、各ノードへは監視ノード）。OpenSSH 10 の `PerSourcePenalties` は、認証しないまま閉じた接続などがあるとその送信元をしばらく締め出すので、入口がなくなる（リハーサルで起きた）。nftables で絞ってある送信元だけを `PerSourcePenaltyExemptList` で外す（`/etc/ssh/sshd_config.d/20-aka-wg.conf`。`render` が描き出す）。

## 4. WireGuard と nftables

### 4.1 置く

公開鍵がそろったら描き出し、ノードごとに設定を置いて WireGuard と nftables を上げる。最初は公開のアドレスで入る（`AKA_SSH=aka-<ノード>-pub`）。順は監視 → データ面 → 管理面 → エッジ（つなぎに行く先を先に上げる）。

```bash
deploy/bin/render "$WORK/inventory.env" "$WORK/out"
AKA_SSH=aka-mon-pub deploy/bin/push-host "$WORK/out" mon files wg nft
```

`nft` の段は規則を当てた後 60 秒の内に確かめを待つ。**別の端末で新しく SSH で入れることを確かめて**から `sudo aka-nft-confirm` を動かす。動かさなければ前の規則に戻る（閉め出されたときのため。それでも入れなければ事業者のコンソールから入る）。

```bash
ssh aka-mon-pub sudo aka-nft-confirm
```

確かめ:

```bash
ssh aka-mon-pub sudo wg show
```

`latest handshake` が出ていること（つなぎに行く側を上げた後）。

`wg-ops` は MTU を 1280 にしてある（`render` が描き出す）。ops-pc は手元の回線を通るため、既定の 1420 では包んだパケットが経路の MTU を超えて落ち、SSH が鍵交換の途中で止まった（2026-11 に KAGOYA で起きた。確認事項 K3）。`wg-svc`（VPS どうし）は既定のまま。全ノードを上げたら、手元から `ssh aka-data`（ops-pc と監視ノードを経由）で入れることを確かめる。

### 4.2 規則（`/etc/nftables.d/aka.nft`）

- 表 `inet aka` だけを作り直す。Debian の既定の `/etc/nftables.conf` は `flush ruleset` で Docker の規則まで消すので、`deploy/host/nftables.conf`（`include` だけ）に置き換える。Docker は今のとおり iptables（nft の互換）で自分の表を持つ。
- 入ってくるもの（input）は既定で拒否。受けるのは、確立済み、ICMP（上限つき）、WireGuard の UDP、`wg-ops` から監視ノードの SSH と 9100、最初の導入の間だけ手元からの 22。
- **Docker が公開したポートは、DNAT の後に forward を通る**（input ではない）。Docker の鎖より先（`priority filter - 1`）で、DNAT 済みのものを元の宛先ポートで絞る。

| ノード | 外から受ける公開ポート |
|---|---|
| データ面 | `wg-svc` のエッジから UDP 1812・1813、`wg-svc` の管理面から TCP 9443・9444 |
| 管理面 | `wg-svc` のエッジから TCP 8449 |
| エッジ | `wg-svc` の管理面から TCP 9447、インターネットから TCP 20000〜21999 |
| 監視 | `wg-ops` の ops-pc から TCP 3000・9090・9093 |

- 送信元はトンネルのアドレス（送り出す側の Docker が MASQUERADE するので、エッジから届く RADIUS の送信元はエッジの `wg-svc` のアドレス）。aka-radius の RADIUS クライアントもこのアドレスで登録する（§8.2）。
- 許した接続への返事（`ct direction reply`）は通す。ほかの公開ポートへの外からの接続は落とす（`counter` で数える）。ループバックに公開したポート（aka-vecgen の 8443、aka-provisioner の 9446、Fluent Bit の 24224）は外から届かない。
- 規則を変えたら描き直して `push-host … files nft`。

### 4.3 最初の導入を閉じる

全ノードの `wg-ops` が上がり、`ssh aka-<ノード>` で入れるようになったら、`inventory.env` の `BOOTSTRAP_SSH_FROM` を空にして描き直し、全ノードに `files nft` を送る。ユーザーにセキュリティグループの 22 番を閉じてもらう（[deployment-console.md](deployment-console.md) §3）。

## 5. Docker

```bash
deploy/bin/push-host "$WORK/out" data docker
```

- Docker の apt のリポジトリから docker-ce `5:29.9.3-1~debian.13~trixie`・containerd.io `2.4.2-4~debian.13~trixie`（段階 5 の T5-10・T5-24 でエッジに 150 テナントと AP の接続 740 本を載せたまま上げて確かめた版）と compose プラグインを入れ、`apt-mark hold` で固定する（D6）。docker-ce の推奨の docker-ce-rootless-extras も同じ版で入れて固定する（省くと最新の版が入る。2026-11-11 に 29.9.3 が入った）。containerd.io も固定する（固定しないと `apt-get upgrade` で計画なしに containerd が入れ替わる）。
- 上げるときは `deploy/host/apply-host.sh` の `DOCKER_VERSION`・`CONTAINERD_VERSION` を変え、1 台ずつ `push-host … <ノード> docker` で送る（版が違えば上げて固定し直す）。dockerd と containerd は再起動するが、コンテナは live-restore で動き続け、張ったままの接続も切れない（edge-02 で確かめた。dockerd の再起動だけなら約 16 秒、更新は約 27 秒で dockerd が応える）。パッケージの更新は docker.socket も作り直すので、エッジの agent（`/var/run/docker.sock` をファイルでマウントしている）は古いソケットを見たまま届かなくなり、約 1 分後に自分で終わって作り直され、つなぎ直す（radsec-edge の運用ガイド 10.1。この間に反映を始めると agent に届かず失敗しうるので、エッジの更新の後は agent が戻ってから反映する）。dockerd の再起動（`systemctl restart docker`）だけなら docker.socket は変わらず、agent は 1 秒ほどでつなぎ直す。
- `/etc/docker/daemon.json` は全ノード同じ（`deploy/host/daemon.json`: `userland-proxy: false`、`live-restore: true`、json-file のローテーション）。変えると dockerd を再起動する。
- systemd の設定（`docker.service.d/10-aka-wireguard.conf`）で、docker を `wg-quick@wg-svc`・`wg-quick@wg-ops` の後に起動する（WireGuard のアドレスで公開するポートがあるため。D7）。再起動すると nftables → WireGuard → docker の順に上がる（2026-11-11 に edge-02 で確かめた）。
- エッジだけ `fs.inotify.max_user_instances = 1024`（radsec-edge の運用ガイド 10.1）。
- `aka` を docker のグループに入れる。

## 6. リポジトリの中身を置く

各ノードの compose と文書は、`versions.env` のコミットから `git archive` で作ったもの（`deploy/bin/build-images` が `<作業>/src/<リポジトリ>.tar` を作る）を `/opt/<リポジトリ>` に置く（D8）。エッジのデータは今のとおり `/var/lib/radsec-edge`。

```bash
ssh aka-data 'sudo install -d -o aka -g aka /opt/aka-radius /opt/aka-vecgen'
ssh aka-data 'tar -xf - -C /opt/aka-radius' < "$WORK/src/aka-radius.tar"
```

`.env` と秘密の値は各ノードの運用ガイドのとおりに作る（`/opt/<リポジトリ>` の中。git の管理の外）。

## 7. イメージ

```bash
deploy/bin/build-images "$WORK"
ssh aka-data 'gunzip | docker load' < "$WORK/images/data.tar.gz"
```

- 手元で `versions.env` のコミットからビルドする（VPS の上ではビルドしない。概要 §17.3）。束は役ごと（`data`・`mgmt`・`edge`・`mon`）。`images.txt` に名前と ID を残す。
- イメージの名前: aka-radius・aka-provisioner・radsec-ca・radsec-edge は `<名前>:<短いコミット>` なので、各 `.env` の `RADIUS_VERSION`・`PROVISIONER_VERSION`・`CA_VERSION`・`EDGE_VERSION` に `images.txt` の最後の行の値を入れる。aka-vecgen・aka-ossbss は compose に `image:` がないので、compose が付ける `aka-vecgen-aka-vecgen:latest`・`aka-ossbss-aka-ossbss:latest`（プロジェクト名はディレクトリの名前）に合わせてある。
- 起動は `docker compose up -d --no-build`（ビルドしない）。
- 公開のイメージ（valkey、postgres、fluent-bit、cloudflared、busybox、監視の部品）は VPS で `docker compose pull` する。取り込んだダイジェストは `docker image ls --digests` で記録する（段階 5 の締めで概要に書く）。

## 8. 各ノードの導入

各ノードの運用ガイドの導入の章に従う。`out/<ノード>/env-hints.txt` に、そのノードの `.env` に入れる WireGuard のアドレスなどを描き出してある。順はデータ面 → 管理面 → エッジ（運用ガイドの「先に導入する」に合わせる）。

- **設定の読み直しの `docker compose kill -s HUP` を受けたコンテナは、再起動の後に起き上がらない。** Docker がそのコンテナに「手で止めた」の印を付け、`unless-stopped` は起動のときにそれを起こし直さない（2026-11-11 に、HUP を送った aka-provisioner が管理面の再起動の後に止まったままになった。確認事項 T5-15）。そのため各ノードに `aka-compose-up.service`（`push-host … node` が有効にする）を置き、起動のときに `/etc/aka/compose-stacks` のスタックを `docker compose up -d --no-build` で起こす。動いているコンテナには何もしない。起動しないと決めたもの（radsec-ca・エッジの cloudflared。D10）は一覧に入れていない。スタックを足したら `render` の `compose_stacks` も直す。

### 8.1 データ面（aka-vecgen → aka-radius）

- aka-vecgen: 運用ガイド 2〜4 章。`.env` の `VECGEN_ADMIN_PUBLISH` を `wg-svc` のアドレスの 9443、`VECGEN_ADMIN_TLS_HOSTS` にそのアドレスを足す。データ面の Fluent Bit に送る重ね合わせ（`COMPOSE_FILE=compose.yaml:compose.fluent-bit.yaml`）。
- aka-radius: 運用ガイド 2〜4 章（`/opt/aka-radius/deployments`）。**`.env` に `COMPOSE_PROJECT_NAME=aka-radius` を書く**（ディレクトリの名前 `deployments` のままだと、プロジェクト名とボリューム名が `deployments` になる）。`RADIUS_UDP_BIND`・`RADIUS_ADMIN_BIND` を `wg-svc` のアドレスに。管理API のサーバー証明書の SAN にもそのアドレスを入れる（`admin-cert create -hosts aka-radius-admin,<アドレス>`）。aka-vecgen への共有ネットワークの重ね合わせ（`docker-compose.aka-av.yml`）。
- 両方とも `--no-build`。

### 8.2 管理面（aka-provisioner → aka-ossbss → radsec-ca）

- aka-provisioner: 運用ガイド 2〜3 章。登録簿 `downstreams/downstreams.json` の url はデータ面とエッジの `wg-svc` のアドレス（`env-hints.txt`）。`PROVISIONER_PUBLISH` はループバックのまま。
- aka-ossbss: 運用ガイド 2〜3 章。cloudflared も起動する（Tunnel のトークンは前の段階から使っている `ossbss-dev` のもの。S5-4）。
- radsec-ca: 運用ガイド 2 章と 3 章（管理モード、`compose.managed.yaml`）。`CA_BIND_ADDR` は管理面の `wg-svc` のアドレス（CRL の配布の口 8449）。**cloudflared は起動しない**（D10）。`docker compose up -d --no-build radsec-ca` のように、サービスの名前を指定して起動する。画面は要るときに SSH のポート転送で開く。
- データ面の aka-radius で、エッジの `wg-svc` のアドレスを RADIUS クライアントとして刻印を信頼する印をつけて登録する（aka-radius の運用ガイド 4 章。エッジごと）。

### 8.3 エッジ

- **テナントを置く前に、ユーザーにエッジからセキュリティグループを外してもらう**（[deployment-console.md](deployment-console.md) §3.3。K1）。外すまでは AP がテナントのポートにつながらない。
- radsec-edge の運用ガイド 10 章（管理モード）。`.env` は `env-hints.txt` のとおり（`EDGE_BIND_ADDR`・`EDGE_TLS_HOSTS` は `wg-svc` のアドレス、`EDGE_CRL_BASE_URL` は管理面の 8449、`EDGE_AGENT_PUBLISH_ADDR` は公開のアドレス、上流は aka-radius の `wg-svc` のアドレスの 1812・1813）。
- **cloudflared は起動しない**（D10）。`docker compose up -d --no-build radsec-edge radsec-edge-agent fluent-bit`。
- aka-provisioner の登録簿にエッジを足し、aka-ossbss の台帳に足す（aka-ossbss の運用ガイド 14.3）。

### 8.4 テナントを置くとき

DNS のレコード（エッジの名前の A レコードと、スロットの名前の CNAME。aka-ossbss の運用ガイド 14.5）はユーザーが登録する（[deployment-console.md](deployment-console.md) §4）。

## 9. 監視

### 9.1 node_exporter と監視ノード

```bash
deploy/bin/push-host "$WORK/out" data files node
deploy/bin/push-host "$WORK/out" mon files node monitor
```

- 各ノード: `/opt/aka-node` の node_exporter（`network_mode: host`、`wg-ops` のアドレスの 9100）と、textfile のスクリプトの timer（§9.2）、バックアップの timer（§10）、起動のときの `aka-compose-up.service`（§8）。
- 監視ノード: `/opt/aka-monitor` に Prometheus（30 日持つ）、Alertmanager、Grafana、blackbox_exporter（aka-ossbss の公開のホスト名）。版は compose で固定した（D11）。画面は `wg-ops` のアドレスだけで公開し、手元からポート転送で見る。

  ```bash
  ssh -L 3000:10.82.0.1:3000 -L 9090:10.82.0.1:9090 -L 9093:10.82.0.1:9093 aka-mon
  ```

  Grafana の `admin` の初めのパスワードは `/opt/aka-monitor/secrets/grafana-admin`。ダッシュボード「aka-mvpset の概要」を置いてある。

### 9.2 数値と警告

各ノードの小さなスクリプトが node_exporter の textfile collector（`/var/lib/aka-textfile`）に書く。ノードのコードは変えず、監視にクライアント証明書を渡さない（S5-10）。

| スクリプト | 間隔 | 数値 |
|---|---|---|
| `textfile.sh` | 1 分 | `aka_docker_up`、`aka_container_running`・`aka_container_healthy`（再起動の方針のあるコンテナ）、`aka_process_rss_bytes`（dockerd・containerd）、`aka_wg_handshake_age_seconds` |
| `certs.sh` | 1 時間 | `aka_cert_not_after_seconds`（各ノードの管理API などのサーバー証明書、エッジのテナントのサーバー証明書）、`aka_crl_next_update_seconds`（エッジのテナントの CA の束の CRL） |
| `backup.sh` | 毎日 2:30 | `aka_backup_last_success_seconds`、`aka_backup_last_run_failed` |
| `probe.sh`（監視ノード） | 1 分 | `aka_probe_success`、`aka_probe_consecutive_failures`、`aka_probe_last_run_seconds` |

- `certs.sh` は `openssl s_client` でサーバー証明書を読む。mTLS の口は TLS 1.3 ではクライアント証明書を求める前に証明書が届くので読めるが、**各ノードのログに 1 時間に 1 回、クライアント証明書のない接続の拒否が出る**（aka-radius の `ADMIN_CLIENT_REJECTED` など。送信元は自分のアドレス）。radsec-ca の管理API はホストに公開しないので、コマンド（`server-cert`）で読む。
- 警告の規則は `deploy/monitor/prometheus/rules.yml`: ノードが落ちた、ディスク 80%、メモリー、エッジの使用量が容量の目安 2.8 GiB 超（30 分。T5-25）、数値が 5 分古い、Docker に届かない、コンテナが止まった・unhealthy、エッジの dockerd・containerd が 400 MiB 超（決定事項 28）、ハンドシェイクが 180 秒より古い、aka-ossbss の公開のホスト名に届かない、証明書の期限 14 日前、CRL の次の更新まで 2 日、バックアップが 26 時間ない・失敗、外形監視が 3 回続けて失敗・結果が 5 分ない。

### 9.3 Slack への通知

Alertmanager は Slack の webhook に送る（S5-11）。webhook の URL は `/opt/aka-monitor/secrets/slack-webhook`（600、UID 65534）に置き、`docker compose restart alertmanager`。Slack アプリの作り方は [deployment-console.md](deployment-console.md) §5。

### 9.4 外形監視

監視ノードに AP の役（Debian の radsecproxy。スロットごとに 1 つ）と eapaka_test を置き、1 分ごとに 2 台のエッジのスロットの名前（`primary`・`secondary`）へ EAP-AKA を最後まで通す（S5-12）。インターネット越しにエッジの公開のアドレスへつなぐ。

1. aka-ossbss で監視専用のテナント（例 slug `probe`）を作り、RadSec を有効にして 2 台に置き、AP を 1 台登録して証明書を発行する。監視専用の IMSI を両側に登録し、認可は監視の SSID だけにする（最小）。課金レコードに出るので、外部のシステムではこのテナントの ID で除く。
2. 監視ノードの `/opt/aka-probe` に `deploy/probe/` を置き、`probe.env`（600。`probe.env.example`）、`conf/ap.pem`・`ap.key`・`server-ca.pem`（`chown -R 65534:65534 conf`）、`/usr/local/bin/eapaka_test`（`build-images` の `bin/`）を置く。
3. `probe.sh conf` で radsecproxy の設定を作り、`PROBE_VERSION` を `images.txt` の値にして `docker compose up -d --no-build`。`deploy/probe/systemd/` の `aka-probe.timer` を有効にする。

## 10. バックアップとログの取得

- 各ノードの `backup.sh`（毎日 2:30。aka-ossbss の定期の処理 3:00〜6:00 を避ける）が `/srv/aka-pull/backups/<日付>/` に置く。ノードには 3 日分。RPO は 24 時間、RTO は 4 時間（S5-14）。

| ノード | 取るもの |
|---|---|
| データ面 | aka-radius の Valkey（`backup-valkey.sh`）と `.env`・`sources/`・`certs/admin/`・ピン、aka-vecgen の Valkey と `.env`・ピン |
| 管理面 | aka-provisioner の Valkey と `.env`・`downstreams/`・ピン、aka-ossbss の DB（`backup-db.sh`）と `.env`・`certs/`、radsec-ca の DB（`backup`）と `.env`・ピン |
| エッジ | `radsec-edge` を止めて `/var/lib/radsec-edge/data` を写し、すぐ起動する（テナントのコンテナと AP の接続は続く）。`.env`・ピン |
| 監視 | `/opt/aka-monitor` の設定 |

- **KEK と Tunnel のトークンは入れない**（別に保管する。§12）。一括投入の後は手でも取る（`sudo /usr/local/lib/aka/backup.sh`）。データ面を戻すと、最後のバックアップの後の一括投入は失われる（鍵は aka-vecgen にしかない）。
- 同じスクリプトが、ログと監査ログの圧縮した前の日までのもの（logrotate の `*.gz`、監査ログの `audit-*.jsonl.gz`）を `/srv/aka-pull/logs/<名前>/` に写す（ノードの 14 日分と同じ）。対象は `/etc/aka/export.list`。
- ops-pc が毎日取りに行く（§11）。各ノードの `pull` は `rrsync -ro /srv/aka-pull` だけを動かせる（読むことしかできない）。**5-1 の確認事項 D13 の「ACL で読み取りだけを与える」は、各ノードのファイルの作り方（600 で作るもの）に左右されるので、root が `/srv/aka-pull` に写す形に改めた。**
- logrotate の設定は各ノードの運用ガイドの例のまま（`deploy/host/logrotate/`）。

## 11. ops-pc（監視用の PC の役）

検証機の 2 台目の `~/aka-work/ops-pc` に `deploy/ops-pc/` を置く（S5-13・D14）。ホストに WireGuard や rsync を入れず、コンテナの中の wireguard-go で `wg-ops` に入る。

```bash
cd ~/aka-work/ops-pc && docker compose up -d --build && docker compose logs ops-pc
```

1. 初めの起動で鍵を作り、`WGOPS_PUB_pc` と `PULL_SSH_KEY` を出す。`inventory.env` に貼って描き直す。
2. 描き出した `out/ops-pc/` の `wg-ops.conf`・`ssh_config`・`nodes.list` を `state/` に置き、`docker compose restart`。
3. 毎日の取得は検証機の claude ユーザーの crontab から（バックアップの後）:

   ```
   30 5 * * * docker exec ops-pc /usr/local/bin/pull.sh >> $HOME/aka-work/ops-pc/pull.log 2>&1
   ```

- ログと監査ログは 3 か月（概要 §13）、バックアップは 30 日持つ（`data/<ノード>/`）。取ったものは `data/` の持ち主（検証機のユーザー）のものにし、本人だけが読める（`.env` の写しなど秘密の値を含む）。生の IMSI がログに入る（決定事項 26）ので、`data/` は検証機の外に出さない。
- 手元の SSH は `ssh <検証機> docker exec -i ops-pc nc -N <監視ノード> 22` を経由する（`out/ssh_config` の `aka-mon`）。`-N`（入力の終わりで接続を閉じる）がないと、SSH を終えても `docker exec` の中の `nc` が残り、監視ノードとその先のセッションが溜まる（2026-11-11 に監視ノードに 211 本たまり、空きメモリーが 632 MiB まで減った。確認事項 T5-14）。各ノードの sshd は相手の消えた接続を約 2 分で切る（`ClientAliveInterval 30`・`ClientAliveCountMax 4`）。
- ops-pc は 60 秒ごとに監視ノードとの最後のハンドシェイクを見て、3 分より古ければ `wg-ops` を張り直す（2026-11-11 に返事がないまま止まり、作り直しで戻った。手元の回線のルーターの NAT の対応が切れたと見ている。確認事項 T5-16）。

## 12. 秘密の値の一覧

| 秘密の値 | 置き場所 | 作り方 | 毎日のバックアップ | 別の保管（段階 5） | 失ったとき |
|---|---|---|---|---|---|
| aka-vecgen の KEK | データ面 `/opt/aka-vecgen/secrets/kek` | 運用ガイド 2 章 | 入れない | ops-pc の `state/` の外、手元で暗号化して保管 | 全加入者の鍵を登録し直す |
| aka-ossbss の KEK（一括投入の待ちのファイル） | 管理面 `/opt/aka-ossbss/secrets/kek` | 同 | 入れない | 同 | 待ちのジョブだけが消える |
| radsec-ca の KEK | 管理面 `/opt/radsec-ca/secrets/kek` | 同 | 入れない | 同 | 全 CA を作り直す（全 AP の証明書の出し直し） |
| Cloudflare Tunnel のトークン | 管理面 `/opt/aka-ossbss/secrets/tunnel-token` | Cloudflare のダッシュボード | 入れない | Cloudflare から取り直せる | 取り直す |
| 管理用 mTLS の鍵（aka-provisioner・aka-ossbss のクライアント証明書、各ノードのサーバー証明書） | 各ノード（`downstreams/`、`certs/`、各 DB と Valkey） | 各運用ガイド | 入る | — | 作り直してピンと登録簿を入れ替える |
| ピンのファイル | 各ノードの `secrets/admin-clients` | 同 | 入る | — | 書き直す |
| Valkey・PostgreSQL のパスワード、RADIUS の共有シークレット | 各 `.env`、aka-radius の Valkey | 同 | 入る | — | 書き直して作り直す |
| WireGuard の秘密鍵 | 各ノード `/etc/wireguard/*.key`、ops-pc の `state/` | `bootstrap.sh` | 入れない | 要らない（作り直して公開鍵を配り直す） | 作り直して `inventory.env` を描き直す |
| SSH の鍵（作業ユーザー、pull） | 手元 `~/.ssh/aka_mvp_ed25519`、ops-pc の `state/` | §3、§11 | — | 手元 | 作り直して各ノードに配り直す |
| KAGOYA のログイン用認証キー、コンソールのパスワード | ユーザーの手元 | コントロールパネル | — | ユーザー | コントロールパネルで作り直す |
| Grafana の admin のパスワード、Slack の webhook | 監視 `/opt/aka-monitor/secrets/` | §9 | 入れない | ユーザー（Slack）| 作り直す |
| 外形監視の IMSI の鍵、AP の鍵 | 監視 `/opt/aka-probe/` | §9.4 | 入れない | — | 登録し直す |

- 本番の保管先と担当は、顧客を収容する前に作り直すときに決める（S5-2・S5-17）。

## 13. VPS を 1 台失ったとき

共通の流れ: 新しいインスタンスを作る（[deployment-console.md](deployment-console.md)）→ `inventory.env` の公開のアドレスを改める → §3 の bootstrap（WireGuard の鍵は新しくなる）→ 公開鍵を貼って全ノードに `files wg nft` を送り直す（つなぐ相手の公開鍵とアドレスが変わるため）→ §5〜§7 → ノードごとに下のとおり戻す。

| 失ったノード | 戻し方 | 失われるもの |
|---|---|---|
| データ面 | KEK を置き、各運用ガイドの戻し方で Valkey（aka-radius・aka-vecgen）を戻す。ファイルの写し（`sources/`、証明書、ピン）を戻す。aka-provisioner の登録簿のフィンガープリントは、証明書を戻せば変わらない。SQN は再同期で戻る（概要 §15） | 最後のバックアップの後の加入者の変更（aka-ossbss の突き合わせが台帳に合わせて直す。鍵は一括投入をし直す）、利用の集計とセッション |
| 管理面 | KEK を置き、aka-ossbss の DB（`restore-db.sh`。戻した後の手順は aka-ossbss の運用ガイド 11 章）、radsec-ca の DB、aka-provisioner のファイル。Tunnel のトークンを置く | 最後のバックアップの後の画面の操作、発行した証明書の記録（エッジにある証明書は動き続ける） |
| エッジ | radsec-edge の運用ガイド 10.8（`data` を戻すか、失ったまま中央から作り直す）。新しい公開のアドレスを DNS の A レコードに書く（ユーザー） | 戻す間、そのエッジの AP はもう 1 台につなぐ |
| 監視 | §9 を置き直す | 監視の 30 日の記録（ログとバックアップは ops-pc にある） |

## 14. エッジを足す

aka-ossbss の運用ガイド 14.3 の順に、本書の手順を当てる。

1. ユーザーがインスタンスを作る（最初の導入の間はエッジのセキュリティグループを付け、テナントを置く前に外す。K1）。
2. `inventory.env` の `EDGES` に `edge-03` を足し、`PUB_edge_03`・`SVC_edge_03`（10.81.0.13）・`OPS_edge_03`（10.82.0.13）を書く。§3 の bootstrap、公開鍵を貼って描き直す。
3. **データ面・管理面・監視にも `files wg nft` を送る**（`wg-svc` と `wg-ops` のピア、nftables の `svc_edges` が増えるため）。続けて新しいエッジに §4〜§8.3。
4. 監視ノードの `prometheus.yml` も描き直したものに置き換わる（`push-host … mon files monitor`）。

エッジの容量（4 GB のエッジ）は、上限 150 テナント（`EDGE_TENANT_CAPACITY`・台帳の容量）のまま、**140 テナントを超えたら次のエッジ（2 台）の準備に入る**（確認事項 T5-25）。段階 5 の試験では、150 テナント・AP の接続 740 本の定常で使用量が約 2.9 GiB と、目安の 2.8 GiB（4 GB の 70%）を少し超えた。1 テナントは約 13 MiB（containerd-shim と radsecproxy）、AP の接続 1 本は約 0.2 MiB で、140 テナントなら AP 740 本でも約 2.77 GiB の見込み。テナントの作成と配置はシステム管理者と運用担当だけが行うが、AP は顧客（テナント管理者）も足せるので、使用量を監視の `EdgeMemoryHigh`（§9.2）で見る。出たら、そのエッジに新しいテナントを置かず、次のエッジを用意する。

## 15. 確かめたことと残したこと

- 5-1（検証機のリハーサル。`verify/deploy-rehearsal/README.md`）: 描き出し、nftables の文法、WireGuard の 2 本の網（wireguard-go）、規則の許すものと断るもの、監視ノードを踏み台にした SSH、`pull` の rrsync、ops-pc の取得、監視の compose と警告の規則、Slack への通知の形（偽の受け口）。
- 5-1 では確かめていないもの（5-3〜5-6 で VPS の上で確かめる）: systemd の単位の実際の起動の順、docker-ce の導入、各ノードの導入（段階 4 までと同じ運用ガイド）、KAGOYA のセキュリティグループが外向きの通信への応答を通すか（K2。ポートの範囲は書けないとユーザーが確かめた）、インターネット越しの AP と実際の送信元のアドレス、外形監視、Slack の本物の webhook。
