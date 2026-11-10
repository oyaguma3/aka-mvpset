# 配置のユーザーの作業（KAGOYA・DNS・Slack）

- 状態: 段階 5 の手順 5-1 で書いた（2026-11-05）。KAGOYA のコントロールパネルの画面は 2026-11 のマニュアルによる。画面の名前が違えば、近いものを選んで Claude に知らせる。
- 位置づけ: 配置の手順書 [deployment.md](deployment.md) のうち、事業者の契約者（ユーザー）が行う作業（概要 §18.11 の S5-5）。それ以外は Claude が SSH で行う。
- 手元は Windows の WSL を想定する。コマンドは WSL の端末で動かす。

## 0. 流れ

| 順 | 作業 | 時期 |
|---|---|---|
| 1 | ログイン用認証キーを作り、WSL に置く（§1） | 契約のとき |
| 2 | セキュリティグループを 4 つ作る（§2）。ポートの範囲を書けるかを確かめる | 契約のとき |
| 3 | インスタンスを 5 台作り、公開のアドレスを Claude に渡す（§3） | 契約のとき |
| 4 | 最初の導入が終わったら、セキュリティグループの SSH（22 番）を消す（§3.3） | Claude から声がかかったとき |
| 5 | DNS のレコードを登録する（§4） | テナントを置くとき |
| 6 | Slack の webhook を作る（§5） | 監視を置くとき |
| 7 | 使い終わったらインスタンスを消す（§6） | 段階 5・6 の後 |

## 1. ログイン用認証キー

KAGOYA は自分の公開鍵を登録する形ではなく、コントロールパネルで鍵を作ってダウンロードする（Debian 13 ではユーザー `debian` で入る鍵。sudo はパスワードなし）。この鍵は最初の導入で 1 回だけ使い、その後は `debian` でも root でも入れなくなる。

1. コントロールパネルで「KVM」→「セキュリティ」→「ログイン用認証キー」→ 追加。キーの名前は `aka-mvp`。
2. 秘密鍵（`aka-mvp.key`）のダウンロードは**作ったときの 1 回だけ**。保存する。
3. WSL に置く（ダウンロードの場所は Windows のユーザーの名前に置き換える）。

   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   ```

   ```bash
   mv /mnt/c/Users/<Windows のユーザー>/Downloads/aka-mvp.key ~/.ssh/kagoya-aka-mvp.key && chmod 600 ~/.ssh/kagoya-aka-mvp.key
   ```

## 2. セキュリティグループ

コントロールパネルで「KVM」→「セキュリティ」→「セキュリティグループ」から 4 つ作る。行ごとに TCP か UDP、宛先ポート（**1 つだけ。範囲は書けない**）、送信元を書く。外向き・内向きを分ける設定はなく、書いたもの以外は断られる。ホストの中でも nftables で絞るので、ここは粗くてよい（2026-11 にユーザーが作って確かめた）。

先に、手元の回線の公開のアドレスを調べる（SSH の 22 番を絞るため）。

```bash
curl -s https://1.1.1.1/cdn-cgi/trace | grep '^ip='
```

| セキュリティグループ | プロトコル | 宛先ポート | 送信元 | 用途 |
|---|---|---|---|---|
| `aka-data` | UDP | 51820 | `*` | サービス用の WireGuard |
| | UDP | 51821 | `*` | 運用用の WireGuard |
| | TCP | 22 | 手元の回線のアドレス | 最初の導入の間だけ |
| `aka-mgmt` | （`aka-data` と同じ 3 行） | | | |
| `aka-edge` | UDP | 51820 | `*` | サービス用の WireGuard |
| | UDP | 51821 | `*` | 運用用の WireGuard |
| | TCP | 22 | 手元の回線のアドレス | 最初の導入の間だけ |
| `aka-mon` | UDP | 51821 | `*` | 運用用の WireGuard |
| | TCP | 22 | 手元の回線のアドレス | 最初の導入の間だけ |

- **エッジのテナントのポート（TCP 20000〜21999）は書かない**。範囲を書けず、テナントを置くたびに 1 行ずつ足すことになるため。エッジはテナントを置く前にセキュリティグループを外し、ホストの nftables だけで守る（§3.3。確認事項 K1）。エッジは加入者の鍵を持たないノードである。
- 外向きの通信への応答（apt、Docker のイメージ、WireGuard の返事）が通るかは、インスタンスを作った後に Claude が最初に確かめる。断られていたら、全ノードからセキュリティグループを外し、ホストの nftables だけで守る（§3.3。確認事項 K2）。

## 3. インスタンス

### 3.1 作る

「KVM」→「インスタンス」→ 作成で、5 台を作る。

| 名前 | プラン | OS | セキュリティグループ |
|---|---|---|---|
| `aka-data` | 4GB（4 コア・600 GB） | Debian 13 | `aka-data` |
| `aka-mgmt` | 4GB | Debian 13 | `aka-mgmt` |
| `aka-edge-01` | 4GB | Debian 13 | `aka-edge` |
| `aka-edge-02` | 4GB | Debian 13 | `aka-edge` |
| `aka-mon` | 2GB（2 コア・200 GB） | Debian 13 | `aka-mon` |

- ログイン用認証キーは `aka-mvp`。
- **コンソールログインパスワード**を決めて控える（SSH で入れなくなったときに、コントロールパネルのコンソールから root で入るためのもの。Claude には渡さない）。
- 料金は日割り（4GB は日額 63 円で月額の上限 1,760 円、2GB は日額 28 円で上限 770 円。2026-11-04 の料金）。

### 3.2 Claude に渡すもの

チャットに次を書く。

- 5 台の公開の IPv4 アドレス（インスタンスの一覧に出る）。
- 手元の回線の公開のアドレス（§2 で調べたもの）。
- 鍵のファイルの置き場所（`~/.ssh/kagoya-aka-mvp.key`）。

Claude が手元から次のコマンドで入れることを確かめてから、導入を始める（`aka-data` の例）。

```bash
ssh -i ~/.ssh/kagoya-aka-mvp.key debian@<aka-data の公開のアドレス> 'cat /etc/debian_version'
```

### 3.3 最初の導入の後

Claude から声がかかったら、次を行う。

- 「SSH を閉じてよい」: 4 つのセキュリティグループから TCP 22 の行を消す。以後の SSH は運用用の WireGuard を通る。
- 「エッジからセキュリティグループを外して」（テナントを置く前）: `aka-edge-01`・`aka-edge-02` のインスタンスの編集（歯車）で、セキュリティグループを外す（K1）。
- 「全ノードからセキュリティグループを外して」（K2 で外向きの通信への応答が断られていたときだけ）: 5 台とも外す。

外すと事業者の側では全部の通信が通るので、ホストの nftables が守りになる。nftables をいったん外す（§3.4）ときは、先に Claude と相談する。

### 3.4 SSH で入れなくなったとき

コントロールパネルの「KVM」→「インスタンス」→ 対象 →「コンソール」→「コンソールを起動」で、root とコンソールログインパスワードで入る（ブラウザのポップアップを許す）。Claude の指示でコマンドを打つ（例: `nft delete table inet aka` で nftables の規則をいったん外す）。

## 4. DNS のレコード

テナントを置くとき（[deployment.md](deployment.md) §8.4）、Claude が aka-ossbss の画面に出る表（名前と向け先）を渡すので、Cloudflare の DNS（検証用のサブドメインの下）に登録する。段階 4 と同じ形（エッジの名前は A レコード、スロットの名前はそこへの CNAME。どれも DNS only の灰色の雲、TTL 60 秒）。

## 5. Slack の webhook

Alertmanager の通知の送り先（S5-11）。本件用のワークスペースで行う。

2026-11 の作成の画面は 4 段の案内つき（Slack の公式の手順書の「Incoming Webhooks を On にして Add New Webhook to Workspace」とは違う。2026-11-09 にユーザーがたどった順）。

1. 通知のチャンネルを先に作る（例 `#aka-mvpset`）。
2. <https://api.slack.com/apps> で「Create New App」。名前は `aka-alerts`、ワークスペースは本件のもの。
3. スコープを選ぶ段で、Bot のスコープに `incoming-webhook` だけを足す。イベント（bot events・workspace events）の段では何も足さずに進む（Alertmanager は Slack から何も受け取らない）。
4. 「Review your app」（Step 4 of 4）で「Create and Install」。
5. 「Slack へのアクセスを aka-alerts に許可する」の画面で、ワークスペースと「Webhook 用のチャンネル」（1 のチャンネル）を選んで「許可する」。
6. 「aka-alerts is ready!」の画面に Bot token（`xoxb-…`）と App token（`xapp-…`）が出るが、**使わないので写さない**（Agent prompt・CLI commands も使わない）。「Go to App Settings」。
7. アプリの設定の画面の左の「Features」→「Incoming Webhooks」の「Webhook URLs for Your Workspace」に URL（`https://hooks.slack.com/services/…`）が出る。「Copy」で写す。
8. URL を**チャットに貼らずに**、手元のファイルに書く（Claude が監視ノードに置く）。

   ```bash
   (umask 077; read -rs -p 'Webhook URL: ' u; printf '%s\n' "$u" > ~/.aka-slack-webhook)
   ```

URL を知っている人は誰でもそのチャンネルに書けるので、漏れたら Slack のアプリの画面で作り直す。

作成の案内が作る App token（`xapp-…`。「Basic Information」の「App-Level Tokens」）と Bot token は通知に使わない。要らなければ「App-Level Tokens」で取り消してよい（Webhook の URL はそのまま使える）。

## 6. 使い終わったら

段階 5・6 の環境は、顧客を収容する前に作り直す（S5-2）。消すときは Claude が中身を ops-pc に取ってから、インスタンス 5 台を削除する（日割りの料金が止まる）。ログイン用認証キーとセキュリティグループは作り直しのときに使い回せる。
