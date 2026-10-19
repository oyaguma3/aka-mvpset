# N1: エッジの 1 テナントあたりのメモリー

要件と構成の概要の決定事項 25（エッジの容量）の根拠にした計測の道具と結果。結果のまとめは概要 §20.1。

## 目的

radsec-edge はテナントごとに radsecproxy のコンテナを立てる。エッジ 1 台に置けるテナントの数を、1 テナントあたりのメモリーから見積もる。Docker の `userland-proxy`（公開ポートごとの docker-proxy のプロセス）をオフにしたときとオンにしたときを比べる。

## 方法

- 検証機（simwifi。Debian 13、Docker 29.8.2、N100・16 GB）で、`docker:29.8.2-dind` の中に起動したばかりの dockerd を立てて測る。ホストの Docker の設定は変えない。dind の中のものは dind のコンテナの cgroup に入れ子になるので、その `memory.current` と `memory.stat` で、エッジの側の合計（プロセス、カーネル、ページキャッシュ）を取る。プロセスの種類ごとの RSS と PSS も `/proc/<pid>/smaps_rollup` から取る。
- テナントのコンテナは、radsec-edge の agent のひな形（`internal/agent` の `tenantSpec`、radsec-edge `4e77a0a`）と同じ引数（nonroot、`--init`、読み取り専用、`--cap-drop ALL`、`no-new-privileges`、ログの回転、専用の bridge、ポートの公開）で作る。イメージは radsec-edge の `images/radsecproxy/Dockerfile`（radsecproxy 1.11.2-1+deb13u1）。ホストでビルドし、`docker save` と `docker load` で渡す（概要の決定事項 24 と同じ形）。
- 設定は radsec-edge の `internal/rsconf` のひな形と同じ形（TLS、CRLCheck on、AP ごとの rewrite と client ブロック、Status-Server つきの上流 2 つ）。鍵は ECDSA P-256。上流は応答しない宛先にした。
- テナントあたり AP 5 つ（client ブロックと証明書）。テナントを 0 → 10 → 20 → 40 → 80 → 160 と増やし、各段で 20 秒待ってから、接続なしと、全 AP が TLS の接続を張った状態とを測る。最後に AP 200 の重いテナントを 1 つ加え、接続なしと 200 本の接続を測る。

## 動かし方

```bash
ssh simwifi 'mkdir -p ~/aka-work/n1'
```

```bash
tar -c run.sh gen.sh clients.py measure.py -C ~/projects/radsec-edge/images/radsecproxy Dockerfile | ssh simwifi 'cd ~/aka-work/n1 && mkdir -p image && tar -x && mv Dockerfile image/'
```

```bash
ssh -f simwifi 'cd ~/aka-work/n1 && nohup bash run.sh /home/claude/aka-work/n1 > run.log 2>&1 < /dev/null &'
```

2 つのモードで約 30 分かかる。結果は `~/aka-work/n1/result-<モード>.jsonl`。片付け:

```bash
ssh simwifi 'docker image rm -f n1/radsecproxy docker:29.8.2-dind; docker image prune -af; docker builder prune -af; sudo rm -rf ~/aka-work/n1'
```

## 結果（2026-10-20）

`results/` に JSON Lines で置く。主な値（MiB。cgroup の合計は `memory.current`）:

| モード | テナント | 接続 | cgroup の合計 | anon | kernel | containerd-shim（PSS） | radsecproxy（PSS） | docker-proxy（PSS） |
|---|---|---|---|---|---|---|---|---|
| noproxy | 0（イメージの読み込みの後） | 0 | 178.9 | 46.8 | 10.5 | 0 | 0 | 0 |
| noproxy | 20 | 0 | 397.7 | 229.3 | 35.9 | 138.7 | 46.7 | 0 |
| noproxy | 160 | 0 | 1952.7 | 1538.2 | 213.4 | 1088.0 | 323.4 | 0 |
| noproxy | 160 | 800 | 2081.0 | 1614.0 | 254.9 | 1086.6 | 394.3 | 0 |
| proxy | 0（イメージの読み込みの後） | 0 | 177.7 | 46.0 | 10.3 | 0 | 0 | 0 |
| proxy | 20 | 0 | 473.1 | 307.9 | 41.8 | 144.1 | 46.7 | 71.5 |
| proxy | 160 | 0 | 2575.4 | 2127.3 | 263.3 | 1102.2 | 323.6 | 571.9 |
| proxy | 160 | 800 | 2709.4 | 2205.1 | 304.9 | 1103.0 | 394.6 | 571.9 |

- 起動したばかりの dockerd は RSS 約 80 MiB、containerd は約 40 MiB（イメージの読み込みの後は約 92 MiB と 45 MiB）。
- 接続はすべて受け付けられた（各段で failed 0、alive が接続数と同じ）。
- 接続を閉じても radsecproxy のメモリーはすぐには戻らない（重いテナントの「接続なし」は、直前の 800 本の段の値から測った）。

## 測っていないもの

- radsec-edge と agent のプロセスがテナントの数に応じて増える分（以前の計測で 2 つで約 25 MiB）。
- 反映のときの捨てるコンテナ（構文の検査）や再起動の一時的な増え方。
- RADIUS のパケットを流したときの CPU とメモリー、conntrack。
- 本物の VPS（dind ではない、Docker の cgroup ドライバーが systemd のもの）での値と、ホスト OS 自体の大きさ。
