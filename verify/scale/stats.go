package main

import (
	"encoding/json"
	"math"
	"os"
	"slices"
	"sync"
	"time"
)

// 数と遅延の記録（確認事項 L6-6）。10 秒ごとの窓を windows.jsonl に書き、場面（label）ごとにすべての遅延を覚えて、終わりに正確な分位を出す。
// 遅延は Access-Accept まで通った認証の、最初の要求から Accept までの時間。

// counts は数えるもの。
type counts struct {
	Started     int64 `json:"started"`      // 始めた認証
	Accept      int64 `json:"accept"`       // Access-Accept
	Reject      int64 `json:"reject"`       // Access-Reject
	Timeout     int64 `json:"timeout"`      // 応答の時間切れ
	Closed      int64 `json:"closed"`       // TLS の切断（途中で接続が切れた）
	Error       int64 `json:"error"`        // そのほかの誤り
	SkipNoConn  int64 `json:"skip_no_conn"` // つながっている AP がなくて始められなかった
	SkipLimit   int64 `json:"skip_limit"`   // 同時の数の上限で始められなかった
	SkipBusy    int64 `json:"skip_busy"`    // 空いている IMSI がなくて始められなかった
	AKA         int64 `json:"aka"`          // EAP-AKA で始めた数
	AKAPrime    int64 `json:"aka_prime"`    // EAP-AKA' で始めた数
	AcctSent    int64 `json:"acct_sent"`
	AcctOK      int64 `json:"acct_ok"`
	AcctTimeout int64 `json:"acct_timeout"`
	AcctError   int64 `json:"acct_error"`
}

func (c *counts) add(o counts) {
	c.Started += o.Started
	c.Accept += o.Accept
	c.Reject += o.Reject
	c.Timeout += o.Timeout
	c.Closed += o.Closed
	c.Error += o.Error
	c.SkipNoConn += o.SkipNoConn
	c.SkipLimit += o.SkipLimit
	c.SkipBusy += o.SkipBusy
	c.AKA += o.AKA
	c.AKAPrime += o.AKAPrime
	c.AcctSent += o.AcctSent
	c.AcctOK += o.AcctOK
	c.AcctTimeout += o.AcctTimeout
	c.AcctError += o.AcctError
}

// failures は失敗の合計（始められなかったものを含む）。
func (c counts) failures() int64 {
	return c.Reject + c.Timeout + c.Closed + c.Error + c.SkipNoConn + c.SkipLimit + c.SkipBusy
}

// percentiles は遅延の分位（秒）。
type percentiles struct {
	N   int     `json:"n"`
	P50 float64 `json:"p50"`
	P90 float64 `json:"p90"`
	P95 float64 `json:"p95"`
	P99 float64 `json:"p99"`
	Max float64 `json:"max"`
}

func percentilesOf(v []float64) percentiles {
	if len(v) == 0 {
		return percentiles{}
	}
	s := slices.Clone(v)
	slices.Sort(s)
	at := func(q float64) float64 {
		i := int(math.Ceil(q*float64(len(s)))) - 1
		return round(s[max(0, min(i, len(s)-1))])
	}
	return percentiles{N: len(s), P50: at(0.50), P90: at(0.90), P95: at(0.95), P99: at(0.99), Max: round(s[len(s)-1])}
}

func round(x float64) float64 { return math.Round(x*10000) / 10000 }

// labelAgg は場面ごとの合計。
type labelAgg struct {
	counts
	lat   []float64
	first time.Time
	last  time.Time
}

// recorder は数と遅延を覚える。
type recorder struct {
	mu     sync.Mutex
	label  string
	win    counts
	winLat []float64
	labels map[string]*labelAgg
	order  []string
}

func newRecorder() *recorder { return &recorder{label: "idle", labels: map[string]*labelAgg{}} }

func (r *recorder) setLabel(l string) {
	r.mu.Lock()
	r.label = l
	r.mu.Unlock()
}

func (r *recorder) curLabel() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.label
}

func (r *recorder) agg(l string) *labelAgg {
	a, ok := r.labels[l]
	if !ok {
		a = &labelAgg{first: time.Now()}
		r.labels[l] = a
		r.order = append(r.order, l)
	}
	a.last = time.Now()
	return a
}

// add は数を足す（label が空なら今の場面）。lat が 0 より大きければ遅延も覚える。
func (r *recorder) add(label string, c counts, lat float64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if label == "" {
		label = r.label
	}
	r.win.add(c)
	a := r.agg(label)
	a.add(c)
	if lat > 0 {
		r.winLat = append(r.winLat, lat)
		a.lat = append(a.lat, lat)
	}
}

// window は 10 秒ごとの記録の 1 行。
type window struct {
	Time     string      `json:"time"`
	Label    string      `json:"label"`
	Rate     float64     `json:"rate"`
	ConnsUp  int64       `json:"conns_up"`
	Connects int64       `json:"connects"`
	DialFail int64       `json:"dial_fail"`
	Lost     int64       `json:"lost"`
	Inflight int64       `json:"inflight"`
	Sessions int64       `json:"sessions"`
	Counts   counts      `json:"counts"`
	Latency  percentiles `json:"latency"`
}

// flush は今の窓を閉じて返す。
func (r *recorder) flush() (string, counts, percentiles) {
	r.mu.Lock()
	defer r.mu.Unlock()
	c, lat := r.win, r.winLat
	r.win, r.winLat = counts{}, nil
	return r.label, c, percentilesOf(lat)
}

// labelSummary は場面ごとのまとめ。
type labelSummary struct {
	Label    string      `json:"label"`
	From     string      `json:"from"`
	To       string      `json:"to"`
	Seconds  float64     `json:"seconds"`
	Counts   counts      `json:"counts"`
	Failures int64       `json:"failures"`
	TPS      float64     `json:"tps"` // Accept の数 / 秒
	Latency  percentiles `json:"latency"`
}

func (r *recorder) summary() []labelSummary {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []labelSummary
	for _, l := range r.order {
		a := r.labels[l]
		secs := a.last.Sub(a.first).Seconds()
		s := labelSummary{Label: l, From: a.first.Format(time.RFC3339), To: a.last.Format(time.RFC3339), Seconds: round(secs), Counts: a.counts, Failures: a.counts.failures(), Latency: percentilesOf(a.lat)}
		if secs > 0 {
			s.TPS = round(float64(a.Accept) / secs)
		}
		out = append(out, s)
	}
	return out
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}
