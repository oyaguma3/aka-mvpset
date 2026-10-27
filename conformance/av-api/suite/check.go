package suite

import (
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"github.com/oyaguma3/aka-mvpset/conformance/av-api/fixture"
	"github.com/oyaguma3/aka-mvpset/conformance/av-api/milenage"
)

const sqnMask = 1<<48 - 1

func setOf(s fixture.Subscriber) milenage.Set {
	k, _ := hex.DecodeString(s.K)
	opc, _ := hex.DecodeString(s.OPc)
	return milenage.Set{K: k, OPc: opc}
}

func sqnBytes(v uint64) []byte {
	b := binary.BigEndian.AppendUint64(nil, v&sqnMask)
	return b[2:]
}

func sqnValue(b []byte) uint64 {
	return binary.BigEndian.Uint64(append([]byte{0, 0}, b...))
}

// hexField は 16 進の項目を確かめて読む。minLen と maxLen はバイト数。
func hexField(name, v string, minLen, maxLen int) ([]byte, error) {
	if v != strings.ToLower(v) {
		return nil, fmt.Errorf("%s が小文字の 16 進でない（%q）", name, v)
	}
	b, err := hex.DecodeString(v)
	if err != nil {
		return nil, fmt.Errorf("%s が 16 進でない（%q）", name, v)
	}
	if len(b) < minLen || len(b) > maxLen {
		return nil, fmt.Errorf("%s の長さが %d バイト（%d〜%d バイトを期待）", name, len(b), minLen, maxLen)
	}
	return b, nil
}

// vectorBytes はベクターの値の形（16 進の小文字、長さ、avType）を確かめて読む。
type vectorBytes struct {
	rand, xres, autn, k1, k2 []byte // k1・k2 は CK・IK か CK'・IK'
}

func parseVector(v vector, at [2]string) (vectorBytes, error) {
	var vb vectorBytes
	var errs []error
	if v.AvType != at[1] {
		errs = append(errs, fmt.Errorf("avType が %q（%q を期待）", v.AvType, at[1]))
	}
	field := func(name, s string, minLen, maxLen int) []byte {
		b, err := hexField(name, s, minLen, maxLen)
		if err != nil {
			errs = append(errs, err)
		}
		return b
	}
	vb.rand = field("rand", v.Rand, 16, 16)
	vb.xres = field("xres", v.Xres, 4, 16)
	vb.autn = field("autn", v.Autn, 16, 16)
	if at == eapAkaPrime {
		vb.k1 = field("ckPrime", v.CkPrime, 16, 16)
		vb.k2 = field("ikPrime", v.IkPrime, 16, 16)
	} else {
		vb.k1 = field("ck", v.Ck, 16, 16)
		vb.k2 = field("ik", v.Ik, 16, 16)
	}
	return vb, errors.Join(errs...)
}

// checkVector は、試験用の加入者の鍵でベクターの値を計算し直して比べ、AUTN から取り出した SQN を返す。
func checkVector(set milenage.Set, v vector, at [2]string, networkName string) (uint64, error) {
	vb, err := parseVector(v, at)
	if err != nil {
		return 0, err
	}
	res, ck, ik, ak, err := set.F2345(vb.rand)
	if err != nil {
		return 0, err
	}
	sqn := make([]byte, 6)
	subtle.XORBytes(sqn, vb.autn[0:6], ak)
	macA, _, err := set.F1(vb.rand, sqn, vb.autn[6:8])
	if err != nil {
		return 0, err
	}
	var errs []error
	if subtle.ConstantTimeCompare(macA, vb.autn[8:16]) != 1 {
		errs = append(errs, errors.New("AUTN の MAC-A が鍵から計算した値と合わない"))
	}
	if subtle.ConstantTimeCompare(res, vb.xres) != 1 {
		errs = append(errs, errors.New("xres が鍵から計算した RES と合わない"))
	}
	want1, want2 := ck, ik
	if at == eapAkaPrime {
		want1, want2, err = milenage.DerivePrime(ck, ik, networkName, vb.autn[0:6])
		if err != nil {
			return 0, err
		}
	}
	if subtle.ConstantTimeCompare(want1, vb.k1) != 1 || subtle.ConstantTimeCompare(want2, vb.k2) != 1 {
		if at == eapAkaPrime {
			errs = append(errs, fmt.Errorf("ckPrime・ikPrime がネットワーク名 %q で導出した値と合わない", networkName))
		} else {
			errs = append(errs, errors.New("ck・ik が鍵から計算した値と合わない"))
		}
	}
	return sqnValue(sqn), errors.Join(errs...)
}
