# R11: 複数の CA の束と送信元の範囲のラボ

radsec-edge の手順 4-1a（概要 §18.9）の確認事項 E7・E9・E10 の根拠にしたラボの道具と結果。`verify/r10` では確かめていなかった、束の中の 1 つの CA の CRL の期限切れ、`host` の複数行、同じ Subject の CA を確かめた。

## 方法

- `verify/r10` のパッチ（`partialchain-leafcrl.patch`）を当てた radsecproxy 1.11.4 を、Debian 13 のコンテナで動かす（エッジで使う版と同じ）。
- こちらの CA（own）と業者の CA（vendor）を 1 つの束に入れ、`openssl s_client` でつなぐ。受け入れは radsecproxy のログの `TLS connection from ..., client <ブロック> ... up` で判定する。
- vendor の CRL は 12 秒で期限が切れるように作り、接続を持ったまま期限を過ぎさせて、読み直しの前後を比べる。vendor を自己署名にした場合と、自己署名でない中間 CA で `PartialChain on` にした場合の両方で行う。

## 動かし方

```bash
cp ../r10/partialchain-leafcrl.patch .
docker build -q -t r11 .
docker run --rm r11
```

## 結果（2026-10-31、検証機。`results/run.log`）

`X3a` の `own lost=1` は、`X2b` の確かめの短い接続が閉じた分で、持ち続けた own の接続は切れていない（ログの順で確かめた）。

| ID | 場面 | 結果 |
|---|---|---|
| X1 | 両方の CA の CRL が有効 | own・vendor とも接続できる |
| X2a | vendor の CRL が切れた後、読み直す前の既存の接続 | 切れない |
| X2b・X2c | 読み直す前の新しい接続 | own は受け入れ、vendor は `CRL has expired` で拒否 |
| X3a | `SIGHUP` の後の既存の接続 | 切れるのは vendor だけ。own は残る |
| X3b・X3c | `SIGHUP` の後の新しい接続 | own は受け入れ、vendor は拒否 |
| H1 | `host` を 2 行にしたブロックに、2 行目の範囲から | 受け入れ（複数行が効く） |
| H2 | 証明書は正しいが、そのブロックの範囲の外 | 拒否（別のブロックが範囲に合えば TLS までは進むが、`no matching TLS client`） |
| H3 | どのブロックの範囲にも入らない送信元 | TLS で応じない（`ignoring unknown TLS client`。証明書も見せない） |
| S1・S2 | 同じ Subject で鍵の違う CA を 2 つ束に入れ、それぞれの正当な AP | **a は受け入れ、b は拒否** |
| S3・S4 | それぞれの失効した AP | 拒否 |

X1〜X3 は、自己署名のみの束と `PartialChain on` の束で同じ結果だった。

## 分かったことと反映

- CRL の確認は発行者の CA ごとに独立していて、1 つの CA の CRL が切れてもほかの CA の AP を巻き込まない。radsec-edge は失効の反映を優先し、持ち込みの CA の CRL が切れていても別の CA の新しい CRL を読み込ませる（radsec-edge の設計概要 §24.5）。
- 同じ Subject の CA は束に並べられないので、radsec-edge は断る（§24.3）。拒否の仕組みまでは調べていない（OpenSSL が CA を名前で探すためと推測している）。
- 範囲外の送信元に TLS で応じないので、送信元の範囲は受け口を狭める効果がある（§24.3）。

radsec-edge の結合の試験 `TestDockerTrust` は、X の場面を生成した設定で確かめる。

## 確かめていないもの

実物の業者の CA と証明書（概要 §19 の 2）。IPv6 の送信元（設定の構文だけを `radsecproxy -p` で確かめた）。
