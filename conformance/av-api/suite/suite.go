// Package suite は認証ベクターAPI の適合試験（契約 §14）を行う。
//
// 試験は認証ベクターAPI だけを話す。試験用の加入者（fixture）は、取得先の実装が自分の手段で先に入れておく。
package suite

import (
	"bytes"
	"cmp"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json/v2"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/oyaguma3/aka-mvpset/conformance/av-api/fixture"
)

// Config は試験の入力。
type Config struct {
	BaseURL     string         // 例 https://aka-vecgen:8443/nudm-ueau/v1
	RootCAs     *x509.CertPool // 取得先のサーバー証明書を確かめる CA
	ClientA     tls.Certificate
	ClientB     tls.Certificate // 黒箱で使わないときは空でよい
	NetworkName string          // クライアント A に許したネットワーク名（既定 WLAN）
	Timeout     time.Duration   // 要求 1 回のタイムアウト

	// BlackBox は鍵を使わない項目だけを行う（試験用の加入者を入れられない外部の取得先のため。契約 §14.2 の注）。
	BlackBox    bool
	ActiveIMSI  string // 黒箱: クライアント A に払い出しを許した Active の IMSI
	UnknownIMSI string // 黒箱: 登録されていない IMSI

	Cases []string // 行う項目（例 C1、C6）。空ならすべて
}

// Status は項目の結果。
type Status string

const (
	Pass Status = "PASS"
	Fail Status = "FAIL"
	Skip Status = "SKIP"
)

// Result は 1 つの項目の結果。
type Result struct {
	ID     string
	Title  string
	Status Status
	Notes  []string
}

// recorder は 1 つの項目の中で、誤りと記録を集める。
type recorder struct {
	notes  []string
	failed bool
	skip   string
}

func (r *recorder) Errorf(format string, args ...any) {
	r.failed = true
	r.notes = append(r.notes, "誤り: "+fmt.Sprintf(format, args...))
}

func (r *recorder) Logf(format string, args ...any) {
	r.notes = append(r.notes, fmt.Sprintf(format, args...))
}

func (r *recorder) Skipf(format string, args ...any) { r.skip = fmt.Sprintf(format, args...) }

type testCase struct {
	id, title string
	blackBox  bool // 黒箱でも行う
	run       func(r *runner, ctx context.Context, t *recorder)
}

var cases = []testCase{
	{"C1", "形の誤り（400・501）と、加入者の有無で応答が変わらないこと", true, (*runner).c1},
	{"C2", "EAP-AKA と UMTS-AKA のベクターの値と SQN の増加", false, (*runner).c2},
	{"C3", "EAP-AKA' の CK'・IK'", false, (*runner).c3},
	{"C4", "ベクターの数（1〜5）と並び", true, (*runner).c4},
	{"C5", "再同期", false, (*runner).c5},
	{"C6", "一般的な拒否（同じステータス・同じ本文、SQN を進めない）", true, (*runner).c6},
	{"C7", "同時の要求で SQN が重ならないこと", false, (*runner).c7},
	{"C8", "トレースID の受け渡し", true, (*runner).c8},
	{"C9", "知らない項目を無視すること", true, (*runner).c9},
	{"C10", "接続（証明書なし・登録していない証明書・TLS 1.1 以下）", true, (*runner).c10},
	{"C11", "応答の形（Content-Type、Cache-Control、16 進の小文字、値の長さ）", true, (*runner).c11},
}

// Run は試験を行い、項目ごとの結果を返す。
func Run(ctx context.Context, cfg Config) []Result {
	r := newRunner(cfg)
	var results []Result
	for _, tc := range cases {
		if len(cfg.Cases) > 0 && !slices.Contains(cfg.Cases, tc.id) {
			continue
		}
		res := Result{ID: tc.id, Title: tc.title}
		if cfg.BlackBox && !tc.blackBox {
			res.Status = Skip
			res.Notes = []string{"鍵を使う項目なので、黒箱では行わない"}
			results = append(results, res)
			continue
		}
		t := &recorder{}
		tc.run(r, ctx, t)
		res.Notes = t.notes
		switch {
		case t.failed:
			res.Status = Fail
		case t.skip != "":
			res.Status = Skip
			res.Notes = append(res.Notes, t.skip)
		default:
			res.Status = Pass
		}
		results = append(results, res)
	}
	return results
}

type runner struct {
	cfg         Config
	a, b        *http.Client
	activeIMSI  string
	unknownIMSI string
}

func newRunner(cfg Config) *runner {
	cfg.NetworkName = cmp.Or(cfg.NetworkName, "WLAN")
	cfg.Timeout = cmp.Or(cfg.Timeout, 5*time.Second)
	cfg.BaseURL = strings.TrimSuffix(cfg.BaseURL, "/")
	r := &runner{
		cfg:         cfg,
		a:           newClient(cfg, &tls.Config{Certificates: []tls.Certificate{cfg.ClientA}}),
		b:           newClient(cfg, &tls.Config{Certificates: []tls.Certificate{cfg.ClientB}}),
		activeIMSI:  fixture.ActiveSub.IMSI,
		unknownIMSI: fixture.UnknownIMSI,
	}
	if cfg.BlackBox {
		r.activeIMSI, r.unknownIMSI = cfg.ActiveIMSI, cfg.UnknownIMSI
	}
	return r
}

// newClient は、取得先の CA を信頼し、tc の証明書と TLS の版を使う HTTP のクライアントを作る。
func newClient(cfg Config, tc *tls.Config) *http.Client {
	tc.RootCAs = cfg.RootCAs
	if tc.MinVersion == 0 {
		tc.MinVersion = tls.VersionTLS12
	}
	return &http.Client{
		Timeout:   cfg.Timeout,
		Transport: &http.Transport{TLSClientConfig: tc, ForceAttemptHTTP2: true, MaxIdleConnsPerHost: 64},
	}
}

// response は取得先の応答。
type response struct {
	status int
	header http.Header
	body   []byte
}

func (p *response) contentType() string { return p.header.Get("Content-Type") }

// post は GenerateAv を呼ぶ。supi は `imsi-<IMSI>` の形のまま渡す（形の誤りの試験のため）。
func (r *runner) post(ctx context.Context, cl *http.Client, supi, authType string, body []byte, traceID string) (*response, error) {
	u := fmt.Sprintf("%s/%s/hss-security-information/%s/generate-av", r.cfg.BaseURL, supi, authType)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if traceID != "" {
		req.Header.Set("X-Trace-ID", traceID)
	}
	resp, err := cl.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return &response{status: resp.StatusCode, header: resp.Header, body: b}, nil
}

// request は GenerateAv の本文。
type request struct {
	HssAuthType           string  `json:"hssAuthType,omitempty"`
	NumOfRequestedVectors int     `json:"numOfRequestedVectors,omitzero"`
	ResynchronizationInfo *resync `json:"resynchronizationInfo,omitempty"`
	AnID                  string  `json:"anId,omitempty"`
}

type resync struct {
	Rand string `json:"rand"`
	Auts string `json:"auts"`
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// authTypes は認証タイプのパスとボディの値の組。
var (
	eapAka      = [2]string{"eap-aka", "EAP_AKA"}
	umtsAka     = [2]string{"umts-aka", "UMTS_AKA"}
	eapAkaPrime = [2]string{"eap-aka-prime", "EAP_AKA_PRIME"}
)

// generate は正しい形の要求を送る。
func (r *runner) generate(ctx context.Context, cl *http.Client, imsi string, at [2]string, n int, rs *resync) (*response, error) {
	req := request{HssAuthType: at[1], NumOfRequestedVectors: n, ResynchronizationInfo: rs}
	if at == eapAkaPrime {
		req.AnID = r.cfg.NetworkName
	}
	return r.post(ctx, cl, "imsi-"+imsi, at[0], mustJSON(req), "")
}

// vector は応答の 1 つのベクター。
type vector struct {
	AvType  string `json:"avType"`
	Rand    string `json:"rand"`
	Xres    string `json:"xres"`
	Autn    string `json:"autn"`
	Ck      string `json:"ck"`
	Ik      string `json:"ik"`
	CkPrime string `json:"ckPrime"`
	IkPrime string `json:"ikPrime"`
}

type result struct {
	Vectors []vector `json:"hssAuthenticationVectors"`
}

// vectors は 200 の応答からベクターを取り出す。
func (p *response) vectors() ([]vector, error) {
	if p.status != http.StatusOK {
		return nil, fmt.Errorf("ステータスが %d（200 を期待）。本文: %s", p.status, short(p.body))
	}
	var res result
	if err := json.Unmarshal(p.body, &res); err != nil {
		return nil, fmt.Errorf("応答の JSON が読めない: %v", err)
	}
	return res.Vectors, nil
}

// problem はエラーの本文。
type problem struct {
	Title  string `json:"title"`
	Status int    `json:"status"`
	Detail string `json:"detail"`
	Cause  string `json:"cause"`
}

func (p *response) problem() (problem, error) {
	var pr problem
	if err := json.Unmarshal(p.body, &pr); err != nil {
		return pr, fmt.Errorf("エラーの本文の JSON が読めない: %v（本文: %s）", err, short(p.body))
	}
	return pr, nil
}

func short(b []byte) string {
	s := string(b)
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}
