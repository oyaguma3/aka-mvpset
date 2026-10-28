# 段階 2 の終わりの通し（aka-vecgen と aka-radius）

段階 2（データ面）の終わりに、検証機で aka-vecgen と aka-radius を組み合わせて通した道具と結果です。要件と構成の概要 §18.5 の H7、aka-radius の設計概要 §17.1 の 2-6（確認事項 M7）によります。

## 作り

```
eapaka_test（ホスト。AP の役）
   │ UDP 127.0.0.1:11812 / 21812
   ▼
edge-t42 / edge-t7（radsecproxy 1.11.2。エッジの代わり。テナントの刻印 32473/1 を "42" / "7" で付ける）
   │ UDP（compose のネットワーク。送信元 172.30.250.42 / .7）
   ▼
aka-radius の auth・acct ──mTLS（共有ネットワーク aka-av）──▶ aka-vecgen
   ▲
   │ UDP（エッジを通さない直の経路）
ap（radclient。Accounting と、刻印のない要求の試し。172.30.250.100）
```

- radsecproxy は、今のエッジのイメージと同じ Debian 13 のパッケージ（1.11.2）を使います。UDP で受けて UDP で送るので、PartialChain のパッチ（TLS の受け口のためのもの。`verify/r10`）は使いません。刻印の付け方（client ブロックの `rewriteIn` と `addVendorAttribute`）は本物のエッジと同じです（`verify/r10` の V 群）。
- radsecproxy は `rewrite` のブロックを、それを使う `client` のブロックより前に書かないと起動しません。また、上流の名前を起動のときに IP に引いたまま使うので、この試しでは auth と acct の IP を決めています（`compose.radius.yaml`）。
- eapaka_test は刻印を付けられず、Accounting も送らないので、Accounting と刻印のない要求は radclient（`ap` のコンテナ）で送ります。

| ファイル | 内容 |
|---|---|
| `Dockerfile` | 道具のイメージ `stage2-tools:dev`（radsecproxy と freeradius-utils の radclient） |
| `edge-t42.conf`・`edge-t7.conf` | エッジの代わりの radsecproxy の設定 |
| `compose.radius.yaml` | aka-radius の compose に重ねる設定（エッジの代わり、AP の役、決まった IP） |
| `compose.vecgen.yaml` | aka-vecgen の compose に重ねる設定（送ったイメージを使う） |
| `stage2.sh` | 準備から全部の場面までを流し、結果の表を出す |

## 配置

検証機の `~/aka-work/stage2/` に、次のように置きます。

```
stage2/
├── vecgen/      aka-vecgen の compose.yaml・compose.fluent-bit.yaml・.env.example
├── radius/      aka-radius の deployments/・configs/・scripts/
└── tools/       このディレクトリのファイルと、CGO_ENABLED=0 でビルドした eapaka_test
```

検証機には Go がないので、イメージは手元でビルドして送ります。

```bash
docker build -t aka-radius:dev ~/projects/aka-radius
```

```bash
docker build -t aka-vecgen:stage2 ~/projects/aka-vecgen
```

```bash
docker build -t stage2-tools:dev ~/projects/aka-mvpset/verify/stage2
```

```bash
docker save aka-radius:dev aka-vecgen:stage2 stage2-tools:dev | gzip -1 | ssh simwifi 'docker load'
```

動かし方（10 分ほど。結果は `~/aka-work/stage2/results.tsv` と `run.log` の終わりの表）:

```bash
ssh -f simwifi 'cd ~/aka-work/stage2/tools && nohup ./stage2.sh > ../run.log 2>&1 < /dev/null &'
```

compose のプロジェクト名は `s2vecgen`・`s2radius` です（手元で試すときに、既存のボリュームを使わないため）。`sudo` のない手元でも動きます（UID 65532 に読ませるファイルを、試しの間だけだれでも読めるようにします）。

片付け:

```bash
ssh simwifi 'cd ~/aka-work/stage2/radius/deployments && docker compose -p s2radius -f docker-compose.yml -f docker-compose.aka-av.yml -f ../../tools/compose.radius.yaml down -v; cd ~/aka-work/stage2/vecgen && docker compose -p s2vecgen -f compose.yaml -f compose.fluent-bit.yaml -f ../tools/compose.vecgen.yaml down -v; sudo rm -rf ~/aka-work/stage2; docker image prune -af; docker builder prune -af'
```

## 場面

| 群 | 内容 |
|---|---|
| E | EAP-AKA・EAP-AKA' の成功（Accept の Class・VLAN・Session-Timeout）、両方の再同期 |
| R | 拒否: inactive、terminated、aka-radius にいない加入者（取得先を呼ばない）、aka-vecgen にいない加入者（取得先が断る）、別のテナントのエッジ、刻印のない要求、刻印を信頼しないクライアント |
| A | Accounting（Start・同じ値の Interim の再送を含む Interim・Stop。Gigawords）と、利用の集計・セッション |
| O | 運用: `/sources` と aka-vecgen の登録の突き合わせ、`sources check`、`SIGHUP`、遮断器（開く・半開き・閉じる）、続けて 20 回、再起動、バックアップと戻し、Fluent Bit、監査ログのファイル、healthcheck |

## 結果

2026-10-29 に検証機（simwifi。Debian 13、Docker 29.8.2、N100・16 GB）で 29 項目すべてが通った（`results/results.tsv`、`results/run.log`）。

| 使ったもの | 版 |
|---|---|
| aka-radius | `feature/stage2-6-ops`（develop `289ee5b` に段階 2-6 の小さな直しを足したもの） |
| aka-vecgen | main `2d48379` |
| radsecproxy | 1.11.2-1+deb13u1（Debian 13） |
| eapaka_test | `b3f8f25` |
| Valkey・Fluent Bit | 9.1.2・4.2.8 |

- 続けて 20 回の EAP-AKA は計 333 ms（eapaka_test の起動を含めて 1 回約 17 ms）。
- 遮断器は、aka-vecgen を止めて 5 回で開き、起こしてから 30 秒ほどで半開きになった。`/status` の報告は auth の 30 秒ごとの報告の分だけ遅れる（O5 の秒数は、aka-vecgen を起こしてから `/status` が半開きを示すまで待った時間）。
- 手元の下見で見つけて直したもの: radsecproxy の設定の順（`rewrite` を `client` より前）、radsecproxy が上流の IP を引いたまま使うこと（auth と acct の IP を決めた）、Valkey のバックアップと戻しのスクリプトが素の `docker compose` で別のプロジェクトを相手にしうること（動いている valkey がなければ何もしない守りを足した。aka-radius の `scripts/`）、`admin-cert create` を Valkey の起動の前に動かすと監査ログを残さなかったこと（日ごとのファイルにだけ書くようにした）。
