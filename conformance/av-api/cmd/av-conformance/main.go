// av-conformance は認証ベクターAPI の適合試験（aka-mvpset の docs/av-api-contract.md §14）を行うコマンド。
//
// 使い方は conformance/av-api/README.md を見る。すべての項目が PASS か SKIP なら 0、FAIL があれば 1、
// 引数の誤りなどで試験を始められなければ 2 で終わる。
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/oyaguma3/aka-mvpset/conformance/av-api/fixture"
	"github.com/oyaguma3/aka-mvpset/conformance/av-api/suite"
)

func main() {
	os.Exit(run())
}

func run() int {
	var (
		baseURL     = flag.String("url", "", "取得先の基底の URL（例 https://aka-vecgen:8443/nudm-ueau/v1）")
		caFile      = flag.String("ca", "", "取得先のサーバー証明書を確かめる CA の PEM")
		certA       = flag.String("cert-a", "", "クライアント A の証明書の PEM（鍵を同じファイルに含めてよい）")
		keyA        = flag.String("key-a", "", "クライアント A の鍵の PEM（省略時は -cert-a のファイル）")
		certB       = flag.String("cert-b", "", "クライアント B の証明書の PEM（どの加入者にも許可しないクライアント）")
		keyB        = flag.String("key-b", "", "クライアント B の鍵の PEM（省略時は -cert-b のファイル）")
		networkName = flag.String("network-name", "WLAN", "クライアント A に許したネットワーク名")
		blackBox    = flag.Bool("blackbox", false, "鍵を使わない項目だけを行う（試験用の加入者を入れられない外部の取得先のため）")
		activeIMSI  = flag.String("active-imsi", "", "黒箱: クライアント A に払い出しを許した Active の IMSI")
		unknownIMSI = flag.String("unknown-imsi", "", "黒箱: 登録されていない IMSI")
		only        = flag.String("cases", "", "行う項目をカンマ区切りで（例 C1,C6）。省略時はすべて")
		timeout     = flag.Duration("timeout", 5*time.Second, "要求 1 回のタイムアウト")
		fixtures    = flag.Bool("fixtures", false, "試験用の加入者の表をタブ区切りで出して終わる（IMSI、K、OPc、AMF、状態、クライアント A への許可）")
	)
	flag.Parse()

	if *fixtures {
		for _, s := range fixture.All() {
			fmt.Printf("%s\t%s\t%s\t%s\t%s\t%t\n", s.IMSI, s.K, s.OPc, s.AMF, s.State, s.AllowA)
		}
		return 0
	}

	cfg, err := config(*baseURL, *caFile, *certA, *keyA, *certB, *keyB)
	if err != nil {
		fmt.Fprintln(os.Stderr, "av-conformance:", err)
		return 2
	}
	cfg.NetworkName = *networkName
	cfg.Timeout = *timeout
	cfg.BlackBox = *blackBox
	cfg.ActiveIMSI, cfg.UnknownIMSI = *activeIMSI, *unknownIMSI
	if cfg.BlackBox && (cfg.ActiveIMSI == "" || cfg.UnknownIMSI == "") {
		fmt.Fprintln(os.Stderr, "av-conformance: 黒箱では -active-imsi と -unknown-imsi が要る")
		return 2
	}
	if *only != "" {
		cfg.Cases = strings.Split(*only, ",")
	}

	results := suite.Run(context.Background(), cfg)
	counts := map[suite.Status]int{}
	for _, r := range results {
		counts[r.Status]++
		fmt.Printf("%-4s %-4s %s\n", r.ID, r.Status, r.Title)
		for _, n := range r.Notes {
			fmt.Printf("          %s\n", n)
		}
	}
	fmt.Printf("== 結果: PASS %d、FAIL %d、SKIP %d\n", counts[suite.Pass], counts[suite.Fail], counts[suite.Skip])
	if counts[suite.Fail] > 0 {
		return 1
	}
	return 0
}

func config(baseURL, caFile, certA, keyA, certB, keyB string) (suite.Config, error) {
	var cfg suite.Config
	if baseURL == "" || caFile == "" || certA == "" {
		return cfg, errors.New("-url、-ca、-cert-a は必須")
	}
	cfg.BaseURL = baseURL
	ca, err := os.ReadFile(caFile)
	if err != nil {
		return cfg, err
	}
	cfg.RootCAs = x509.NewCertPool()
	if !cfg.RootCAs.AppendCertsFromPEM(ca) {
		return cfg, fmt.Errorf("%s に証明書がない", caFile)
	}
	if cfg.ClientA, err = loadPair(certA, keyA); err != nil {
		return cfg, fmt.Errorf("クライアント A: %w", err)
	}
	if certB != "" {
		if cfg.ClientB, err = loadPair(certB, keyB); err != nil {
			return cfg, fmt.Errorf("クライアント B: %w", err)
		}
	}
	return cfg, nil
}

// loadPair は証明書と鍵を読む。鍵のファイルを省くと、証明書のファイルから鍵も読む。
func loadPair(certFile, keyFile string) (tls.Certificate, error) {
	if keyFile == "" {
		keyFile = certFile
	}
	return tls.LoadX509KeyPair(certFile, keyFile)
}
