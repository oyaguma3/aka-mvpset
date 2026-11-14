# 段階 5 の VPS の上の確かめ（通し、戻す練習、150 テナントの長い時間の試験、障害の通知）

段階 5（配置）の手順 5-6 で、VPS に配置した全ノードを相手に、環境で変わるところの通し、バックアップから戻す練習、
エッジ 1 台に 150 テナントを載せた長い時間の試験、Docker の再起動と更新、障害の通知、片付けを行った道具と結果です。
要件と構成の概要 §18.11 の S5-15 と、確認事項 T5-1〜T5-25 によります。

## 作り

```
ブラウザー（手元の playwright-cli）─Cloudflare Access─Tunnel─> 管理面（aka-ossbss・aka-provisioner・radsec-ca）
                                                                     │ wg-svc（WireGuard）
                         ┌───────────────────────────────────────────┼────────────────────── データ面（aka-radius・aka-vecgen）
                         ▼                                           ▼
  AP の役（手元の回線の内側の検証機。radsecproxy と eapaka_test）─インターネット─> edge-01・edge-02（テナントのポート）
  AP の役（150 テナントの試験。T5-23 で足した一時の VPS）────────インターネット─> edge-02
  監視ノード（Prometheus・Alertmanager・外形監視）── wg-ops ── 全ノード ─→ Slack
```

- VPS は 5 台（データ面・管理面・エッジ 2 台・監視）。導入は `docs/deployment.md` のとおりです。
- 通しのテナント `s5a` は primary を edge-01、secondary を edge-02 に置きます。外形監視のテナント `probe` も同じ形で、片付けの後も残します。
- 150 テナントの試験（③）は、`ld001`〜`ld148` に `probe`・`s5a` を合わせた 150 テナントを edge-02 に置き、1 テナントあたり AP 5 台（接続 740 本）をつなぎます。
  - AP の役は、最初は手元の回線の内側の検証機から送りました。手元の回線は IPv4 を ISP 側の NAT で共有する形で、740 本の接続で利用者ごとの同時のセッションの枠を使い切り、家庭のほかの通信の新しい接続が断られました（確認事項 T5-22・T5-23）。
  - その後は、一時の VPS（2 GB）から送りました。この VPS は SSH を監視ノードからだけ受け、試験の後に消しました。
- 製品に試し用の口は足していません。

| ファイル | 内容 |
|---|---|
| `drive.sh` | 手元の台本。段（下の表）ごとに VPS・検証機・画面を動かす |
| `ap.sh` | 検証機の側の AP の役（radsecproxy の起動、eapaka_test、TLS の試し） |
| `ui/*.js` | 画面の台本（playwright-cli の `run-code`）。`bulk.js` は画面の要求を 1 回でまとめて送る。画面の HTTP の部品は段階 4 の `verify/stage4/web.py`・`ui/http.js` を使う |
| `load.py` | ③ の要求の組み立て（テナント・AP・配置、証明書の取得、片付け）と、測定のまとめと判定 |
| `load-ap.py` | ③ の AP の役（接続を保ち、毎秒 1 本つなぎ直し、登録のない IMSI の認証を流して Access-Reject を受ける） |
| `load-measure.py` | ③ の測定（edge-02 のホストで 10 分ごと。使用量、プロセスの PSS・FD、cgroup、接続、ディスク、コンテナの起動の時刻） |
| `t510.sh` | T5-10・T5-24 の Docker の再起動と更新（前後の状態の記録と比べ、反映の試し） |
| `ap-cost.py` | T5-25 の AP 1 台あたりのメモリーの計測（1 分ごと）とまとめ |
| `arena/` | T5-20 の実験。radsecproxy のつなぎ直しを検証機で再現し、`MALLOC_ARENA_MAX` の効果を比べる |
| `results/` | 結果（公開のアドレス・ドメイン・メールアドレスは伏せた） |

**公開のリポジトリなので、ドメイン・メールアドレス・公開のアドレスはここに書きません。** 手元の作業場所の `site.env`（`BASE`、`ADMIN_EMAIL`、`DNS_DOMAIN`、`HOME_IP`、`PROBE_IMSI`）と、配置の `inventory.env` から読みます。

## 動かし方

```bash
export WORK=<手元の作業ディレクトリ>   # site.env を置く
verify/stage5/drive.sh <段>
```

| 段 | 内容 |
|---|---|
| `prepare` | AP の役の道具と eapaka_test を検証機に送り、AP の鍵と CSR を検証機で作る |
| `login-start`・`login-pin <PIN>` | Access のログイン（PIN は人が渡す） |
| `setup`・`aps` | 通しのテナント `s5a`・加入者・RadSec・配置・AP を画面から作り、AP の役を起動する（DNS の CNAME は人が登録する） |
| `dns`・`auth`・`reject`・`source`・`revoke`・`apply`・`nft`・`reboot`・`ui` | ① 通し（下の P〜U） |
| `drill-data`・`drill-mgmt` | ② 戻す練習（D・M） |
| `keepalive` | T5-18 の確かめ（K） |
| `load-keys`・`load-tenants`・`load-wait`・`load-certs`・`load-try`・`load-start`・`load-status`・`load-report` | ③ 150 テナントの試験 |
| `notify` | ④ 障害の通知（N） |
| `clean` | 片付け（C） |
| `summary` | 結果の数え上げ |

## 結果（2026-11-12〜15）

`results/results.tsv` は **68 / 68 PASS** です。

- ①・② は段階 4 を締めた組み合わせで行いました（aka-mvpset `bd65f49` の `versions.env`）。
- K と ③ は Go 1.27.4 と T5-18 の組み合わせで行いました（aka-mvpset `11a7f0d` の `versions.env`）。
- ③ の測り直し・AP 1 台あたりの計測・④・片付けは、そこに radsec-edge `b482617`（T5-19・T5-21）を加えた組み合わせです。

### ① 通し（T5-2。31 項目）

| 場面 | 確かめたこと |
|---|---|
| P | スロットの名前を公開のリゾルバーと AP の役の機械から引ける |
| B | インターネット越しの 2 台のエッジで EAP-AKA・EAP-AKA' が通る。テナントの刻印、RADIUS の送信元はエッジの WireGuard のアドレス、エッジに見える送信元は実際の AP の回線のアドレス |
| R | 別のテナントの IMSI、登録のない IMSI、radius 側を止めた加入者を断り、戻すと通る |
| S | 送信元の範囲（手元の回線のアドレスの /32 で受け、範囲の外は TLS で断り、空に戻す） |
| X | AP の証明書の失効が WireGuard 越しの CRL で 2 台に届く。失効の後の宣言の変更を「反映する」で 2 台に届ける |
| F | エッジ以外のアドレスからデータ面の RADIUS に送ると nftables で落ちる |
| G | edge-01 の再起動の間、両方のスロットを持つ AP は secondary に切り替わって通り（16 秒）、戻ると primary で通る |
| U | Cloudflare 越しの画面（ダッシュボードの 6 つの接続、配置の反映の状態） |

### ② 戻す練習（T5-5・T5-6。16 項目）

- **データ面（D）**: Valkey のボリュームと KEK を消し、監視の PC の役の写しと手元の KEK の写しから戻すまで 52 秒でした。戻した後は、SQN の再同期、写しの後に足した加入者の拒否と突き合わせ、承認つきの登録し直しを確かめました。
- **管理面（M）**: aka-ossbss の DB・radsec-ca の DB・aka-provisioner の Valkey を写しから戻すまで 37 秒でした。DB は写しの時点に戻り、エッジのほうが新しい版であることが画面に出ます。「やり直す」を 1 台ずつ押すと、写しの後に足した AP がつながらなくなることを確かめました。

### T5-18 TCP の生存確認（K。10 項目）

エッジのテナントの radsecproxy の client ブロックに `TCPKeepalive on` を入れました。660 秒何も送らなかった AP の役が、つなぎ直さずに通ることを確かめています。入れる前は 10 分で応答がなくなっていました。手元の回線の側の NAT が、しばらく何も流れない TCP の対応を消すためとみています。

### ③ 150 テナントの長い時間の試験（T5-7〜T5-9、T5-20〜T5-22、T5-25）

基準は 2 つです（T5-9）。6 時間以降の使用量（MemTotal−MemAvailable）の増え方が 30 MiB/日未満であること、使用量が 2.8 GiB（4 GB の 70%）以内であることです。

| | 40.4 時間（`results/load-40h.txt`） | `MALLOC_ARENA_MAX=2` を入れた後の 24 時間（`results/load-remeasure.txt`） |
|---|---|---|
| 6 時間以降の増え方 | +92.3 MiB/日（不合格） | **+15.7 MiB/日（合格）** |
| 使用量の最大 | 3,044 MiB（不合格） | 2,930 MiB（不合格。定常は 2,895〜2,930） |
| radsecproxy（150 個の PSS） | 417 → 559 MiB | 392 → 462 MiB |
| containerd-shim（154 個の PSS） | 1,248 → 1,267 MiB | 1,063 → 1,277 MiB（作り直した直後から 2 時間で元の大きさに戻った） |

- **増えたもの**: radsecproxy の名前のない領域でした。radsecproxy は AP の接続ごとにスレッドを作り、glibc の malloc はスレッドごとに 64 MiB 級の領域（arena）を足して返しません。arena の数は同時のスレッドの数（7 + 接続 × 2）で頭打ちになり、漏れではありません。
  - 実験（`arena/`、`results/arena.txt`）で、既定は arena 14 個で止まり、`MALLOC_ARENA_MAX=2` では 1 個、`=1` では 0 個になることを確かめました。
  - 段階 4 の長い時間の試験で見えなかったのは、反映の繰り返しで各テナントが約 2.5 時間ごとに再起動していたためです。
- **T5-21**: テナントのコンテナのひな形に `MALLOC_ARENA_MAX=2` を入れ、ひな形のハッシュにも含めました（radsec-edge `b482617`）。イメージを入れ替えると、整合ループが 150 テナントのコンテナを約 103 秒で 1 つずつ作り直しました。arena は全部 1 個、名前のない領域は 1 個あたり 2.27 → 1.04 MiB になりました。
- **AP 1 台あたりのメモリー**（`results/ap-cost.txt`）: AP の役を 30 分止めて戻すと、使用量は接続 1 本あたり 70〜81 KiB 動きました。radsecproxy は確保した領域を返さず使い回すので、その分は最初の数時間の増え方から約 95 KiB と見積もりました（推定）。合わせて約 0.17 MiB で、1 テナント（約 13 MiB）は AP 約 75 台に当たります。
- **扱い（T5-25）**: 容量の上限 150 と基準 2.8 GiB は変えず、140 テナントで次のエッジの準備に入る目安を運用ガイドに書きました。顧客が足せる AP の数でも使用量が増えるので、エッジの使用量が 2.8 GiB を 30 分超えたら Slack に知らせる警告 `EdgeMemoryHigh`（`deploy/monitor/prometheus/rules.yml`）を足しました。試験の状態で発報して Slack に届き、片付けの後に解消しました。
- **そのほか**: 外形監視の失敗 0、反映の失敗 0、テナントのコンテナの想定外の再起動 0、FD の増加なしでした。ディスクの使用は約 19 GiB で、そのうち radsecproxy のログは約 109 MiB でした。

### T5-10・T5-24 Docker の再起動と更新（`results/t510.txt`）

edge-02 に 150 テナントと AP の接続 740 本を載せたまま、次の 2 つを行い、それぞれ 1 時間測りました。

| | `systemctl restart docker` | docker-ce 29.9.2 → 29.9.3、containerd.io 2.4.2-3 → 2.4.2-4 |
|---|---|---|
| dockerd が応えるまで | 15.6 秒 | 26.7 秒 |
| 作り直されたコンテナ | なし（live-restore） | agent だけ |
| agent が戻るまで | 16.8 秒 | 73.9 秒 |
| AP の接続・反映・ログ | 保たれた・通った・抜けなし | 保たれた・通った |

- **更新で agent だけ作り直された理由**: パッケージの更新で docker.socket も作り直され、`/var/run/docker.sock` をファイルでマウントしている agent が古いソケットを見たまま届かなくなります。60 秒で自分で終わって作り直される作り（段階 4 の L12）が働きました。
- **ほかの 4 台**: 直した `deploy/host/apply-host.sh` で 1 台ずつ上げ、containerd.io も版を決めて固定しました。

### ④ 障害の通知（T5-11。N。7 項目）

edge-01 のテナントのポート（probe・s5a）を、nftables の一時の表で 366 秒止めました。
- 両方のスロットを持つ AP は、17 秒で secondary に切り替わって通りました。
- 外形監視の `ProbeFailing` は、primary だけで 257 秒後に発報しました。戻すと 67 秒で解消し、primary だけの AP もまた通りました。
- Slack の [発生] と [解消] が届くことは、人が確かめました。[解消] は [発生] の 5 分後に届きます。Alertmanager の `group_interval: 5m` で、同じまとまりの次の知らせは前の知らせから 5 分空くためです。

### 片付け（T5-12。C。4 項目）

画面から次のものを消しました。要求はすべて成功しました。
- s5a の加入者
- 150 の配置と AP 742 台（有効な証明書は失効）
- 149 テナント（ポートが空き、テナントの CA が止まった）

残っているのは `probe` だけです。

## 見つけて直したこと（確認事項）

| # | 見つけたこと | 直したこと |
|---|---|---|
| T5-14 | 手元から監視ノードを踏み台にした SSH のセッションが溜まる | sshd の `ClientAlive*`、手元の経路を `nc -N` に（`deploy/`） |
| T5-15 | `docker compose kill -s HUP` を受けたコンテナが、ホストの再起動の後に起き上がらない | 起動のときにスタックを起こす `aka-compose-up.service`（`deploy/`） |
| T5-16 | 監視の PC の役の WireGuard が止まることがある | 見張りで張り直す（`deploy/ops-pc`） |
| T5-18 | しばらく何も流れない AP の接続が NAT で消える | テナントの radsecproxy の `TCPKeepalive on`（radsec-edge `9ede829`） |
| T5-19 | 反映の途中で radsec-edge を止めると、結果が「途中で止まった」でなく「失敗」になり、自動でやり直されない | 止めるときの取り消しを `interrupted` に（radsec-edge `e3afe92`） |
| T5-21 | radsecproxy の malloc の領域が同時のスレッドの数だけ増える | `MALLOC_ARENA_MAX=2`（radsec-edge `b482617`） |
| T5-24 | containerd.io を固定しておらず、`apt-get upgrade` で計画なしに入れ替わる | 版を決めて固定し、版が違えば上げる（`deploy/host/apply-host.sh`） |
| T5-25 | 150 テナント・AP 740 本で使用量が 2.8 GiB を少し超える | 140 の目安と `EdgeMemoryHigh`。監視の段は、規則が変わったら Prometheus・Alertmanager を再起動して読み直す |

## 残したこと

- 業者の実機の AP と、持ち込みの CA の実物（段階 4 からの残り）。
- 「ひな形が変わったら全テナントを反映し直す」口。T5-18 のような設定のファイルの変更は、上げただけでは入りません。
- バックアップで radsec-edge を止めない形（T5-19 の代案）。
- 手順書と各ノードの運用ガイドへの注記（`/opt` を tar で置き直すときに見本のファイルが書けないこと、HUP の扱い、Alertmanager の知らせの間隔）。

上の 3 つは段階 5 の締めで扱います。
