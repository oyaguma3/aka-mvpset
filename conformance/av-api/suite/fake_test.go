package suite

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json/v2"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sync"
	"testing"
	"time"

	"github.com/oyaguma3/aka-mvpset/conformance/av-api/fixture"
	"github.com/oyaguma3/aka-mvpset/conformance/av-api/milenage"
)

// fakeServer は契約どおりに振る舞う取得先の偽物（適合試験そのものを確かめるため）。
// bug を設定すると、わざと契約から外れた振る舞いをする。
type fakeServer struct {
	mu          sync.Mutex
	subs        map[string]*fakeSub
	clients     map[[32]byte]string // フィンガープリント → "A" / "B"
	networkName string
	bug         string
}

type fakeSub struct {
	set    milenage.Set
	amf    []byte
	state  string
	allowA bool
	sqn    uint64
}

// 偽物に入れられる誤り。
const (
	bugNotFound404     = "not-found-404"     // 未登録に 404 を返す
	bugNoCacheControl  = "no-cache-control"  // Cache-Control を付けない
	bugAdvanceOnReject = "advance-on-reject" // クライアント B の拒否でも SQN を進める
	bugWrongPrime      = "wrong-prime"       // CK'・IK' を別のネットワーク名で導出する
)

var (
	traceIDPattern = regexp.MustCompile(`^[\x21-\x7E]{1,64}$`)
	supiPattern    = regexp.MustCompile(`^imsi-[0-9]{5,15}$`)
	genericBody    = []byte(`{"title":"Forbidden","status":403,"cause":"AUTHENTICATION_REJECTED"}`)
)

func newFakeServer(a, b tls.Certificate, bug string) *fakeServer {
	f := &fakeServer{
		subs:        map[string]*fakeSub{},
		clients:     map[[32]byte]string{sha256.Sum256(a.Certificate[0]): "A", sha256.Sum256(b.Certificate[0]): "B"},
		networkName: "WLAN",
		bug:         bug,
	}
	for _, s := range fixture.All() {
		amf, _ := hex.DecodeString(s.AMF)
		f.subs[s.IMSI] = &fakeSub{set: setOf(s), amf: amf, state: s.State, allowA: s.AllowA}
	}
	return f
}

func (f *fakeServer) tlsConfig(server tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{server},
		MinVersion:   tls.VersionTLS12,
		ClientAuth:   tls.RequireAnyClientCert,
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			if _, ok := f.clients[sha256.Sum256(raw[0])]; !ok {
				return errors.New("登録していないクライアント証明書")
			}
			return nil
		},
	}
}

func (f *fakeServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /nudm-ueau/v1/{supi}/hss-security-information/{type}/generate-av", f.generate)
	return mux
}

func (f *fakeServer) problem(w http.ResponseWriter, status int, cause string) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	json.MarshalWrite(w, map[string]any{"title": http.StatusText(status), "status": status, "cause": cause, "detail": "fake"})
}

func (f *fakeServer) generic(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(http.StatusForbidden)
	w.Write(genericBody)
}

func (f *fakeServer) generate(w http.ResponseWriter, r *http.Request) {
	traceID := r.Header.Get("X-Trace-ID")
	if !traceIDPattern.MatchString(traceID) {
		traceID = hex.EncodeToString(randBytes(16))
	}
	w.Header().Set("X-Trace-ID", traceID)
	client := f.clients[sha256.Sum256(r.TLS.PeerCertificates[0].Raw)]

	// (2) 加入者に依らない検査
	var at [2]string
	switch r.PathValue("type") {
	case "eap-aka":
		at = eapAka
	case "umts-aka":
		at = umtsAka
	case "eap-aka-prime":
		at = eapAkaPrime
	case "eps-aka", "ims-aka", "gba-aka":
		f.problem(w, 501, causeAuthTypeNotSupported)
		return
	default:
		f.problem(w, 400, causeMandatoryIEIncorrect)
		return
	}
	supi := r.PathValue("supi")
	if !supiPattern.MatchString(supi) {
		f.problem(w, 400, causeMandatoryIEIncorrect)
		return
	}
	var req struct {
		HssAuthType *string `json:"hssAuthType"`
		Num         *int    `json:"numOfRequestedVectors"`
		Resync      *resync `json:"resynchronizationInfo"`
		AnID        *string `json:"anId"`
	}
	if err := json.UnmarshalRead(r.Body, &req); err != nil {
		f.problem(w, 400, causeInvalidMsgFormat)
		return
	}
	switch {
	case req.HssAuthType == nil || req.Num == nil:
		f.problem(w, 400, causeMandatoryIEMissing)
		return
	case *req.HssAuthType != at[1] || *req.Num < 1 || *req.Num > 5:
		f.problem(w, 400, causeMandatoryIEIncorrect)
		return
	}
	var rnd, auts []byte
	if req.Resync != nil {
		var err1, err2 error
		rnd, err1 = hexField("rand", req.Resync.Rand, 16, 16)
		auts, err2 = hexField("auts", req.Resync.Auts, 14, 14)
		if err1 != nil || err2 != nil {
			f.problem(w, 400, causeOptionalIEIncorrect)
			return
		}
	}
	if at == eapAkaPrime {
		if req.AnID == nil {
			f.problem(w, 400, causeMandatoryIEMissing)
			return
		}
		if *req.AnID != f.networkName {
			f.problem(w, 400, causeOptionalIEIncorrect)
			return
		}
	}

	// (3) 加入者に依る検査
	f.mu.Lock()
	defer f.mu.Unlock()
	sub, ok := f.subs[supi[len("imsi-"):]]
	if !ok {
		if f.bug == bugNotFound404 {
			f.problem(w, 404, "USER_NOT_FOUND")
			return
		}
		f.generic(w)
		return
	}
	if client != "A" || !sub.allowA || sub.state != fixture.Active {
		if f.bug == bugAdvanceOnReject {
			sub.sqn += 32
		}
		f.generic(w)
		return
	}
	if req.Resync != nil {
		aks, _ := sub.set.F5Star(rnd)
		sqnMS := make([]byte, 6)
		subtle.XORBytes(sqnMS, auts[0:6], aks)
		_, macS, _ := sub.set.F1(rnd, sqnMS, []byte{0, 0})
		if subtle.ConstantTimeCompare(macS, auts[6:]) != 1 {
			f.generic(w)
			return
		}
		sub.sqn = sqnValue(sqnMS)
	}

	var vs []vector
	for range *req.Num {
		sub.sqn = (sub.sqn + 32) & sqnMask
		rnd := randBytes(16)
		res, ck, ik, ak, _ := sub.set.F2345(rnd)
		sqn := sqnBytes(sub.sqn)
		macA, _, _ := sub.set.F1(rnd, sqn, sub.amf)
		autn := make([]byte, 6, 16)
		subtle.XORBytes(autn, sqn, ak)
		autn = append(append(autn, sub.amf...), macA...)
		v := vector{AvType: at[1], Rand: hex.EncodeToString(rnd), Xres: hex.EncodeToString(res), Autn: hex.EncodeToString(autn)}
		if at == eapAkaPrime {
			name := f.networkName
			if f.bug == bugWrongPrime {
				name = "HRPD"
			}
			ckp, ikp, _ := milenage.DerivePrime(ck, ik, name, autn[0:6])
			v.CkPrime, v.IkPrime = hex.EncodeToString(ckp), hex.EncodeToString(ikp)
		} else {
			v.Ck, v.Ik = hex.EncodeToString(ck), hex.EncodeToString(ik)
		}
		vs = append(vs, v)
	}
	w.Header().Set("Content-Type", "application/json")
	if f.bug != bugNoCacheControl {
		w.Header().Set("Cache-Control", "no-store")
	}
	json.MarshalWrite(w, map[string]any{"hssAuthenticationVectors": vs})
}

func randBytes(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}

// selfSigned は試験用の自己署名の証明書を作る。server なら 127.0.0.1 の SAN を付ける。
func selfSigned(t *testing.T, cn string, server bool) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	if server {
		tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		tmpl.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
		tmpl.IsCA = true
		tmpl.BasicConstraintsValid = true
		tmpl.KeyUsage |= x509.KeyUsageCertSign
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// startFake は偽物を立て、それを相手にする試験の設定を返す。
func startFake(t *testing.T, bug string) Config {
	t.Helper()
	server := selfSigned(t, "fake-av", true)
	a := selfSigned(t, "client-a", false)
	b := selfSigned(t, "client-b", false)
	f := newFakeServer(a, b, bug)
	ts := httptest.NewUnstartedServer(f.handler())
	ts.TLS = f.tlsConfig(server)
	ts.StartTLS()
	t.Cleanup(ts.Close)

	leaf, err := x509.ParseCertificate(server.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return Config{BaseURL: ts.URL + "/nudm-ueau/v1", RootCAs: pool, ClientA: a, ClientB: b, NetworkName: "WLAN", Timeout: 5 * time.Second}
}
