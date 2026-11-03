# 長い時間の試験（エッジ）

要件と構成の概要の決定事項 28、§16.4、§18.9 の S4-11 による試験の道具と結果です。radsec-edge を本物の形で 150 テナント動かし、dockerd などのメモリーが増え続けないかを確かめます。増え続けると、4 GB の VPS で保証した 150 テナント（決定事項 25）が崩れます。

## 作り

検証機（simwifi2。N95・4 コア・11 GB）で次を動かします。ホストの Docker の設定は変えません。

```
AP の役（ap.py。接続 750 本、接続のし直し 毎秒 1 本、RADIUS 10 件/秒）──RadSec──┐
中央の代わり（long.py run。管理API を mTLS で直接呼ぶ）──────────────────────┐ │
                                                                             ▼ ▼
                                      dind（userland-proxy オフ、live-restore オン）
                                        radsec-edge・agent・Fluent Bit（compose の本物の形）
                                        radsecproxy × 150（パッチ版）
                                                │ RADIUS / CRL の取得
                                                ▼
                       上流の代わり（upstream.py。Status-Server と RADIUS に応答、CRL を ETag つきで配る）
```

| ファイル | 内容 |
|---|---|
| `drive.sh` | 手元の台本 |
| `run.sh` | 検証機の側の導入、dockerd の再起動の確かめ、片付け |
| `long.py` | 中央の代わり（PKI の生成、宣言と最初の反映、定期の呼び出し） |
| `upstream.py` | 上流の RADIUS と CRL の配布の口の代わり |
| `ap.py` | AP の役 |
| `sample.sh`・`measure.py` | 10 分ごとの記録 |
| `report.py` | 結果のまとめと判定 |
| `refs.env` | 通した組み合わせ |
| `results/` | 結果（`samples.jsonl` は 10 分ごとの記録、`events.jsonl` は反映と誤り、`restart-1.txt`・`restart.txt` は dockerd の再起動の確かめ、`report.txt` は `report.py` の出力） |

### テナントの形

150 テナント、AP 5 台ずつ。130 は AP だけ、10 は Meraki 形の模型（PartialChain）、10 は Mist 形の模型（CRL なし、CRLCheck off）。**業者の CA は模型で、実物ではありません。**

### 定期の動き

| 動き | 頻度 | 実際との比べ |
|---|---|---|
| `GET /tenants` | 1 分ごと | aka-ossbss のループと同じ |
| `GET /status` | 30 秒ごと | aka-provisioner と同じ |
| 反映（AP の足し引きで版を上げて `PUT` と `apply`。捨てるコンテナも動く） | 1 分に 1 テナント（1 日 1,440 回） | 実際よりかなり多い |
| CRL の更新 | 10 分に 1 テナント（1 日 144 回） | 実際の毎日 1 回 × 150 に近い |
| 整合ループ、全テナントのログの読み出し（`RefreshLastSeen`） | 1 分ごと | エッジ自身の処理 |
| CRL の取得 | 5 分ごと | エッジ自身の処理 |
| AP の接続のし直し | 毎秒 1 本 | 実際より多い |
| RADIUS | 10 件/秒（認証と Accounting が半々） | ピーク 50 TPS の 2 割。認証の中身は通らない（上流は拒否を返す） |

上流を応答させるのは、応答しないと radsecproxy が 1 分に 4 行ほどログを出し、ログの量が実際と変わるためです（`verify/edge-logs`）。

## 合格の基準

エッジの合計（dind の cgroup の anon + kernel）の **6 時間以降の増え方** で判定します。最初の 6 時間は起動直後の増え方として除きます。

| 増え方 | 次の動き |
|---|---|
| 30 MiB/日未満 | 24 時間で終える |
| 30 MiB/日以上 | 72 時間に延ばす |
| 72 時間でも 37 MiB/日（30 日で余裕の 1.1 GiB を使い切る速さ）を超える | `GOMEMLIMIT` などを確認事項にする |

あわせて次を確かめます。

- `memory.current` は 2.3 GiB 以内を目安にする（4 GB の 70% から OS の 300 MiB を引いた値）。
- 反映の失敗 0、API の誤り 0、接続が保たれる、ログの行が欠けない。
- ディスク: 25 GB の VPS に 2 週間分のログが入る（外挿）。
- dockerd の再起動を試験の終わりに 1 回行う（途中だと増え方が元に戻る）。コンテナの起動の時刻が変わらない、接続が続く、agent がつなぎ直す、API と反映が動く、ログが届く。その後 1 時間測る。

## 動かし方

```bash
export WORK=<手元の作業ディレクトリ>
```

| 段 | 内容 |
|---|---|
| `./drive.sh prepare` | `refs.env` のコミットからイメージをビルドして送る（時間がかかる） |
| `SUDO_PW=<…> ./drive.sh inotify 1024` | `fs.inotify.max_user_instances` を上げる（再起動で既定に戻る） |
| `./drive.sh start 150 600` | 導入から自走まで。`nohup` で検証機の上で動き、手元を閉じてよい |
| `./drive.sh status` | 今の状態 |
| `./drive.sh report [始めの時間]` | 結果を手元に写してまとめる（既定は 6 時間以降の増え方） |
| `./drive.sh restart` | dockerd の再起動の確かめ（`run/restart.txt`）。約 7 分 |
| `SUDO_PW=<…> ./drive.sh teardown` | 片付け。`fs.inotify.max_user_instances` を 128 に戻す |

## 測っていないもの

- 本物の VPS（dind でないもの）。決定事項 28 で段階 5 に回しています。
- 中央のノードを通すこと。エッジの API を直接呼びます。
- logrotate。ディスクの増え方から外挿します。

## 準備で見つけたこと

- **radsec-edge の不具合（確認事項 L10。直した）:** 整合ループの途中で宣言した新しいテナントのディレクトリを消していました。ID で引いて確かめていたので、ID と slug が違う管理モードでは必ず「ない」となるためです。150 テナントの最初の反映で 1 件が `could not read config file` で失敗して見つかりました。radsec-edge `42e7386` で直し、再現する試験を足しました。
- **inotify の上限（確認事項 L11）:** `fs.inotify.max_user_instances` の既定 128 では、130 個目あたりのコンテナから dockerd のログに `failed to watch oom events ... too many open files` が出ます（1 回目の 150 テナントで 69 件）。OOM の知らせが届かなくなるだけで、製品は使っていません。radsec-edge の運用ガイド 10.1 に上げる手順を足しました（`5a3a3e1`）。この試験では 1024 にして動かします。
- **dockerd の再起動で agent が Docker につなげなくなる（確認事項 L12。直した）:** 下の「結果」の dockerd の再起動を見てください。
- Docker 29 の dind では、containerd は別のプロセスとして動いていません（dockerd に含まれる形）。`report.py` の containerd の行は 0 です。

## 結果（2026-11-03 01:34〜11-04 03:00）

組み合わせは radsec-edge `5a3a3e1`（L12 の確かめだけ `2a8b62d`）、radsecproxy `1.11.4-pc1`、`docker:29.9.2-dind`、Fluent Bit 4.2.8。検証機は simwifi2（N95・4 コア・11 GB）。`fs.inotify.max_user_instances` は 1024。

**合格: エッジの合計（anon + kernel）の 6〜24 時間の増え方は 15.4 MiB/日**（基準 30 MiB/日未満）。72 時間への延長は要りません。`GOMEMLIMIT` も要りません。

| 項目 | 始め | 6 時間 | 24 時間 | 増え方（6 時間以降、1 日あたり） |
|---|---|---|---|---|
| 合計 anon + kernel | 1,854 MiB | 2,195 MiB | 2,181 MiB | 15.4 MiB |
| dockerd（PSS） | 223 MiB | 232 MiB | 229 MiB | 4.8 MiB |
| containerd-shim × 150（PSS） | 1,056 MiB | 1,264 MiB | 1,231 MiB | −18.2 MiB |
| radsecproxy × 150（PSS） | 334 MiB | 417 MiB | 418 MiB | 1.4 MiB |
| radsec-edge・agent・Fluent Bit（PSS） | 115 MiB | 115 MiB | 116 MiB | ほぼ 0 |
| dockerd の FD | 2,182 | 2,167 | 2,167 | ほぼ 0 |

- 増えたのは始めの 6 時間（反映で radsecproxy のコンテナが作り直され、接続のし直しが続く形に落ち着くまで）で、その後は平らです。25 時間（再起動の後 1 時間を含む）では 1.6 MiB/日でした。
- **`memory.current` は最大 2,876 MiB で、目安の 2,355 MiB（2.3 GiB）を超えました。** 差はファイルのキャッシュ（`inactive_file` 590 MiB。Fluent Bit のファイルと dual logging のキャッシュの書き込みで増える）で、メモリーが足りなくなれば使い回されます。キャッシュを除いた使用量（working set）は 2,273 MiB で、目安の内です。4 GB の VPS で 150 テナント（決定事項 25）は保てると判断しました。
- 動作: 反映 1,444 回（24 時間）はすべて成功（中央値 2.4 秒、最大 2.6 秒）。`GET /tenants` 1,444 回・`GET /status` 2,888 回の誤り 0。RADIUS 85 万件は送った数と受けた数が一致。AP の接続は最小 741 / 750（反映で radsecproxy が再起動した分を張り直す。接続の失敗は 9 回）。コンテナの想定外の再起動 0。dind の CPU の平均は 17%（1 コアあたり）。
- ディスク: Fluent Bit のファイルは 125 MiB/日（2 週間で 1.7 GiB。logrotate の圧縮の前）、dual logging のキャッシュは最大 150 × 20 MiB = 2.9 GiB。25 GB の VPS に収まります。
- CRL: 1 日 145 回の更新が 5 分ごとの取得で届きました（ETag の 304 が 45,766 回、200 が 314 回）。

### dockerd の再起動（live-restore）

1 回目（`5a3a3e1`、`results/restart-1.txt`）:

- コンテナ 150 の起動の時刻は変わらず、AP の接続も切れませんでした（747 → 748）。dockerd は 17 秒で戻り、Fluent Bit にもログが届きました。
- **ただし agent が Docker につなげなくなり、反映が 4 回失敗しました**（`dial unix /var/run/docker.sock: connect: connection refused`）。agent は `docker.sock` をファイルとしてマウントするので、dockerd がソケットを作り直すと古い inode を見たままになります（ホスト 9053628、agent 9053608）。live-restore で agent も止まらないので、自分では直りません。`docker compose restart radsec-edge-agent` で戻りました。
- 本番の Debian の docker-ce は systemd のソケット起動（`docker.socket`）なので、`docker.service` だけの再起動なら inode は変わらないはずです。パッケージの更新で作り直されるかは確かめていません（段階 5 の VPS で確かめる）。

2 回目（L12 を直した `2a8b62d`、`results/restart.txt`）:

- agent は 60 秒続けて Docker に届かないので終了し、再起動の方針で作り直されて、**dockerd の再起動から 69 秒で Docker に届きました**。その後の反映はすべて成功しました。コンテナの起動の時刻は変わらず、接続も切れませんでした（749 → 748）。
- 再起動の後 1 時間（1 回目の後）は、メモリーの合計 2,127〜2,159 MiB で落ち着き、反映 53 回はすべて成功しました（agent を戻す前の 4 回を除く）。dockerd のスレッドは 20 から 104 に増えました（再起動の後の Go の実行時の分。増え続けてはいません）。
