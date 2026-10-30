# 段階 3 の終わりの通し（4 ノードと Cloudflare）

段階 3（管理面）の終わりに、検証機で aka-vecgen・aka-radius・aka-provisioner・aka-ossbss を組み合わせ、Cloudflare Access と Tunnel を通して確かめた道具と結果です。要件と構成の概要 §18.7 の Q8 によります。

## 作り

```
ブラウザー（手元の playwright-cli）─Cloudflare Access─Tunnel─> cloudflared ─> aka-ossbss ── PostgreSQL
                                                                                  │ mTLS（aka-provisioner）
                                                                                  ▼
                                                                          aka-provisioner ── Valkey
                                                                            │ mTLS（共有ネットワーク）
                                     ┌──────────────────────────────────────┴───┐
                                     ▼                                          ▼
eapaka_test ─UDP─> edge-t1 / edge-t2 ─刻印─> aka-radius（auth・acct・admin）─mTLS─> aka-vecgen
radclient ───UDP─┘
```

- 各ノードは運用ガイドのとおりに導入します。`.env` の `COMPOSE_PROJECT_NAME`・`COMPOSE_FILE` を使い、ガイドと同じ素の `docker compose` で動かし、`sudo chown 65532` も本物で行います。イメージだけは手元でビルドして送ります（`up --no-build`）。
- 本番では下流は別の VPS で、WireGuard を通します。ここでは同じホストなので、各ノードの共有ネットワークの重ね合わせでつなぎます。WireGuard の配置は段階 5 です。
- エッジの代わりは `verify/stage2` と同じ radsecproxy（`stage2-tools:dev`）で、刻印の値は aka-ossbss のテナントの ID（1・2）です。
- 製品に試し用の口は足していません。ずれは下流の管理API を直接呼んで作り、課金の月は試しの DB を SQL で固定の過去の月（2026-09）に動かします。

| ファイル | 内容 |
|---|---|
| `drive.sh` | 手元の台本。段（下の表）ごとに検証機と画面を動かす |
| `stage3.sh` | 検証機の側の部品（導入、EAP、Accounting、ずれの作成、月の移動、ログの確かめ） |
| `ui/*.js` | 画面の台本（playwright-cli の `run-code`） |
| `compose.radius.yaml`・`edge-t1.conf`・`edge-t2.conf` | aka-radius に重ねるエッジの代わりと AP の役 |
| `refs.env` | 通した組み合わせ |
| `results/` | 結果 |

**公開のリポジトリなので、ドメイン・AUD・メールアドレスはここに書きません。** 手元の `site.env`（`BASE`、`OSSBSS_ACCESS_TEAM_DOMAIN`、`OSSBSS_ACCESS_AUD`、`ADMIN_EMAIL`、`TOKEN_FILE`）から読みます。結果にも書きません。

## 動かし方

前提は、Cloudflare の Tunnel と Access のアプリがあり、公開ホスト名の向け先が `http://aka-ossbss:8446` であること、検証機にトークンのファイルがあることです。

```bash
export SITE=<site.env のパス> WORK=<手元の作業ディレクトリ>
```

| 段 | 内容 |
|---|---|
| `prepare` | 固定のコミットからイメージをビルドして送り、compose のファイルを置く |
| `setup` | 4 ノードの導入と Tunnel の確立（I、C0〜C3） |
| `login-start` | ブラウザーで Access のログイン画面を開く。メールアドレスと PIN は人が渡す（`playwright-cli -s=stage3` の `fill`・`click`） |
| `u` | 画面からテナント、アカウント、個別の登録、認可ポリシー（U） |
| `e` | 認証、状態による拒否、Accounting、セッション（E、A） |
| `b` | 一括投入 1 万件を両側に同時に、投入し直し、自動の中断（B） |
| `k` | 突き合わせの自動の修正、保留と承認、台帳にない IMSI（K） |
| `m` | 公開鍵、取り込み、締め、ダウンロードと `verify/charging/verify-file.py`、作り直し（M） |
| `o` | ログ、監査ログ、止めたときの文、結果が分からない操作、戻し（O） |
| `c` | 役割、無効のアカウント、AUD と公開鍵の誤り（C4〜C13） |
| `end` | ログアウト（C10）と結果の表。この後は PIN がないとログインできないので、最後に動かす |
| `teardown` | 検証機の片付け（トークンのファイルは残す） |

## 結果（2026-10-31）

組み合わせは aka-vecgen `2d48379`・aka-radius `0050687`・aka-provisioner `9a5f4b0`・aka-ossbss `7082332`。検証機は N100・16 GB。**81 / 81 PASS**（`results/results.tsv`）。

| 場面 | 確かめたこと |
|---|---|
| I | ガイドのとおりの導入、`sources check`、`check-downstream`、`check-provisioner`、全部のコンテナの healthy、ポートを公開しないこと、権限 |
| C | Tunnel の接続 4 本、未ログインは Access へ、JWT なしの直接の要求は 401、最初のログイン、役割 A・C の見え方、無効のアカウントの 403、AUD の誤りの 401、公開鍵を取れないときの 503、接続元のアドレス、ログアウト |
| U・E・A | 画面で登録した加入者の EAP-AKA・EAP-AKA'・再同期、別のテナントのエッジと SSID の違いの拒否、画面で止めたときの両側の拒否、Accounting とセッションの画面、利用の集計 |
| B | 1 万件の投入と時間、投入された加入者の認証、投入し直し、下流を止めたときの自動の中断、残りだけの処理 |
| K | 自動の修正、1,001 件の保留と承認、台帳にない IMSI の取り込みと下流からの削除 |
| M | Cloudflare 越しのダウンロード、`verify-file.py`、行の値が手の計算と合うこと、作り直しで版が上がること、監査ログ |
| O | トレースID で全ノードをたどること、Fluent Bit と監査ログのファイル、鍵がログに出ないこと、DB・aka-provisioner・下流が止まったときの文、結果が分からない操作の印と直り方、Valkey と DB の戻し、締めより前に戻すと同じ通し番号のファイルができること（aka-ossbss の運用ガイド 11.2） |

| 計測 | 結果 |
|---|---|
| 一括投入 1 万件を両側に同時に | vecgen 側 68 秒、radius 側 65 秒（目標は 30 分。Cloudflare を通るのはアップロードと確認の操作だけ） |
| 投入し直し 1 万件（全部既にある） | 4 秒 |
| 突き合わせ（台帳 約 1.3 万件） | 0.4〜0.6 秒。1,001 件を直す承認の実行は 7.3 秒 |
| 締め（13,004 行、事実 24,020 件） | 時間は測っていない（画面の操作の待ちの数秒の中で終わった）。DB は全体で 35 MB |
| 一括投入中のメモリー | aka-ossbss 34 MiB、PostgreSQL 83 MiB、aka-provisioner 23 MiB、aka-vecgen 22 MiB、aka-radius admin 13 MiB（`results/stats-bulk.txt`） |

20 万件の規模の試験と容量は段階 6 です。

### 試して分かったこと

- 台本の誤りを直してやり直した項目があります。製品の不具合ではありませんでした。
  - radius 側の登録と一括投入では、取得先を選ぶ必要があります（既定で選ばれません）。
  - 利用の集計の取り込みは前の日までを読むので、今日の Accounting は翌日まで取り込まれません（設計どおり）。試しでは Valkey のキーを昨日に移しました。
  - SQL で過去の月に動かすと、取り込みの記録がないので `usage_complete` が全部 `false` になります（設計どおり）。試しでは 9 月の `usage_import_days` を足しました。
  - PostgreSQL の真偽値は、文字列につなぐと `false`、そのまま出すと `f` です。
- 1 つのブラウザーで 1 つのメールアドレスのまま、SQL でアカウントの役割を変えて確かめられます（aka-ossbss は要求のたびにアカウントを引くので、起動し直しは要りません）。
- ワンタイム PIN は 10 分で切れます。切れたときは画面の「Request New Code」で出し直せます。
- 手元の台本は検証機で直接通しました（aka-ossbss は Cloudflare Access がないと compose で動かせないので、手元では同じ形で試せません）。

### 見つけた食い違い（直した）

- 実行中の自動の中断と手動の中断、待ちのジョブの中断で、ログに `JOB_INTERRUPTED` が出ていませんでした（`job finished` の INFO だけ）。aka-ossbss の運用ガイドの 6.3・10.2 には出ると書いてあり、監視で拾えませんでした。aka-ossbss `6b8d6ee` で直しました（確認事項 W1）。ログの出し方だけの変更なので、通しはやり直さず、単体の試験と CI で確かめました。
