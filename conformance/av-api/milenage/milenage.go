// Package milenage は、適合試験が取得先の返したベクターを確かめるための Milenage（3GPP TS 35.206）を実装する。
//
// 取得先の実装と同じライブラリを使うと、ライブラリの誤りを見逃すので、標準ライブラリの AES だけで自前で書く。
// 正しさは TS 35.208 の試験セットで確かめる（milenage_test.go）。
package milenage

import (
	"crypto/aes"
	"crypto/subtle"
	"fmt"
)

// Set は 1 つの加入者の鍵（K と OPc）。OP は扱わない（MVP セットは常に OPc で持つ）。
type Set struct {
	K   []byte
	OPc []byte
}

// 回転量（ビット）と定数 c1〜c5（TS 35.206 4.1 の既定値）。
var (
	rot = [5]int{64, 0, 32, 64, 96}
	cst = [5]byte{0, 1, 2, 4, 8} // c の最後のバイトだけが 0 でない
)

// F1 は f1（MAC-A）と f1*（MAC-S）を返す。sqn は 6 バイト、amf は 2 バイト。
func (s Set) F1(rand, sqn, amf []byte) (macA, macS []byte, err error) {
	if len(sqn) != 6 || len(amf) != 2 {
		return nil, nil, fmt.Errorf("milenage: SQN は 6 バイト、AMF は 2 バイト（%d、%d）", len(sqn), len(amf))
	}
	temp, err := s.temp(rand)
	if err != nil {
		return nil, nil, err
	}
	in1 := make([]byte, 16)
	copy(in1[0:6], sqn)
	copy(in1[6:8], amf)
	copy(in1[8:14], sqn)
	copy(in1[14:16], amf)
	out, err := s.out(temp, in1, 0)
	if err != nil {
		return nil, nil, err
	}
	return out[0:8], out[8:16], nil
}

// F2345 は f2（RES）、f3（CK）、f4（IK）、f5（AK）を返す。
func (s Set) F2345(rand []byte) (res, ck, ik, ak []byte, err error) {
	temp, err := s.temp(rand)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	out2, err := s.out(temp, temp, 1)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	out3, err := s.out(temp, temp, 2)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	out4, err := s.out(temp, temp, 3)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	return out2[8:16], out3, out4, out2[0:6], nil
}

// F5Star は f5*（再同期の AK）を返す。
func (s Set) F5Star(rand []byte) ([]byte, error) {
	temp, err := s.temp(rand)
	if err != nil {
		return nil, err
	}
	out5, err := s.out(temp, temp, 4)
	if err != nil {
		return nil, err
	}
	return out5[0:6], nil
}

// AUTS は、端末が再同期のときに作る AUTS（(SQN_MS ⊕ AK*) ‖ MAC-S）を作る。
// MAC-S は AMF を 0x0000 として計算する（TS 33.102 6.3.3）。
func (s Set) AUTS(rand, sqnMS []byte) ([]byte, error) {
	aks, err := s.F5Star(rand)
	if err != nil {
		return nil, err
	}
	_, macS, err := s.F1(rand, sqnMS, []byte{0, 0})
	if err != nil {
		return nil, err
	}
	auts := make([]byte, 14)
	subtle.XORBytes(auts[0:6], sqnMS, aks)
	copy(auts[6:], macS)
	return auts, nil
}

// temp は TEMP = E_K(RAND ⊕ OPc) を返す。
func (s Set) temp(rand []byte) ([]byte, error) {
	if len(s.K) != 16 || len(s.OPc) != 16 || len(rand) != 16 {
		return nil, fmt.Errorf("milenage: K・OPc・RAND は 16 バイト（%d、%d、%d）", len(s.K), len(s.OPc), len(rand))
	}
	x := make([]byte, 16)
	subtle.XORBytes(x, rand, s.OPc)
	return s.encrypt(x)
}

// out は OUTi = E_K(rot(in ⊕ OPc, ri) ⊕ ci) ⊕ OPc を返す。
// f1 では in に IN1 を渡し、その結果に TEMP を足してから暗号化する（TS 35.206 4.1）。
// f2〜f5* では in に TEMP を渡す。
func (s Set) out(temp, in []byte, i int) ([]byte, error) {
	x := make([]byte, 16)
	subtle.XORBytes(x, in, s.OPc)
	x = rotate(x, rot[i])
	x[15] ^= cst[i]
	if i == 0 {
		subtle.XORBytes(x, x, temp)
	}
	y, err := s.encrypt(x)
	if err != nil {
		return nil, err
	}
	subtle.XORBytes(y, y, s.OPc)
	return y, nil
}

func (s Set) encrypt(x []byte) ([]byte, error) {
	b, err := aes.NewCipher(s.K)
	if err != nil {
		return nil, fmt.Errorf("milenage: %w", err)
	}
	y := make([]byte, 16)
	b.Encrypt(y, x)
	return y, nil
}

// rotate は 128 ビットの値を bits ビットだけ左に巡回させる（bits は 8 の倍数）。
func rotate(x []byte, bits int) []byte {
	n := bits / 8
	out := make([]byte, 16)
	for i := range 16 {
		out[i] = x[(i+n)%16]
	}
	return out
}
