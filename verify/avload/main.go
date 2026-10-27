// avload は、認証ベクターAPI の取得先（aka-vecgen など）に一定の速さで要求を送り、応答の時間を測る道具。
//
// 加入者の登録（-setup）は取得先の管理API（aka-vecgen の /admin/v2/subscribers）で行う。
// 測るのは認証ベクターAPI の契約 §11.1 の目安（毎秒 100 要求で p99 200 ミリ秒）に照らすため。
// 使い方は README.md。
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"time"
)

type options struct {
	avURL, avCA, avCert string
	adminURL, adminCA   string
	adminCert           string
	clientID            int64
	prefix              string
	count               int
	setup               bool
	setupWorkers        int
	rate                int
	duration            time.Duration
	timeout             time.Duration
	label               string
}

func main() {
	var o options
	flag.StringVar(&o.avURL, "url", "https://127.0.0.1:8443/nudm-ueau/v1", "認証ベクターAPI の基底の URL")
	flag.StringVar(&o.avCA, "ca", "", "認証ベクターAPI のサーバー証明書（PEM）")
	flag.StringVar(&o.avCert, "cert", "", "AV クライアントの証明書と秘密鍵（PEM。1 つのファイル）")
	flag.StringVar(&o.adminURL, "admin-url", "https://127.0.0.1:9443", "管理API の URL（-setup のとき）")
	flag.StringVar(&o.adminCA, "admin-ca", "", "管理API のサーバー証明書（PEM。-setup のとき）")
	flag.StringVar(&o.adminCert, "admin-cert", "", "管理クライアントの証明書と秘密鍵（PEM。-setup のとき）")
	flag.Int64Var(&o.clientID, "client-id", 1, "払い出しを許す AV クライアントの ID（-setup のとき）")
	flag.StringVar(&o.prefix, "prefix", "00101", "IMSI の先頭（5 桁。残りの 10 桁は通し番号）")
	flag.IntVar(&o.count, "n", 10000, "加入者の数")
	flag.BoolVar(&o.setup, "setup", false, "測る前に加入者を管理API で登録する")
	flag.IntVar(&o.setupWorkers, "setup-workers", 8, "登録の並列の数")
	flag.IntVar(&o.rate, "rate", 100, "1 秒あたりの要求の数（EAP-AKA と EAP-AKA' を交互に）")
	flag.DurationVar(&o.duration, "duration", time.Minute, "測る時間")
	flag.DurationVar(&o.timeout, "timeout", 3*time.Second, "要求 1 回のタイムアウト")
	flag.StringVar(&o.label, "label", "", "結果の行に付ける名前")
	flag.Parse()

	if err := run(context.Background(), o); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, o options) error {
	if o.setup {
		admin, err := newClient(o.adminCA, o.adminCert, 30*time.Second, o.setupWorkers)
		if err != nil {
			return fmt.Errorf("admin client: %w", err)
		}
		start := time.Now()
		if err := setup(ctx, admin, o); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "registered %d subscribers in %s\n", o.count, time.Since(start).Round(time.Millisecond))
	}
	av, err := newClient(o.avCA, o.avCert, o.timeout, 256)
	if err != nil {
		return fmt.Errorf("av client: %w", err)
	}
	return load(ctx, av, o)
}

// newClient は mTLS のクライアントを作る（接続を使い回す。TLS 1.2 以上）。
func newClient(caFile, certFile string, timeout time.Duration, conns int) (*http.Client, error) {
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("%s has no certificate", caFile)
	}
	cert, err := tls.LoadX509KeyPair(certFile, certFile)
	if err != nil {
		return nil, err
	}
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, Certificates: []tls.Certificate{cert}},
			MaxIdleConns:        conns,
			MaxIdleConnsPerHost: conns,
			IdleConnTimeout:     50 * time.Second,
		},
	}, nil
}

func imsi(o options, i int) string { return fmt.Sprintf("%s%010d", o.prefix, i) }

// setup は加入者を管理API で登録する（既にあれば 409 を許す）。鍵は試験用の決まった値。
func setup(ctx context.Context, c *http.Client, o options) error {
	var next atomic.Int64
	errs := make(chan error, o.setupWorkers)
	var wg sync.WaitGroup
	for range o.setupWorkers {
		wg.Go(func() {
			for {
				i := int(next.Add(1) - 1)
				if i >= o.count {
					return
				}
				body, _ := json.Marshal(map[string]any{
					"imsi": imsi(o, i), "ki": "465b5ce8b199b49faa5f0a2ee238a6bc", "opc": "cd63cb71954a9f4e48a5994e37a02baf",
					"state": "active", "amf": "8000", "allowedClientIds": []int64{o.clientID},
				})
				req, _ := http.NewRequestWithContext(ctx, http.MethodPost, o.adminURL+"/admin/v2/subscribers", bytes.NewReader(body))
				req.Header.Set("Content-Type", "application/json")
				resp, err := c.Do(req)
				if err != nil {
					errs <- err
					return
				}
				b, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusConflict {
					errs <- fmt.Errorf("register %s: %d %s", imsi(o, i), resp.StatusCode, b)
					return
				}
			}
		})
	}
	wg.Wait()
	close(errs)
	return errors.Join(slices.Collect(func(yield func(error) bool) {
		for e := range errs {
			if !yield(e) {
				return
			}
		}
	})...)
}

// result は 1 回の要求の結果。
type result struct {
	latency time.Duration
	status  int
	err     bool
}

// load は o.rate 回/秒で要求を送り続け（前の要求の終わりを待たない）、応答の時間を集める。
func load(ctx context.Context, c *http.Client, o options) error {
	total := int(o.duration.Seconds() * float64(o.rate))
	results := make([]result, total)
	interval := time.Second / time.Duration(o.rate)
	var wg sync.WaitGroup
	start := time.Now()
	for i := range total {
		// 予定の時刻まで待つ（遅れたら待たずに送る）
		if d := time.Until(start.Add(time.Duration(i) * interval)); d > 0 {
			time.Sleep(d)
		}
		wg.Go(func() {
			results[i] = request(ctx, c, o, i)
		})
	}
	sent := time.Since(start)
	wg.Wait()

	var lat []time.Duration
	codes := map[int]int{}
	errCount := 0
	for _, r := range results {
		if r.err {
			errCount++
			continue
		}
		codes[r.status]++
		if r.status == http.StatusOK {
			lat = append(lat, r.latency)
		}
	}
	slices.Sort(lat)
	pct := func(p float64) float64 {
		if len(lat) == 0 {
			return 0
		}
		return float64(lat[min(len(lat)-1, int(float64(len(lat))*p))].Microseconds()) / 1000
	}
	summary := map[string]any{
		"label": o.label, "subscribers": o.count, "rate": o.rate, "durationSec": o.duration.Seconds(),
		"requests": total, "ok": len(lat), "transportErrors": errCount, "statusCounts": codes,
		"achievedRate": float64(total) / sent.Seconds(),
		"p50ms":        pct(0.50), "p95ms": pct(0.95), "p99ms": pct(0.99), "maxMs": pct(1.0),
	}
	out, _ := json.Marshal(summary)
	fmt.Println(string(out))
	if errCount > 0 || len(lat) != total {
		return fmt.Errorf("%d of %d requests failed", total-len(lat), total)
	}
	return nil
}

// request は 1 回の GenerateAv を送る。偶数番は EAP-AKA、奇数番は EAP-AKA'（anId は WLAN）。
func request(ctx context.Context, c *http.Client, o options, i int) result {
	pathType, body := "eap-aka", `{"hssAuthType":"EAP_AKA","numOfRequestedVectors":1}`
	if i%2 == 1 {
		pathType, body = "eap-aka-prime", `{"hssAuthType":"EAP_AKA_PRIME","numOfRequestedVectors":1,"anId":"WLAN"}`
	}
	url := o.avURL + "/imsi-" + imsi(o, i%o.count) + "/hss-security-information/" + pathType + "/generate-av"
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	t := time.Now()
	resp, err := c.Do(req)
	if err != nil {
		return result{err: true}
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return result{latency: time.Since(t), status: resp.StatusCode}
}
