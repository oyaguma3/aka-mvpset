// Package fixture は適合試験の試験用の加入者の表（認証ベクターAPI の契約 §14.1）を持つ。
//
// 取得先の実装は、この表の加入者を自分の管理の手段で先に入れておく。鍵は 3GPP TS 35.208 の試験セットから取った。
// 公開してよい試験用の値で、本物の SIM の鍵ではない。
package fixture

// 状態の値（aka-vecgen の決定事項 2 と同じ書き方）。
const (
	Active     = "active"
	Inactive   = "inactive"
	Terminated = "terminated"
)

// Subscriber は試験用の加入者。
type Subscriber struct {
	IMSI    string
	TestSet int    // TS 35.208 の試験セットの番号
	K, OPc  string // 16 進
	AMF     string // 16 進 4 桁。すべて separation bit を 1 にする（EAP-AKA' で使えるように）
	State   string
	AllowA  bool // クライアント A に払い出しを許すか（クライアント B にはどの加入者も許さない）
	Purpose string
}

// 試験用の加入者。試験用の PLMN 00101 の IMSI を使う。
var (
	ActiveSub = Subscriber{
		IMSI: "001010000000001", TestSet: 1,
		K: "465b5ce8b199b49faa5f0a2ee238a6bc", OPc: "cd63cb71954a9f4e48a5994e37a02baf",
		AMF: "8000", State: Active, AllowA: true, Purpose: "EAP-AKA・UMTS-AKA・数・再同期・同時の要求",
	}
	PrimeSub = Subscriber{
		IMSI: "001010000000002", TestSet: 3,
		K: "fec86ba6eb707ed08905757b1bb44b8f", OPc: "1006020f0a478bf6b699f15c062e42b3",
		AMF: "8000", State: Active, AllowA: true, Purpose: "EAP-AKA'",
	}
	InactiveSub = Subscriber{
		IMSI: "001010000000003", TestSet: 4,
		K: "9e5944aea94b81165c82fbf9f32db751", OPc: "a64a507ae1a2a98bb88eb4210135dc87",
		AMF: "8000", State: Inactive, AllowA: true, Purpose: "Inactive の一般的な拒否",
	}
	TerminatedSub = Subscriber{
		IMSI: "001010000000004", TestSet: 5,
		K: "4ab1deb05ca6ceb051fc98e77d026a84", OPc: "dcf07cbd51855290b92a07a9891e523e",
		AMF: "8000", State: Terminated, AllowA: true, Purpose: "Terminated の一般的な拒否",
	}
	NotAllowedSub = Subscriber{
		IMSI: "001010000000005", TestSet: 6,
		K: "6c38a116ac280c454f59332ee35c8c4f", OPc: "3803ef5363b947c6aaa225e58fae3934",
		AMF: "8000", State: Active, AllowA: false, Purpose: "許可されていないクライアントの一般的な拒否",
	}
)

// UnknownIMSI は登録しない IMSI。
const UnknownIMSI = "001010000000099"

// All は登録する試験用の加入者（登録しない IMSI を除く）。
func All() []Subscriber {
	return []Subscriber{ActiveSub, PrimeSub, InactiveSub, TerminatedSub, NotAllowedSub}
}
