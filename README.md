# aka-mvpset

EAP-AKA の RADIUS 認証の PoC セット（[eapaka-pocset](https://github.com/oyaguma3/eapaka-pocset) の `pocset-v1.0.0`）と、RadSec の受け口 [radsec-edge](https://github.com/oyaguma3/radsec-edge)・独立CA [radsec-ca](https://github.com/oyaguma3/radsec-ca) をもとに、VPS に分けて置いて顧客を収容できる **MVP セット**を作るためのリポジトリ。要件・構成・API の契約・試験・組み合わせの表を置く。

- 状態: 検討と設計の段階（要件と構成の概要の下書き）。
- 個人の検証用であり、商用の運用を保証するものではない。

## 文書

| ファイル | 内容 |
|---|---|
| [docs/requirements-overview.md](docs/requirements-overview.md) | 要件と構成の概要（決定事項、規模、構成、データ、契約、一括投入、運用、進め方） |
| [verify/n1/](verify/n1/README.md) | エッジの 1 テナントあたりのメモリーの計測（道具と結果） |

## ライセンス

MIT（`LICENSE`）。
