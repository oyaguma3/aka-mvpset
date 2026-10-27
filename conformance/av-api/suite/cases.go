package suite

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json/v2"
	"fmt"
	"maps"
	"math/big"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/oyaguma3/aka-mvpset/conformance/av-api/fixture"
)

// 契約 §9 の cause。
const (
	causeInvalidMsgFormat     = "INVALID_MSG_FORMAT"
	causeMandatoryIEMissing   = "MANDATORY_IE_MISSING"
	causeMandatoryIEIncorrect = "MANDATORY_IE_INCORRECT"
	causeOptionalIEIncorrect  = "OPTIONAL_IE_INCORRECT"
	causeAuthRejected         = "AUTHENTICATION_REJECTED"
	causeAuthTypeNotSupported = "AUTH_TYPE_NOT_SUPPORTED"
)

var generatedTraceID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// expectProblem は、エラーの応答のステータス・Content-Type・cause を確かめる。
func expectProblem(t *recorder, p *response, status int, cause, what string) bool {
	ok := true
	if p.status != status {
		t.Errorf("%s: ステータスが %d（%d を期待）。本文: %s", what, p.status, status, short(p.body))
		return false
	}
	if !strings.HasPrefix(p.contentType(), "application/problem+json") {
		t.Errorf("%s: Content-Type が %q（application/problem+json を期待）", what, p.contentType())
		ok = false
	}
	pr, err := p.problem()
	if err != nil {
		t.Errorf("%s: %v", what, err)
		return false
	}
	if pr.Cause != cause {
		t.Errorf("%s: cause が %q（%q を期待）", what, pr.Cause, cause)
		ok = false
	}
	return ok
}

// c1 は形の誤り（契約 §9.1 の 400 と 501）を確かめ、加入者の有無で応答が変わらないことを確かめる（§9.2 の判定の順）。
func (r *runner) c1(ctx context.Context, t *recorder) {
	notAllowedAnID := "ETHERNET"
	if r.cfg.NetworkName == notAllowedAnID {
		notAllowedAnID = "WLAN"
	}
	zeroAUTS := strings.Repeat("0", 28)
	cases := []struct {
		name, authType, body string
		status               int
		cause                string
	}{
		{"JSON として読めない", "eap-aka", `{`, 400, causeInvalidMsgFormat},
		{"hssAuthType がない", "eap-aka", `{"numOfRequestedVectors":1}`, 400, causeMandatoryIEMissing},
		{"numOfRequestedVectors がない", "eap-aka", `{"hssAuthType":"EAP_AKA"}`, 400, causeMandatoryIEMissing},
		{"パスとボディの認証タイプが対応しない", "eap-aka", `{"hssAuthType":"UMTS_AKA","numOfRequestedVectors":1}`, 400, causeMandatoryIEIncorrect},
		{"数が 0", "eap-aka", `{"hssAuthType":"EAP_AKA","numOfRequestedVectors":0}`, 400, causeMandatoryIEIncorrect},
		{"数が 6", "eap-aka", `{"hssAuthType":"EAP_AKA","numOfRequestedVectors":6}`, 400, causeMandatoryIEIncorrect},
		{"再同期の RAND の長さが違う", "eap-aka", `{"hssAuthType":"EAP_AKA","numOfRequestedVectors":1,"resynchronizationInfo":{"rand":"00","auts":"` + zeroAUTS + `"}}`, 400, causeOptionalIEIncorrect},
		{"EAP-AKA' で anId がない", "eap-aka-prime", `{"hssAuthType":"EAP_AKA_PRIME","numOfRequestedVectors":1}`, 400, causeMandatoryIEMissing},
		{"許していない anId（" + notAllowedAnID + "）", "eap-aka-prime", `{"hssAuthType":"EAP_AKA_PRIME","numOfRequestedVectors":1,"anId":"` + notAllowedAnID + `"}`, 400, causeOptionalIEIncorrect},
		{"対応していない認証タイプ（eps-aka）", "eps-aka", `{"hssAuthType":"EPS_AKA","numOfRequestedVectors":1}`, 501, causeAuthTypeNotSupported},
	}
	for _, c := range cases {
		for _, imsi := range []string{r.activeIMSI, r.unknownIMSI} {
			p, err := r.post(ctx, r.a, "imsi-"+imsi, c.authType, []byte(c.body), "")
			if err != nil {
				t.Errorf("%s（%s）: %v", c.name, imsi, err)
				continue
			}
			expectProblem(t, p, c.status, c.cause, fmt.Sprintf("%s（%s）", c.name, imsi))
		}
	}
	p, err := r.post(ctx, r.a, "imsi-abc", "eap-aka", mustJSON(request{HssAuthType: "EAP_AKA", NumOfRequestedVectors: 1}), "")
	if err != nil {
		t.Errorf("SUPI の形が違う: %v", err)
		return
	}
	expectProblem(t, p, 400, causeMandatoryIEIncorrect, "SUPI の形が違う（imsi-abc）")
	t.Logf("%d 種類の誤りを、登録した IMSI（%s）と登録していない IMSI（%s）の両方で確かめた", len(cases), r.activeIMSI, r.unknownIMSI)
}

// one は 1 つのベクターを取り、鍵で確かめて SQN とベクターを返す。
func (r *runner) one(ctx context.Context, t *recorder, sub fixture.Subscriber, at [2]string, rs *resync) (uint64, vector, bool) {
	p, err := r.generate(ctx, r.a, sub.IMSI, at, 1, rs)
	if err != nil {
		t.Errorf("%s の %s: %v", sub.IMSI, at[0], err)
		return 0, vector{}, false
	}
	vs, err := p.vectors()
	if err != nil {
		t.Errorf("%s の %s: %v", sub.IMSI, at[0], err)
		return 0, vector{}, false
	}
	if len(vs) != 1 {
		t.Errorf("%s の %s: ベクターが %d 個（1 個を期待）", sub.IMSI, at[0], len(vs))
		return 0, vector{}, false
	}
	sqn, err := checkVector(setOf(sub), vs[0], at, r.cfg.NetworkName)
	if err != nil {
		t.Errorf("%s の %s: %v", sub.IMSI, at[0], err)
		return sqn, vs[0], false
	}
	return sqn, vs[0], true
}

// c2 は EAP-AKA と UMTS-AKA のベクターを鍵で確かめ、SQN が要求のたびに大きくなることを確かめる。
func (r *runner) c2(ctx context.Context, t *recorder) {
	var prev uint64
	for i, at := range [][2]string{eapAka, eapAka, umtsAka} {
		sqn, _, ok := r.one(ctx, t, fixture.ActiveSub, at, nil)
		if !ok {
			return
		}
		if i > 0 && sqn <= prev {
			t.Errorf("%s: SQN が大きくなっていない（前 %012x、今 %012x）", at[0], prev, sqn)
		}
		prev = sqn
	}
	t.Logf("XRES・CK・IK・AUTN の MAC-A が一致し、SQN が増えた（最後 %012x）", prev)
}

// c3 は EAP-AKA' の CK'・IK' を、ネットワーク名で導出した値と比べる。
func (r *runner) c3(ctx context.Context, t *recorder) {
	var prev uint64
	for i := range 2 {
		sqn, _, ok := r.one(ctx, t, fixture.PrimeSub, eapAkaPrime, nil)
		if !ok {
			return
		}
		if i > 0 && sqn <= prev {
			t.Errorf("SQN が大きくなっていない（前 %012x、今 %012x）", prev, sqn)
		}
		prev = sqn
	}
	t.Logf("ネットワーク名 %q で CK'・IK' が一致した", r.cfg.NetworkName)
}

// c4 は 1〜5 のそれぞれで、その数ちょうどのベクターが SQN の小さい順に返ることを確かめる。
func (r *runner) c4(ctx context.Context, t *recorder) {
	var prev uint64
	have := false
	for n := 1; n <= 5; n++ {
		p, err := r.generate(ctx, r.a, r.activeIMSI, eapAka, n, nil)
		if err != nil {
			t.Errorf("数 %d: %v", n, err)
			return
		}
		vs, err := p.vectors()
		if err != nil {
			t.Errorf("数 %d: %v", n, err)
			return
		}
		if len(vs) != n {
			t.Errorf("数 %d: ベクターが %d 個", n, len(vs))
			continue
		}
		for i, v := range vs {
			if r.cfg.BlackBox {
				if _, err := parseVector(v, eapAka); err != nil {
					t.Errorf("数 %d の %d 個目: %v", n, i+1, err)
				}
				continue
			}
			sqn, err := checkVector(setOf(fixture.ActiveSub), v, eapAka, r.cfg.NetworkName)
			if err != nil {
				t.Errorf("数 %d の %d 個目: %v", n, i+1, err)
				continue
			}
			if have && sqn <= prev {
				t.Errorf("数 %d の %d 個目: SQN が小さい順でない（前 %012x、今 %012x）", n, i+1, prev, sqn)
			}
			prev, have = sqn, true
		}
	}
	if r.cfg.BlackBox {
		t.Logf("黒箱なので、数と形だけを確かめた（SQN の並びは鍵が要るので確かめない）")
	}
}

// c5 は再同期を確かめる。試験の側で SQN_MS を決めて AUTS を作り、返ったベクターの SQN が SQN_MS より大きいことを確かめる。
func (r *runner) c5(ctx context.Context, t *recorder) {
	sub := fixture.ActiveSub
	sqn, v, ok := r.one(ctx, t, sub, eapAka, nil)
	if !ok {
		return
	}
	randBytes, _ := hex.DecodeString(v.Rand)
	sqnMS := (sqn + 1<<20) & sqnMask
	auts, err := setOf(sub).AUTS(randBytes, sqnBytes(sqnMS))
	if err != nil {
		t.Errorf("AUTS を作れない: %v", err)
		return
	}
	got, _, ok := r.one(ctx, t, sub, eapAka, &resync{Rand: v.Rand, Auts: hex.EncodeToString(auts)})
	if !ok {
		return
	}
	if got <= sqnMS {
		t.Errorf("再同期の後の SQN %012x が SQN_MS %012x より大きくない", got, sqnMS)
		return
	}
	t.Logf("SQN_MS %012x に対して、再同期の後の SQN は %012x", sqnMS, got)
}

// checkGeneric は一般的な拒否の固定の本文（契約 §9.2）を確かめる。
func checkGeneric(t *recorder, p *response, what string) {
	if !expectProblem(t, p, http.StatusForbidden, causeAuthRejected, what) {
		return
	}
	var m map[string]any
	if err := json.Unmarshal(p.body, &m); err != nil {
		t.Errorf("%s: 本文が読めない: %v", what, err)
		return
	}
	keys := slices.Sorted(maps.Keys(m))
	if !slices.Equal(keys, []string{"cause", "status", "title"}) {
		t.Errorf("%s: 本文の項目が %v（cause・status・title だけを期待。detail は入れない）", what, keys)
	}
}

// c6 は一般的な拒否を確かめる。未登録・許可なし・Inactive・Terminated・AUTS の誤りが同じ本文になり、SQN を進めないこと。
func (r *runner) c6(ctx context.Context, t *recorder) {
	if r.cfg.BlackBox {
		r.checkRejects(ctx, t, []reject{
			{"登録されていない IMSI", r.a, r.unknownIMSI, nil},
			{"クライアント B", r.b, r.activeIMSI, nil},
		})
		return
	}
	sub := fixture.ActiveSub
	s0, _, ok0 := r.one(ctx, t, sub, eapAka, nil)
	s1, v1, ok1 := r.one(ctx, t, sub, eapAka, nil)
	if !ok0 || !ok1 {
		return
	}
	step := s1 - s0
	randBytes, _ := hex.DecodeString(v1.Rand)
	auts, _ := setOf(sub).AUTS(randBytes, sqnBytes(s1+1<<20))
	auts[13] ^= 0xff // MAC-S を壊す
	r.checkRejects(ctx, t, []reject{
		{"登録されていない IMSI", r.a, fixture.UnknownIMSI, nil},
		{"許可されていないクライアント（" + fixture.NotAllowedSub.IMSI + "）", r.a, fixture.NotAllowedSub.IMSI, nil},
		{"クライアント B", r.b, sub.IMSI, nil},
		{"Inactive（" + fixture.InactiveSub.IMSI + "）", r.a, fixture.InactiveSub.IMSI, nil},
		{"Terminated（" + fixture.TerminatedSub.IMSI + "）", r.a, fixture.TerminatedSub.IMSI, nil},
		{"MAC-S の合わない AUTS", r.a, sub.IMSI, &resync{Rand: v1.Rand, Auts: hex.EncodeToString(auts)}},
	})
	s2, _, ok2 := r.one(ctx, t, sub, eapAka, nil)
	if !ok2 {
		return
	}
	if s2-s1 != step {
		t.Errorf("拒否の前後で SQN が進んだ（拒否の前の 1 回の増分 %d、拒否をはさんだ増分 %d）", step, s2-s1)
	} else {
		t.Logf("拒否をはさんでも SQN の増分は %d のまま", step)
	}
}

// reject は一般的な拒否になるはずの要求。
type reject struct {
	name string
	cl   *http.Client
	imsi string
	rs   *resync
}

// checkRejects は、拒否の要求をすべて送り、どれも同じステータス・同じ本文の一般的な拒否であることを確かめる。
func (r *runner) checkRejects(ctx context.Context, t *recorder, rejects []reject) {
	var first []byte
	var firstName string
	same := true
	for _, x := range rejects {
		req := request{HssAuthType: "EAP_AKA", NumOfRequestedVectors: 1, ResynchronizationInfo: x.rs}
		p, err := r.post(ctx, x.cl, "imsi-"+x.imsi, "eap-aka", mustJSON(req), "")
		if err != nil {
			t.Errorf("%s: %v", x.name, err)
			continue
		}
		checkGeneric(t, p, x.name)
		switch {
		case first == nil:
			first, firstName = p.body, x.name
		case !bytes.Equal(first, p.body):
			same = false
			t.Errorf("%s の本文が %s と違う（%s ／ %s）", x.name, firstName, short(p.body), short(first))
		}
	}
	if first != nil && same {
		t.Logf("%d 種類の拒否がすべて同じ本文: %s", len(rejects), short(first))
	}
}

// c7 は同じ加入者に 50 並列で要求し、SQN がすべて異なることを確かめる。
func (r *runner) c7(ctx context.Context, t *recorder) {
	const n = 50
	sqns := make([]uint64, n)
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Go(func() {
			p, err := r.generate(ctx, r.a, fixture.ActiveSub.IMSI, eapAka, 1, nil)
			if err != nil {
				errs[i] = err
				return
			}
			vs, err := p.vectors()
			if err != nil {
				errs[i] = err
				return
			}
			if len(vs) != 1 {
				errs[i] = fmt.Errorf("ベクターが %d 個", len(vs))
				return
			}
			sqns[i], errs[i] = checkVector(setOf(fixture.ActiveSub), vs[0], eapAka, r.cfg.NetworkName)
		})
	}
	wg.Wait()
	seen := map[uint64]int{}
	for i := range n {
		if errs[i] != nil {
			t.Errorf("%d 本目: %v", i+1, errs[i])
			continue
		}
		seen[sqns[i]]++
	}
	for sqn, c := range seen {
		if c > 1 {
			t.Errorf("SQN %012x が %d 回払い出された", sqn, c)
		}
	}
	t.Logf("%d 並列で %d 種類の SQN", n, len(seen))
}

// c8 はトレースID の受け渡し（契約 §11.2）を確かめる。
func (r *runner) c8(ctx context.Context, t *recorder) {
	body := mustJSON(request{HssAuthType: "EAP_AKA", NumOfRequestedVectors: 1})
	supi := "imsi-" + r.activeIMSI
	check := func(what, sent string, b []byte, wantSame bool) {
		p, err := r.post(ctx, r.a, supi, "eap-aka", b, sent)
		if err != nil {
			t.Errorf("%s: %v", what, err)
			return
		}
		got := p.header.Get("X-Trace-ID")
		switch {
		case wantSame && got != sent:
			t.Errorf("%s: X-Trace-ID が %q（%q を期待）", what, got, sent)
		case !wantSame && !generatedTraceID.MatchString(got):
			t.Errorf("%s: 採番した X-Trace-ID が %q（16 進 32 桁を期待）", what, got)
		}
	}
	check("送った値を返す", "conformance-trace-1", body, true)
	check("送らないときは採番する", "", body, false)
	check("形が違うときは採番する", "bad trace id", body, false)
	check("エラーの応答でも返す", "conformance-trace-2", []byte(`{`), true)
}

// c9 は、リクエストの知らない項目を無視することを確かめる。
func (r *runner) c9(ctx context.Context, t *recorder) {
	body := []byte(`{"hssAuthType":"EAP_AKA","numOfRequestedVectors":1,"conformanceUnknownMember":{"x":1}}`)
	p, err := r.post(ctx, r.a, "imsi-"+r.activeIMSI, "eap-aka", body, "")
	if err != nil {
		t.Errorf("%v", err)
		return
	}
	if _, err := p.vectors(); err != nil {
		t.Errorf("知らない項目を足した要求: %v", err)
	}
}

// c10 は、証明書なし・登録していない証明書・TLS 1.1 以下の接続を確かめる。
func (r *runner) c10(ctx context.Context, t *recorder) {
	body := mustJSON(request{HssAuthType: "EAP_AKA", NumOfRequestedVectors: 1})
	supi := "imsi-" + r.activeIMSI
	rejected := func(what string, cl *http.Client) {
		p, err := r.post(ctx, cl, supi, "eap-aka", body, "")
		if err != nil {
			t.Logf("%s: TLS で拒否された（%v）", what, err)
			return
		}
		checkGeneric(t, p, what)
	}
	rejected("証明書なし", newClient(r.cfg, &tls.Config{}))
	unknown, err := selfSignedClient()
	if err != nil {
		t.Errorf("試験用の証明書を作れない: %v", err)
	} else {
		rejected("登録していない証明書", newClient(r.cfg, &tls.Config{Certificates: []tls.Certificate{unknown}}))
	}
	old := newClient(r.cfg, &tls.Config{Certificates: []tls.Certificate{r.cfg.ClientA}, MinVersion: tls.VersionTLS10, MaxVersion: tls.VersionTLS11})
	if p, err := r.post(ctx, old, supi, "eap-aka", body, ""); err == nil {
		t.Errorf("TLS 1.1 以下でつながった（ステータス %d）", p.status)
	} else {
		t.Logf("TLS 1.1 以下: つながらない（%v）", err)
	}
}

// c11 は応答の形（Content-Type、Cache-Control、16 進の小文字、値の長さ）を確かめる。
func (r *runner) c11(ctx context.Context, t *recorder) {
	p, err := r.generate(ctx, r.a, r.activeIMSI, eapAka, 1, nil)
	if err != nil {
		t.Errorf("%v", err)
		return
	}
	if !strings.HasPrefix(p.contentType(), "application/json") {
		t.Errorf("Content-Type が %q（application/json を期待）", p.contentType())
	}
	if cc := p.header.Get("Cache-Control"); !strings.Contains(cc, "no-store") {
		t.Errorf("Cache-Control が %q（no-store を期待）", cc)
	}
	vs, err := p.vectors()
	if err != nil {
		t.Errorf("%v", err)
		return
	}
	for i, v := range vs {
		if _, err := parseVector(v, eapAka); err != nil {
			t.Errorf("%d 個目: %v", i+1, err)
		}
	}
}

// selfSignedClient は、どの取得先にも登録していないクライアント証明書を作る。
func selfSignedClient() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "av-conformance-unregistered"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}
