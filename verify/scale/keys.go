package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"fmt"
	"io"
	"os"
)

// 規模の試験の加入者（確認事項 L6-3）。IMSI は imsiPrefix に 8 桁の番号を付けたもの（1〜200,000 と、③ の 1 万件）。
// Ki・OPc は種（32 バイトの乱数のファイル）から IMSI ごとに HMAC-SHA256 で決める。一括投入の CSV と負荷の道具が同じ値を作れるので、
// 20 万件の鍵のファイルを持ち回らない。種は一時の VPS と手元にだけ置く（手元は試験の後に gpg で暗号化して残す）。
const imsiPrefix = "4401080"

// imsiOf は番号 n の IMSI を返す。
func imsiOf(n int) string { return fmt.Sprintf("%s%08d", imsiPrefix, n) }

// readSeed は種のファイルを読む（32 バイトちょうど）。
func readSeed(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b) != 32 {
		return nil, fmt.Errorf("種のファイル %s は 32 バイトでない（%d バイト）。head -c 32 /dev/urandom で作る", path, len(b))
	}
	return b, nil
}

// keysOf は種と IMSI から Ki と OPc（どちらも 16 バイト）を決める。
func keysOf(seed []byte, imsi string) (ki, opc []byte) {
	sum := func(label string) []byte {
		m := hmac.New(sha256.New, seed)
		m.Write([]byte("aka-mvpset/verify/scale/" + label + "/" + imsi))
		return m.Sum(nil)[:16]
	}
	return sum("ki"), sum("opc")
}

// writeCSV は一括投入の CSV（aka-ossbss の運用ガイド 6 章）を書く。vecgen は imsi,ki,opc,amf,sqn（amf・sqn は空にして既定）、radius は imsi だけ。
func writeCSV(w io.Writer, kind string, seed []byte, from, to int) error {
	cw := csv.NewWriter(w)
	cw.UseCRLF = false
	switch kind {
	case "vecgen":
		if err := cw.Write([]string{"imsi", "ki", "opc", "amf", "sqn"}); err != nil {
			return err
		}
		for n := from; n <= to; n++ {
			imsi := imsiOf(n)
			ki, opc := keysOf(seed, imsi)
			if err := cw.Write([]string{imsi, hex.EncodeToString(ki), hex.EncodeToString(opc), "", ""}); err != nil {
				return err
			}
		}
	case "radius":
		if err := cw.Write([]string{"imsi"}); err != nil {
			return err
		}
		for n := from; n <= to; n++ {
			if err := cw.Write([]string{imsiOf(n)}); err != nil {
				return err
			}
		}
	default:
		return fmt.Errorf("種類は vecgen か radius（%q）", kind)
	}
	cw.Flush()
	return cw.Error()
}
