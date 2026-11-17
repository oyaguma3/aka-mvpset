# 受入試験の予行（段階 6-4。UniFi U7 Lite と実際の SIM）

段階 6 の手順 6-4 で、受入試験の手順書（[docs/acceptance-test.md](../../docs/acceptance-test.md)）の予行を、実際の AP（Ubiquiti UniFi U7 Lite）・実際の検証用 SIM・2 つの端末で行った台本と結果です。
要件と構成の概要 §18.13 の S6-10 と、確認事項 A6-1〜A6-19 によります。

## 作り

```
端末 1: Android の端末（SIM 1 枚目。人が操作）          ┐
端末 2: USB のモデムの検証用 SIM と無線 LAN（SIM 2 枚目。│ Wi-Fi（WPA2-Enterprise、EAP-AKA・EAP-AKA'）
        simwifi を台本で動かす）                        ┘
        │
UniFi U7 Lite（UniFi OS Server で設定）
        │ RadSec（拠点の回線から。サーバーは IPv4 アドレスで書く）
エッジ 2 台（テナント at1 のポート。primary=edge-01、secondary=edge-02）
        │ wg-svc（WireGuard）
データ面（aka-radius・aka-vecgen）、管理面（aka-ossbss・aka-provisioner・radsec-ca）

画面: 手元のブラウザー（playwright-cli）─ Cloudflare Access ─ aka-ossbss
```

- 予行のテナントは `at1`（試験の本体）と `at2`（AT-08 の付け替え先）。at1 にグループ `unifi`（用途 unifi、P-256）を登録し、1 組の証明書と鍵を UniFi の RADIUS のプロファイルに入れた。
- 検証用 SIM の vecgen 側（Ki・OPc）は、システム管理者が画面で登録した（台本やチャットには通さない）。radius 側は台本が登録した。
- 端末 2 は [simwifi](https://github.com/oyaguma3/simwifi)（v0.1.3。SIM の AKA の計算を MBIM のモデムで行い、wpa_supplicant でつなぐ）。無線 LAN の口には IP アドレスを付けない（検証機の経路を変えないため。AT-12 の間は IPv6 の RA も止めた）。
- 規模の試験のデータ（テナント 1,000、加入者 20 万）が入ったままの環境で行った。

## ファイル

| ファイル | 内容 |
|---|---|
| `drive.sh` | 台本（手元で動かす）。段は下の表 |
| `ui/*.js` | 画面の台本（playwright-cli の `run-code` に渡す）。段階 5 の `verify/stage5/ui/`（状態の変更、送信元の範囲）も使う |
| `results/results.tsv` | 項目ごとの結果（拠点のアドレス、IMSI、AP の MAC アドレスは伏せた） |
| `results/night.txt` | AT-12 の一晩の記録（認証し直しの時刻、エッジの AP の接続、端末の Wi-Fi の接続） |

公開しないもの（手元の `$WORK/accept/` だけに置く）: グループの鍵と CSR、UniFi に入れた PEM、SIM の IMSI、端末と RADIUS の生の記録。

## 動かし方

```bash
export WORK=~/aka-deploy/stage6      # site.env（BASE・ADMIN_EMAIL・DNS_DOMAIN・HOME_IP）がある手元の作業場所
verify/acceptance/drive.sh <段>
```

| 段 | すること |
|---|---|
| `csr` | 顧客の役で、グループの鍵と CSR を作る（鍵は手元だけ） |
| `login-start`・`login-pin <PIN>` | Access のログイン（PIN はシステム管理者のメールに届く。10 分で切れる） |
| `setup` | テナント at1・at2、RadSec と配置、グループ、反映、PEM |
| `pem`・`dns`・`tls` | PEM 3 つを取り出す、スロットの名前を引く、手元から TLS を確かめる（名前と IPv4 アドレスの両方で照らす） |
| `radius` | SIM の radius 側を登録する（ルールは NAS-Identifier `*`・SSID・Session-Timeout 3600） |
| `sim-status`・`sim-id`・`status`・`try` | 端末 2 の前提、SIM の IMSI、配置と接続の様子、1 回だけつなぐ |
| `at01`・`first`・`at05`・`at05b`・`at06`〜`at10` | AT-01〜AT-10 |
| `at11-renew`・`at11-check` | AT-11（間に、人が UniFi の証明書を入れ替えて AP を再起動する） |
| `night-start`・`night-status`・`night-stop` | AT-12（端末 2 を一時の unit でつないだまま置く。判定は認証し直しの時刻の間隔で人が書く） |
| `apply`・`revoke`・`renew-rsa` | 反映、証明書の失効、RSA の鍵での証明書の更新（切り分けで使った） |
| `clean` | 片付け（SIM → グループ → 配置 → テナント） |

## 結果（2026-11-17〜18）

| 項目 | 結果 | 様子 |
|---|---|---|
| AT-01 RadSec でつながる | PASS | UniFi は CA・証明書・鍵を差し替えた後に AP の再起動が要った（下の「見つけたこと」） |
| AT-02 EAP-AKA | PASS | 2 つの端末とも。Android の端末はインターネットにも出られた |
| AT-03 EAP-AKA' | PASS | 2 つの端末とも |
| AT-04 再同期 | PASS | Android の端末の SIM で 1 回起きた（もう 1 枚では起きなかった） |
| AT-05 NAS-Identifier と Called-Station-Id | PASS | 実際の値のルールで通り、合わない値で拒否される。UniFi の「AP MAC」は小文字・コロン区切り |
| AT-06 Accounting と利用の集計 | PASS | 翌朝 3:00 の取り込みで、2 枚とも at1 で利用の集計に入った |
| AT-07 状態による拒否 | PASS | `AUTH_SUBSCRIBER_INACTIVE` |
| AT-08 別のテナントの拒否 | PASS | `AUTH_POLICY_DENIED`（刻印のテナントとルールのテナントが合わない） |
| AT-09 送信元の範囲 | PASS | 範囲の外はエッジが TLS に応じない（`ignoring unknown TLS client`） |
| AT-10 予備のサーバーへの切り替え | PASS | 6 秒で secondary に切り替わった。UniFi は戻した後も secondary のまま |
| AT-11 証明書の差し替え | PASS | 古い証明書を失効させ、エッジの接続を張り直させても、新しい証明書で通った |
| AT-12 一晩の維持 | **FAIL** | 認証し直しの拒否は 0。エッジが要求のない AP の接続を 15 分で閉じ、UniFi の張り直しが遅れた回に、認証し直しが 16〜59 分遅れ、端末がつながらない時間があった（`results/night.txt`） |

夜の定期の処理（利用の取り込み、突き合わせ（ずれ 0）、削除、証明書の更新、課金の締めの確かめ）はすべて ok、外形監視は 2 スロットとも成功し続け、発報した警告は 0 だった。

## 見つけたこと（確認事項。すべて推奨どおりで合意）

| # | 見つけたこと | 決めたこと |
|---|---|---|
| A6-12 | UniFi が TLS の途中で切り続けた（エッジのログは `unexpected eof while reading`）。サーバー証明書の名前・CA の束・鍵の形式・鍵の種類を順に切り分けた（edge-01 に一時の受け口を立てた）が、原因は **UniFi が CA・証明書・鍵の差し替えを AP の再起動まで読み込まない**ことだった | 手順書に書く（A6-16）。一時の受け口と試しの CA・鍵は片付けた |
| A6-13 | radsecproxy（1.11.4・1.11.5）は、AP からの TLS の接続を要求がないと 900 秒で閉じる（ソースに固定）。UniFi は認証の接続で生存確認を送らないので、閉じられた後の張り直しが遅れると、認証し直しが通らない | radsec-edge の radsecproxy のパッチに、開発版と同じ名前のクライアントの `IdleTimeout` を取り込み、テナントの設定に `IdleTimeout 0`（閉じない。切れた相手は TCP の生存確認で見つける）。あわせて radsecproxy を 1.11.5 に上げる。段階 6-5 で、段階的な反映し直しで届ける |
| A6-14 | UniFi OS Server の RADIUS のサーバーの欄は IPv4 アドレスだけ。スロットの移動やエッジの入れ替えでアドレスが変わる | aka-ossbss の RadSec の画面と接続の案内に、スロットごとの IPv4 アドレスも出す。AP の接続の手順書と運用ガイドのスロットの移動に注記。サーバー証明書に IP アドレスは入れない（UniFi は照らし合わせない） |
| A6-15 | 証明書の発行・失効で宣言の版が上がり「反映する」が要るが、画面と手順書は「反映は要らない」と書いている。反映してもエッジは何もしない（action `none`） | aka-ossbss が、AP・グループの証明書の発行・失効のときに反映を自動で求める |
| A6-16 | 証明書の差し替えで AP の再起動が要る製品がある | AP の接続の手順書に一般的な書き方で足す。製品名は受入試験の手順書 11 章だけ |
| A6-17 | キャッシュした鍵で EAP なしにつなぎ直す端末では、aka-radius にセッションがなく、Accounting が `ACCT_SESSION_NOT_FOUND`（WARN）になる（一晩で 163 回。利用は集計される） | aka-radius で、Class の UUID と IMSI があればセッションを作り直して続け、INFO にする |
| A6-18 | AT-12 の FAIL | A6-13 の後に、残した環境で一晩やり直す |
| A6-19 | 手順書 | 予行の結果で直し、1 回目の予行としてコミットする（やり直しの結果は後で足す） |

そのほか（手順書に書いた）: UniFi の NAS-Identifier は誤ってカスタムの固定の値になっていたので「AP MAC」にした（「変更を適用」だけで効く）。Called-Station-Id は電波の MAC アドレス（BSSID）と SSID。AT-09 の送信元の範囲の変更は、反映のときに AP の接続がいったん切れる。

## 残したもの（A6-18）

エッジの直しの後に AT-12 をやり直すため、テナント at1・at2、グループ `unifi`、SIM 2 枚の登録、UniFi の設定、スロットの名前の CNAME 2 件は残してある。やり直しの後に `clean` で片付け、UniFi の設定と CNAME は人が消す。
