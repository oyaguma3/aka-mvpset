# R10: RadSec の受け口のラボ（radsecproxy の信頼の起点・CRL・client ブロック・テナントの刻印）

要件と構成の概要の決定事項 32〜34 の根拠にしたラボの道具と結果。結果のまとめは概要 §20.2。

## 目的

業者の CA（Meraki の PureCA のような多段の中間 CA、Mist のような組織ごとの自己署名の CA）と、こちらの CA が発行するグループの証明書を、テナントのエッジの radsecproxy で正しく受け分けられるかを、実機の AP なしで確かめる。

## 方法

- 検証機（simwifi。Debian 13）の Docker の中で、radsecproxy を 4 つ用意して比べる。
  - Debian 13 のパッケージ（1.11.2-1+deb13u1。今のエッジのイメージと同じ）
  - 1.11.4 のソースからビルドした無改造のもの
  - 1.11.4 に `partialchain.patch`（tls ブロックごとのオプション `PartialChain`）だけを当てたもの
  - 1.11.4 に `partialchain-leafcrl.patch`（`PartialChain` に加え、`PartialChain on` のときは CRL の確認をリーフだけにする）を当てたもの。エッジで使う版（決定事項 32）
- 業者の CA は公開の情報をもとにした**模型**で、実物ではない。
  - Meraki: 共通のルート → 共通の中間 CA 2 段 → 組織の CA（CN = 組織の ID）→ RadSec 用の CA → AP（CN = シリアル番号の形）。組織を 2 つ作る。
  - Mist: 組織ごとの自己署名 CA → AP（CN = MAC の 12 桁）。組織を 2 つ作る。
- こちらの CA: テナントごとの自己署名のクライアントCA と、グループの証明書（URI SAN `urn:example:grp:<テナント>:<グループ>`）・AP の証明書（`urn:example:nas:<テナント>:<AP>`）。
- 鍵はすべて ECDSA P-256。CRL は `openssl ca` で作る。
- TLS の受け入れは `openssl s_client` でつなぎ、radsecproxy のログ（`TLS connection from ..., client <ブロックの名前> ... up`、または拒否の理由）で判定する。
- テナントの刻印と NAS-Identifier は、AP の役の radsecproxy（UDP で受けて RadSec で送る）→ エッジの役の radsecproxy → 上流の役（`radtool.py dump`）の経路で、上流に届いた属性で判定する。AP からは偽の刻印（Vendor-Id 32473、Vendor-Type 1、値 `999`）と、別の業者の VSA（Vendor-Id 9）を付けて送る。

## 場面

| 群 | 内容 |
|---|---|
| P | 信頼の起点とチェーン（共通のルート、組織の CA、RadSec 用の CA、PartialChain、深さの上限、Mist の模型） |
| C | CRL（PartialChain と CRLCheck の組み合わせ、失効、CRL のない CA、こちらの CA との混在） |
| B | client ブロック（グループのブロック、登録していない証明書、ブロックの削除、同じ SAN の新旧の証明書と失効） |
| M | CRL のない持ち込みの CA を CRLCheck off で受け、共通のブロックを CN の形で絞る |
| V | テナントの刻印と NAS-Identifier（AP・グループ・共通のブロック、Accounting、Debian の 1.11.2） |

## 動かし方

radsecproxy 1.11.4 のソースを取得して、この README と同じディレクトリに置く（ファイルの SHA-256 は Dockerfile で確かめる）。

```bash
curl -fLO https://github.com/radsecproxy/radsecproxy/releases/download/1.11.4/radsecproxy-1.11.4.tar.gz
```

検証機に送って動かす（約 10 分。結果は `run.log` の表と、コンテナの中の `/work/results.tsv`）。

```bash
ssh simwifi 'mkdir -p ~/aka-work/rlab'
```

```bash
tar -c Dockerfile lab.sh radtool.py partialchain.patch partialchain-leafcrl.patch radsecproxy-1.11.4.tar.gz | ssh simwifi 'tar -x -C ~/aka-work/rlab'
```

```bash
ssh -f simwifi 'cd ~/aka-work/rlab && nohup sh -c "docker build -q -t rlab:sim . && docker run --rm --name rlab rlab:sim" > run.log 2>&1 < /dev/null &'
```

片付け:

```bash
ssh simwifi 'docker image rm -f rlab:sim; docker image prune -af; docker builder prune -af; sudo rm -rf ~/aka-work/rlab'
```

## 結果（2026-10-20、検証機）

52 件すべてが期待どおり（`results/results.tsv`）。主なもの:

| ID | 場面 | 結果 |
|---|---|---|
| P2 | 無改造で共通のルートを信頼し、他の組織の Meraki の AP | 受け入れてしまう |
| P3 | 無改造で RadSec 用の CA だけを信頼 | 拒否（起点にならない） |
| P4・P6 | PartialChain で RadSec 用の CA を起点（自組織・他組織） | 自組織は受け入れ、他組織は拒否 |
| P9 | パッチ版で PartialChain を書かない | 無改造と同じ |
| P10・P11 | 1 段深いチェーン（無改造で共通のルート・PartialChain で RadSec 用の CA） | 無改造は深さの上限で拒否、PartialChain は受け入れ |
| C1a・C2a | PartialChain だけの版で CRLCheck on | 正当な AP も拒否（起点の CA 自身の CRL を求められる、またはその CRL の署名を確かめられない） |
| C1・C3・C3b | CRL をリーフだけにした版で CRLCheck on | RadSec 用の CA の CRL 1 つで、正当な AP は受け入れ、失効させた AP は拒否 |
| C4・C4b | 組織の CA を起点 | RadSec 用の CA の CRL も要る |
| C7・C7c | CRL のない CA が束にある | その CA の証明書だけが拒否され、他の CA の証明書は巻き込まれない |
| C8〜C8d | こちらの CA と Meraki の模型の混在の束 | それぞれ正しく受け入れ・拒否 |
| B1b・B2 | 共通のブロックがなく、登録していない証明書・ブロックを消した証明書 | 拒否 |
| B3c・B3d | 同じ SAN の古い証明書を失効させて SIGHUP | 古い方だけ拒否 |
| M1〜M5 | CRLCheck off で Mist の模型を共通のブロック（CN の形で絞る）で受ける | Mist の AP は共通のブロック、こちらの未登録の証明書は拒否。ただし失効させたこちらの証明書も通る（ブロックの削除で止める） |
| V1〜V7 | テナントの刻印と NAS-Identifier | 偽の刻印は消して付け直し、別の業者の VSA は残る。NAS-Identifier の置き換え・そのまま・補うがそれぞれ効く。Accounting にも付く。Debian の 1.11.2 でも同じ |

## 確かめていないもの

- 実物の業者の証明書と CRL（拡張、ポリシー、名前制約、AP が送るチェーン、CRL の期間）。実機が手に入ったときに確かめる（概要 §19）。
- `PolicyOID` との組み合わせ、Status-Server、IPv6。
- radsec-edge の設定の生成（rsconf）と agent を通した反映。段階 4 の実装で確かめる。
