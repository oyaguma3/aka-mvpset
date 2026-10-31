# エッジのテナントのコンテナのログの読み方

aka-mvpset の概要 §18.9 の S4-4 と、radsec-edge の段階 4-1b の判断の根拠にした計測の道具と結果。

## 目的

エッジにも Fluent Bit を 1 つ置き、テナントの radsecproxy のログを送る。読み方によって、1 台 150 テナント（決定事項 25）のメモリーと、`GET /tenants/{id}/last-seen` が頼る `docker logs` がどう変わるかを確かめる。

| 方式 | 内容 |
|---|---|
| `json` | json-file だけ（Fluent Bit なし。比べる基準） |
| `fluentd` | fluentd のログドライバー。値はデータ面のノードと同じ（`fluentd-buffer-limit=1048576`。Fluent Bit の forward は既定の受信バッファー） |
| `fluentd2` | `fluentd` と同じ方式で値を絞る（`fluentd-buffer-limit=8192`。forward は `buffer_chunk_size: 32K`、`buffer_max_size: 512K`） |
| `tail` | json-file のまま、Fluent Bit が `/var/lib/docker/containers/*/*-json.log` を tail で読む |

## 方法

- 検証機（simwifi。Debian 13、N100・16 GB）の `docker:29.9.2-dind`（`--userland-proxy=false --live-restore`。決定事項 27）に、起動したばかりの dockerd を立てて測る。ホストの Docker の設定は変えない。メモリーの測り方と PKI・設定の作り方は `verify/n1` と同じ（`gen.sh`・`clients.py`・`measure.py` はその写し）。
- 150 テナント、AP 5 台ずつ。イメージは `radsec-edge/radsecproxy:1.11.4-pc1`。fluentd のときは dual logging のキャッシュを `cache-max-size=10m`・`cache-max-file=2` にする。
- 手順: 起動 → 接続なしで測る → 750 本の接続を張る → 毎秒 20 接続を 60 秒繰り返してログの行を出す（`cycle.py`）→ `docker logs` の読み出しと、Fluent Bit に届いた行の数を比べる → Fluent Bit を止めて 30 秒、コンテナの作り直しと再起動も試し、戻した後に行が届くかを見る（fluentd のときだけ）→ `dockerd` を止めて起動し直す（live-restore）。

## 動かし方

```bash
ssh simwifi 'mkdir -p ~/aka-work/edge-logs'
```

```bash
docker save radsec-edge/radsecproxy:1.11.4-pc1 | gzip -1 | ssh simwifi 'cat > ~/aka-work/edge-logs/image.tar.gz'
```

```bash
tar -c run.sh gen.sh clients.py measure.py cycle.py | ssh simwifi 'cd ~/aka-work/edge-logs && tar -x'
```

```bash
ssh -f simwifi 'cd ~/aka-work/edge-logs && nohup env MODES="json fluentd fluentd2 tail" bash run.sh /home/claude/aka-work/edge-logs > run.log 2>&1 < /dev/null &'
```

1 方式あたり約 8 分。`run.log` に `== 終わり` が出たら、`result-<方式>.jsonl` と `notes-<方式>.txt` を手元へ写す。片付け:

```bash
ssh simwifi 'sudo rm -rf /home/claude/aka-work/edge-logs; docker image prune -af; docker builder prune -af'
```

## 結果（2026-10-31）

`results/` に置く。150 テナント、750 接続、ログの行を出した後の値（MiB。合計は dind の cgroup の `memory.current`、ほかは PSS）。

| 方式 | 合計 | json との差 | dockerd | containerd-shim | radsecproxy | Fluent Bit |
|---|---|---|---|---|---|---|
| `json` | 2108 | — | 186 | 1012 | 377 | — |
| `fluentd` | 2811 | **+703** | 671 | 1047 | 377 | 176 |
| `fluentd2` | 2195 | **+87** | 206 | 1044 | 377 | 32 |
| `tail` | 2152 | +44 | 166 | 1022 | 377 | 40 |

- `fluentd` の増分の大半は 2 つの値で決まる。`fluentd-buffer-limit` は待ち行列のイベントの数で、コンテナごとに確保される（既定の 1,048,576 で dockerd が 1 コンテナあたり約 3.2 MiB 増える）。Fluent Bit の forward は接続ごとに受信バッファーを取る（既定で 1 接続あたり約 1 MiB）。`fluentd2` はこれを絞り、1 テナントあたりの増分は約 0.6 MiB になった。
- どの方式でも、接続 750 本はすべて受け付けられ、起動の時間（約 48 秒）と CPU（負荷の 60 秒で 11〜13 秒、何もしない 60 秒で 3〜4 秒）に目立つ差はない。
- `docker logs --timestamps --since` は fluentd のドライバーでも dual logging のキャッシュで読め、行の形も同じ（radsec-edge の `LogsSince` と `parseSeen` がそのまま使える）。
- Fluent Bit への送信は `localhost:24224`（`userland-proxy` オフ）で届く。Fluent Bit の出力の行の数は `docker logs` の合計と合う（読むまでの時間の差で少し多い）。
- Fluent Bit を止めている間（`fluentd`・`fluentd2`）: コンテナは動き続け、`docker logs` は読め、作り直しと再起動もできる。戻すと、止まっていた間の行が届く（どちらも 4,448 行）。ただし、止まっている間に作り直した・再起動したコンテナの送っていない行は失われる。
- `dockerd` の再起動（live-restore）: どの方式でもコンテナの起動の時刻は変わらず、接続は切れず（750→750。fluentd の 2 方式は作り直したコンテナの分を除いて 740→740）、その後の行も `docker logs` と Fluent Bit に届く。
- `tail` はメモリーが最も小さいが、Fluent Bit を root で動かして全コンテナの JSON のログを読み取り専用でマウントすることになり、行に残るのはコンテナの ID だけなので、テナントを見分けるのに別の作りが要る。ほかのノードの方式（fluentd のドライバー）とも違う。

## 測っていないもの

- radsec-edge と agent のプロセスの増え方、整合ループが 1 分ごとに読むときの増え方（長い時間の試験 `verify/edge-long/` で確かめる）。
- 本物の VPS（dind ではないもの）での値。
- 上流を応答させたときのログの量（ここでは上流が応答しないので、`clientwr: no status server response` の行がテナントごとに 1 分に 4 行ほど出る）。
