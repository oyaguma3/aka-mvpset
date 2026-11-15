# verify/scale — 段階 6 の規模の試験の道具と台本

要件と構成の概要 §16.1・§18.13 の S6-3〜S6-6 の規模の試験（加入者 20 万、テナント 1,000、AP 1,000、セッション 2 万、ピーク 50 TPS）を行う道具と台本。確認事項 L6-1〜L6-9（段階 6-2）。実施は段階 6-3（VPS の 5 台と一時の VPS）。

| ファイル | 内容 |
|---|---|
| `scaleload`（`*.go`） | 負荷の道具。AP ごとに RadSec（TLS と AP ごとの証明書）の接続を保ち、EAP-AKA・EAP-AKA' を最後まで通し、Accounting を送り、毎秒の件数を決めて遅延の分布を記録する |
| `scale.py` | 手元の補助。計画（テナント・IMSI の範囲・ジョブ・配置）の正と、画面の要求の組み立て、結果のまとめ |
| `drive.sh` | 手元から進める台本（段は下の表） |
| `ui/upload.js`・`ui/timing.js` | 画面の台本（一括投入の登録と確定、画面の応答の時間）。テナント・RadSec・AP の要求は段階 5 の `verify/stage5/ui/bulk.js` を使う |
| `measure.py` | データ面で 10 秒ごとに Valkey とコンテナの様子を取る |
| `loadgen-setup.sh` | 一時の VPS（aka-loadgen）を整える |
| `lab/` | 道具の手元の通し（aka-vecgen・aka-radius と、エッジの代わりの radsecproxy を手元の Docker に立てる） |

## scaleload

```bash
cd verify/scale && CGO_ENABLED=0 go build -trimpath -o scaleload .
scaleload csv -seed seed.bin -kind vecgen -from 1 -to 10000 > vecgen.csv   # 一括投入の CSV
scaleload serve -aps aps.json -seed seed.bin -out out                     # AP をつないで操作の口（127.0.0.1:9900）で待つ
curl -X POST '127.0.0.1:9900/sessions?tenant=sc0001&n=20000&tps=50'       # セッションを作る（認証と Accounting-Start、10 分ごとに Interim）
curl -X POST '127.0.0.1:9900/load?tps=50&label=p2'                        # 毎秒 50 の認証（tps=0 で止める）
curl 127.0.0.1:9900/status                                                # 今の状態と場面ごとのまとめ
curl -X POST '127.0.0.1:9900/stop?stop_sessions=1&tps=100'                # 止める（Accounting-Stop を送ってから）
scaleload report out                                                      # まとめの表
```

- **加入者と鍵**: IMSI は `4401080` に 8 桁の番号（1〜200,000 と、③ の 200,001〜210,000）。Ki・OPc は種（32 バイトの乱数のファイル）から IMSI ごとに HMAC-SHA256 で決めるので、CSV と道具が同じ値を作れる（L6-3）。種は手元（`$WORK/seed.bin`、600）と一時の VPS だけに置き、試験の後に一時の VPS から消し、手元は gpg で暗号化して作り直しまで残す。
- **端末側**: eapaka_test（`v0.2.0` = `versions.env` の `EAPAKA_TEST_REF`）の `eap`・`eapmethod/aka` を使う（中で go-eapaka）。Identity の頭が `0` なら EAP-AKA、`6` なら EAP-AKA'（交互）。SQN は鍵付きのメモリーに覚え、同じ IMSI を同時に使わない。
- **RadSec**: 共有の秘密 `radsec`。IP でつなぐので名前は照らさず、テナントのサーバー CA で鎖を確かめる。1 本の接続で Identifier ごとに多重にやり取りし、時間切れになった Identifier は 30 秒使わない（遅れた応答が次の要求に紛れないように）。AP は自分のテナントの primary のエッジだけにつなぎ、切れたら 1〜30 秒おいて張り直す（張る数は `-dial-rate` で 1 秒あたりに絞る）。
- **属性**: NAS-Identifier は `<slug>-<AP の名前>`（エッジも同じ値に書き換える）、Called-Station-Id は `<AP の MAC>:scale`（SSID `scale`）、Calling-Station-Id は IMSI ごとの MAC の形、NAS-Port-Type 19。
- **数え方**: 失敗は Reject・時間切れ（`-timeout`、既定 10 秒）・切断・そのほかの誤り・始められなかった（つながった AP がない、同時の数の上限、空いた IMSI がない）に分ける。場面は認証を始めたときの名前で数える。遅延は Accept までの時間で、場面ごとに全部を覚えて正確な分位を出す。10 秒ごとの窓は `windows.jsonl`、終わりのまとめは `summary.json`。
- **セッション**: aka-radius は Access-Accept のときにセッション（24 時間。Start・Interim で延ばし、Stop で消す）を作る。`/sessions` は指定のテナントの IMSI の頭から認証して Accounting-Start を送り、`-interim`（既定 10 分）ごとに Interim を送る。認証だけの負荷（`/load`）でもセッションは増える（24 時間で消える）。

## 手元の通し（lab）

```bash
export WORK=<消してよい作業場所>
verify/scale/lab/lab.sh up             # aka-vecgen・aka-radius（固定のコミット）とエッジの代わり。イメージは deploy/bin/build-images で作っておく
verify/scale/lab/lab.sh subs 2000      # 加入者 2,000 を両側に（約 25 秒）
verify/scale/lab/lab.sh aps 1000 2000  # AP 1,000 の aps.json
$WORK/scaleload serve -aps $WORK/aps.json -seed $WORK/seed.bin -out $WORK/out -listen 127.0.0.1:19900 -dial-rate 100 -interim 60s
verify/scale/lab/lab.sh logs           # aka-radius・aka-vecgen の WARN・ERROR と event_id
verify/scale/lab/lab.sh down
```

エッジの代わりは本物のエッジと同じイメージ（`radsec-edge/radsecproxy:1.11.4-pc1`）で、1 つの client ブロックで受けて刻印（テナント 42）を付ける（テナントごとの証明書・CRL・送信元の範囲はない）。

結果（2026-11-15、手元の WSL）: AP 100 で毎秒 10・50（3,001 件すべて Accept、p99 30 ms）、セッション 500（Start・Interim 2 回・Stop すべて応答あり）、AP 1,000 本（1 秒に 100 本で張れた）で毎秒 200 を 60 秒（12,003 件すべて Accept、p99 36 ms）。道具は AP 1,000 本でメモリー約 69 MB、毎秒 200 で CPU 約 0.93 コア。aka-radius・aka-vecgen の WARN・ERROR 0。

## 試験の進め方（drive.sh。段階 6-3）

`export WORK=~/aka-deploy/stage6`（`site.env` は段階 5 のものを写す）。一時の VPS は `~/aka-deploy/ssh_config` の先頭に `Host aka-loadgen`（`User debian`、KAGOYA の鍵、`ProxyJump aka-mon`）を足す（段階 5 の T5-23 と同じ。`Include` は `Host *` の中に）。

| 枠 | 段 | 内容 |
|---|---|---|
| 1 | （ユーザー） | 一時の VPS を作る（2 GB、Debian 13、セキュリティグループは監視ノードからの TCP 22 だけ）|
| 1 | `prepare`、`lg-setup` | 種と scaleload、一時の VPS を整える（nftables は 90 秒で戻す仕掛けを止めるまで） |
| 2 | `login-start`・`login-pin <PIN>` | Access にログイン（PIN は 10 分で切れる。セッションは 24 時間） |
| 2 | `tenants` | テナント sc0001〜sc1000（50 件ずつ。やり直すと残りだけ） |
| 2 | `jobs`、`jobs-wait` | 一括投入 40 本を 1 本ずつ登録して確定し、終わるまで待ってジョブごとの時間（① 1 万件が 30 分以内） |
| 2 | `radsec`、`lg-keys`、`aps`、`certs`、`applied` | 19 テナントの RadSec と配置、AP 1,000 台の鍵と CSR（一時の VPS）、AP の登録、証明書と aps.json、反映を待つ |
| 2 | `lg-push`、`serve 10`、`ctl …`、`stop` | 道具を送り、AP 10 台で小さく試す（L6-7。エッジ固有のこと） |
| 2〜3 | `scheduled` | その夜の毎日の処理（バックアップ、利用の取り込み、突き合わせ）の時間（⑥） |
| 3 | （ユーザー） | 一時の VPS のセキュリティグループを外す |
| 3 | `measure-start`、`serve`、`ctl '/sessions?tenant=sc0001&n=20000&tps=50' POST` | 測定を始め、AP 1,000 本をつなぎ、セッション 2 万を作る |
| 3 | `ctl '/load?tps=50&label=p2' POST`、`jobs extra` | ② 50 TPS を 30 分、その間に ③ sc0020 の vecgen 側 1 万件 |
| 3 | `ctl '/load?tps=10&label=p5' POST`、`ui-timing` | ⑤ 10 TPS を流しながら画面の応答を 20 回ずつ |
| 3 | `ctl '/load?tps=100&label=p4-100' POST` … 150・200 | ④ 5 分ずつ |
| 3 | `stop stop_sessions`、`measure-stop`、`prom <始め> <終わり>` | 止めて記録を写す（Prometheus から 30 秒ごとの数） |
| 3 | `lg-clean`、（ユーザー） | 一時の VPS の鍵・種を消し、ユーザーが VPS とセキュリティグループを消す |

- 測定の間だけ、aka-vecgen の Valkey の遅れの記録（`latency-monitor-threshold`）を 5 ms にする（`measure-start`。`CONFIG SET` なので再起動で消え、`measure-stop` が 0 に戻す）。
- 規模のデータ（テナント・加入者・RadSec・AP）は顧客を収容する前の作り直しまで残す（S6-6）。
- 結果は `$WORK` に残し、アドレス・ドメイン・メールを伏せてから `results/` に写す。
