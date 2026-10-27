package milenage

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
)

// DerivePrime は EAP-AKA' の CK' と IK' を導出する（TS 33.402 Annex A.2、RFC 5448 §3.3）。
// sqnXorAK は AUTN の先頭 6 バイト。
//
//	CK' ‖ IK' = HMAC-SHA-256(CK ‖ IK, FC ‖ P0 ‖ L0 ‖ P1 ‖ L1)
//	FC = 0x20、P0 = ネットワーク名、P1 = SQN ⊕ AK、L0・L1 は 2 バイトの長さ
func DerivePrime(ck, ik []byte, networkName string, sqnXorAK []byte) (ckPrime, ikPrime []byte, err error) {
	if len(ck) != 16 || len(ik) != 16 || len(sqnXorAK) != 6 {
		return nil, nil, fmt.Errorf("milenage: CK・IK は 16 バイト、SQN⊕AK は 6 バイト（%d、%d、%d）", len(ck), len(ik), len(sqnXorAK))
	}
	s := []byte{0x20}
	s = append(s, networkName...)
	s = binary.BigEndian.AppendUint16(s, uint16(len(networkName)))
	s = append(s, sqnXorAK...)
	s = binary.BigEndian.AppendUint16(s, 6)

	mac := hmac.New(sha256.New, append(append([]byte{}, ck...), ik...))
	mac.Write(s)
	out := mac.Sum(nil)
	return out[0:16], out[16:32], nil
}
