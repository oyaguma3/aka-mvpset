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
| `charging-copy.sh` | 課金の締めを、本番から切り離した写しで測る（管理面のノードで動かす。今の月のデータを先月にずらして締める） |
| `results/` | 段階 6-3 の結果（下の「結果」） |
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
| 2 | `radsec`、`lg-keys`、`aps`、`radsec-apply`、`certs`、`applied` | 19 テナントの RadSec と配置、AP 1,000 台の鍵と CSR（一時の VPS）、AP の登録、「反映する」（配置の後に足した AP は自動では反映されない。OB1）、証明書と aps.json、反映を待つ |
| 2 | `lg-push`、`serve 10`、`ctl …`、`stop` | 道具を送り、AP 10 台で小さく試す（L6-7。エッジ固有のこと） |
| 2〜3 | `scheduled` | その夜の毎日の処理（バックアップ、利用の取り込み、突き合わせ）の時間（⑥） |
| 3 | （ユーザー） | 一時の VPS のセキュリティグループを外す |
| 3 | `measure-start`、`serve`、`ctl '/sessions?tenant=sc0001&n=20000&tps=50' POST` | 測定を始め、AP 1,000 本をつなぎ、セッション 2 万を作る |
| 3 | `ctl '/load?tps=50&label=p2' POST`、`jobs extra` | ② 50 TPS を 30 分、その間に ③ sc0020 の vecgen 側 1 万件 |
| 3 | `ctl '/load?tps=10&label=p5' POST`、`ui-timing` | ⑤ 10 TPS を流しながら画面の応答を 20 回ずつ |
| 3 | `ctl '/load?tps=100&label=p4-100' POST` … 150・200 | ④ 5 分ずつ |
| 3 | `stop stop_sessions`、`measure-stop`、`prom <始め> <終わり>` | 止めて記録を写す（Prometheus から 30 秒ごとの数） |
| 3 | `lg-clean`、（ユーザー） | 一時の VPS の鍵・種を消し、ユーザーが VPS とセキュリティグループを消す |
| 翌朝 | `scheduled`、`charging-copy.sh` | その夜の毎日の処理（⑥）と、課金の締めを写しで測る（下の手順） |

- 測定の間だけ、aka-vecgen の Valkey の遅れの記録（`latency-monitor-threshold`）を 5 ms にする（`measure-start`。`CONFIG SET` なので再起動で消え、`measure-stop` が 0 に戻す）。
- 規模のデータ（テナント・加入者・RadSec・AP）は顧客を収容する前の作り直しまで残す（S6-6）。
- 結果は `$WORK` に残し、アドレス・ドメイン・メールを伏せてから `results/` に写す。

課金の締めを写しで測る（`charging-copy.sh`。3:00 の取り込みの後に。試験用の PGP 鍵は手元で暗号化の副鍵つきで作る）:

```bash
S="ssh -F ~/aka-deploy/ssh_config aka-mgmt"
$S 'cat > /var/tmp/aka-chg.sh && chmod 700 /var/tmp/aka-chg.sh' < verify/scale/charging-copy.sh
$S "/var/tmp/aka-chg.sh setup '<システム管理者のメール>'"   # 本番の DB の写しを一時の postgres に戻す
$S '/var/tmp/aka-chg.sh shift; /var/tmp/aka-chg.sh start'
$S '/var/tmp/aka-chg.sh key' < <公開鍵.asc>
$S '/var/tmp/aka-chg.sh stats-start; /var/tmp/aka-chg.sh close; /var/tmp/aka-chg.sh wait; /var/tmp/aka-chg.sh stats-stop; /var/tmp/aka-chg.sh report'
$S '/var/tmp/aka-chg.sh get 1' > charging.zip.pgp && GNUPGHOME=<鍵束> python3 -I verify/charging/verify-file.py charging.zip.pgp
$S '/var/tmp/aka-chg.sh clean; rm /var/tmp/aka-chg.sh'
```

## 結果（段階 6-3。2026-11-15〜17、KAGOYA CLOUD VPS の 5 台と一時の VPS）

すべての判定を満たした。詳しくは `results/`（`frame2.txt`・`frame2-jobs.txt`、`frame3.md` と生の記録 `frame3-*.json(l)`、`daily.txt`、`restore.txt`、`charging-close.txt`）。

| # | 項目 | 結果 |
|---|---|---|
| ① | 一括投入（1 本 1 万件が 30 分以内） | 40 本すべて成功、1 本 15〜21 秒。**PASS** |
| ② | 認証 50 TPS を 30 分（AP 1,000 本、EAP-AKA と AKA' を半々、セッション 2 万の Interim つき） | 90,053 件すべて Accept、p95 8.6 ms・p99 11.0 ms、エッジの使用量 1.3 GiB 以下、警告 0。**PASS** |
| ③ | ② の間に 1 万件の一括投入 | 15 秒で全件成功。重なった 10 秒だけ最大 234 ms。**PASS** |
| ④ | 100・150・200 TPS を 5 分ずつ | すべて Accept、p99 9.1・9.3・8.5 ms。200 TPS でデータ面の CPU は 4 コアの約 22% |
| ⑤ | 10 TPS を流しながら画面（20 回ずつ、p95 が 3 秒以内） | p95 82〜155 ms（一覧の 1 回目だけ 5.2 秒）。セッションの一覧（2 万件）は p95 82 ms。**PASS** |
| ⑥ | 毎日の処理 | バックアップ 5 台で最長 5 秒、利用の取り込み 3.3 秒（14 万行）、突き合わせ 9.1 秒（21 万件、ずれ 0）。課金の締めは写しで 40.6 秒（回線 21 万、テナント 1,150、ファイル 4.3 MB） |
| ⑦ | データ面をバックアップから戻す | Valkey のボリュームを消してから戻すまで 46 秒、外形監視は失敗せず、突き合わせのずれ 0 |

- 見つけて直したこと: Valkey のバックアップが前のスナップショットを写していた（確認事項 B6-1。aka-vecgen・aka-radius・aka-provisioner の `scripts/backup-valkey.sh`）。直した後、11-17 の 2:30 の写しがその時のスナップショットであることを確かめた。
- 台本の直し: 一時の VPS のカーネルが `apt-get upgrade` で上がらない、段 `radsec-apply`（配置の後に足した AP は自動では反映されない）、`ctl` の表示。
- 遅延の外れ（約 235 ms が 318 窓のうち 7 窓）は TCP の再送待ち（エッジのコンテナの中の `TCPTimeouts`）で、一時の VPS とエッジの間でときどきパケットが落ちた見込み。
- 規模のデータ（テナント 1,000、加入者 21 万、RadSec 19 テナント・AP 1,000・配置 38）は顧客を収容する前の作り直しまで残す。試験用の PGP 公開鍵を本番に登録したので、12-01 6:00 の本番の締めのファイルを手元で開いて確かめる。
