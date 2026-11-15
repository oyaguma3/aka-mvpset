package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/oyaguma3/eapaka_test/sqnstore"
	"layeh.com/radius"
	"layeh.com/radius/rfc2865"
	"layeh.com/radius/rfc2866"
)

// 負荷の道具の本体（確認事項 L6-2・L6-5）。AP ごとに 1 本の RadSec の接続を保ち（切れたら張り直す）、手元の HTTP の口で
// 毎秒の認証の数（場面の名前つき）とセッションの作り方を指示する。接続とセッションを場面をまたいで保つので、1 つのプロセスで動かし続ける。

// apConfig は aps.json の 1 件（verify/scale/drive.sh の aps の段が作る）。
type apConfig struct {
	Tenant string `json:"tenant"` // テナントの slug
	Name   string `json:"name"`   // AP の名前
	Addr   string `json:"addr"`   // primary のエッジの公開のアドレスとテナントのポート（host:port）
	Cert   string `json:"cert"`
	Key    string `json:"key"`
	CA     string `json:"ca"`   // テナントのサーバー CA
	From   int    `json:"from"` // テナントの IMSI の番号の範囲
	To     int    `json:"to"`
}

// apState は動いている AP。
type apState struct {
	cfg  apConfig
	idx  int
	tls  *tls.Config
	nas  string
	mac  string
	conn atomic.Pointer[rsConn]
}

// setAttrs は AP が付ける属性を足す（NAS-Identifier は <slug>-<名前>。エッジも同じ値に書き換える）。
func (a *apState) setAttrs(p *radius.Packet, n int) {
	_ = rfc2865.NASIdentifier_SetString(p, a.nas)
	_ = rfc2865.CalledStationID_SetString(p, a.mac+":"+ssid)
	_ = rfc2865.CallingStationID_SetString(p, station(n))
	_ = rfc2865.NASPortType_Set(p, rfc2865.NASPortType_Value_Wireless80211)
}

type server struct {
	log      *slog.Logger
	seed     []byte
	store    sqnstore.Store
	aps      []*apState
	byTenant map[string][]*apState
	timeout  time.Duration
	maxIn    int64
	rec      *recorder
	out      string

	rate     atomic.Uint64 // 毎秒の認証の数（float64 のビット）
	inflight atomic.Int64
	connsUp  atomic.Int64
	connects atomic.Int64
	dialFail atomic.Int64
	lost     atomic.Int64
	rr       atomic.Uint64
	flip     atomic.Uint64

	busyMu sync.Mutex
	busy   map[int]struct{}

	sessMu   sync.Mutex
	interim  time.Duration // Interim の間隔（既定 10 分）
	buckets  [][]*session  // 始めた秒 % 間隔の秒 ごと
	sessions atomic.Int64
	building atomic.Bool

	dialTokens chan struct{}
	stop       context.CancelFunc
}

func (s *server) setRate(tps float64) { s.rate.Store(math.Float64bits(tps)) }
func (s *server) curRate() float64    { return math.Float64frombits(s.rate.Load()) }

// keep は AP の接続を保つ（張り直しは dialTokens で毎秒の数を絞り、失敗したら 1〜30 秒待つ）。
func (s *server) keep(ctx context.Context, a *apState) {
	backoff := time.Second
	for ctx.Err() == nil {
		select {
		case <-s.dialTokens:
		case <-ctx.Done():
			return
		}
		c, err := dialRadSec(ctx, a.cfg.Addr, a.tls)
		if err != nil {
			s.dialFail.Add(1)
			if s.dialFail.Load()%50 == 1 {
				s.log.Warn("接続できない", "ap", a.nas, "addr", a.cfg.Addr, "error", err)
			}
			select {
			case <-time.After(backoff + time.Duration(rand.Int64N(int64(time.Second)))):
			case <-ctx.Done():
				return
			}
			backoff = min(backoff*2, 30*time.Second)
			continue
		}
		backoff = time.Second
		a.conn.Store(c)
		s.connects.Add(1)
		s.connsUp.Add(1)
		select {
		case <-c.closed():
		case <-ctx.Done():
			c.close()
		}
		a.conn.Store(nil)
		s.connsUp.Add(-1)
		if ctx.Err() == nil {
			s.lost.Add(1)
		}
	}
}

// dialer は張り直しの許しを毎秒 rate 回出す。
func (s *server) dialer(ctx context.Context, rate float64) {
	t := time.NewTicker(time.Duration(float64(time.Second) / rate))
	defer t.Stop()
	for {
		select {
		case <-t.C:
			select {
			case s.dialTokens <- struct{}{}:
			default:
			}
		case <-ctx.Done():
			return
		}
	}
}

// pickIMSI はテナントの範囲から、認証中でない IMSI を選ぶ（同じ IMSI を同時に使うと SQN の順が入れ替わるため）。
func (s *server) pickIMSI(a *apState) (int, bool) {
	s.busyMu.Lock()
	defer s.busyMu.Unlock()
	for range 8 {
		n := a.cfg.From + rand.IntN(a.cfg.To-a.cfg.From+1)
		if _, ok := s.busy[n]; !ok {
			s.busy[n] = struct{}{}
			return n, true
		}
	}
	return 0, false
}

func (s *server) release(n int) {
	s.busyMu.Lock()
	delete(s.busy, n)
	s.busyMu.Unlock()
}

// nextAP はつながっている AP を順に選ぶ。
func (s *server) nextAP(list []*apState) (*apState, *rsConn) {
	for range len(list) {
		a := list[s.rr.Add(1)%uint64(len(list))]
		if c := a.conn.Load(); c != nil {
			return a, c
		}
	}
	return nil, nil
}

// record は 1 回の認証の結果を数える。
func (s *server) record(label string, prime bool, r authResult, d time.Duration) {
	c := counts{Started: 1}
	if prime {
		c.AKAPrime = 1
	} else {
		c.AKA = 1
	}
	lat := 0.0
	switch r.failKind() {
	case "":
		c.Accept, lat = 1, d.Seconds()
	case "reject":
		c.Reject = 1
	case "timeout":
		c.Timeout = 1
	case "closed":
		c.Closed = 1
	default:
		c.Error = 1
		s.log.Warn("認証の誤り", "error", r.err, "round", r.rounds)
	}
	s.rec.add(label, c, lat)
}

// runAuth は 1 回の認証を始め、始めたかを返す。done があれば終わったときに結果を渡す（セッションを作るとき）。
func (s *server) runAuth(ctx context.Context, label string, list []*apState, n int, done func(*apState, int, authResult)) bool {
	// 場面は始めたときの名前で数える（場面を切り替えた後に終わった認証を次の場面に数えない）
	if label == "" {
		label = s.rec.curLabel()
	}
	if s.inflight.Load() >= s.maxIn {
		s.rec.add(label, counts{SkipLimit: 1}, 0)
		return false
	}
	a, c := s.nextAP(list)
	if a == nil {
		s.rec.add(label, counts{SkipNoConn: 1}, 0)
		return false
	}
	if n == 0 {
		var ok bool
		if n, ok = s.pickIMSI(a); !ok {
			s.rec.add(label, counts{SkipBusy: 1}, 0)
			return false
		}
	} else {
		s.busyMu.Lock()
		s.busy[n] = struct{}{}
		s.busyMu.Unlock()
	}
	prime := s.flip.Add(1)%2 == 0
	s.inflight.Add(1)
	go func() {
		defer s.inflight.Add(-1)
		defer s.release(n)
		t0 := time.Now()
		r := authenticate(ctx, c, a, s.seed, s.store, n, prime, s.timeout)
		s.record(label, prime, r, time.Since(t0))
		if done != nil {
			done(a, n, r)
		}
	}()
	return true
}

// loadLoop は毎秒 rate 回の認証を始める（返事を待たずに次を始める）。
func (s *server) loadLoop(ctx context.Context) {
	t := time.NewTicker(5 * time.Millisecond)
	defer t.Stop()
	last, acc := time.Now(), 0.0
	for {
		select {
		case now := <-t.C:
			acc += s.curRate() * now.Sub(last).Seconds()
			last = now
			for ; acc >= 1; acc-- {
				s.runAuth(ctx, "", s.aps, 0, nil)
			}
			if s.curRate() == 0 {
				acc = 0
			}
		case <-ctx.Done():
			return
		}
	}
}

// buildSessions は tenant の IMSI の頭から n 件を毎秒 tps で認証し、Accept なら Accounting-Start を送ってセッションにする。
// 失敗した IMSI は最後に 1 回だけやり直す。セッションは 10 分ごとに Interim を送る（interimLoop）。
func (s *server) buildSessions(ctx context.Context, tenant string, n int, tps float64) {
	defer s.building.Store(false)
	list := s.byTenant[tenant]
	from, to := list[0].cfg.From, min(list[0].cfg.From+n-1, list[0].cfg.To)
	var fmu sync.Mutex
	var failed []int
	done := func(a *apState, num int, r authResult) {
		if !r.accept {
			fmu.Lock()
			failed = append(failed, num)
			fmu.Unlock()
			return
		}
		ss := &session{n: num, ap: a, id: fmt.Sprintf("scale-%d-%d", num, time.Now().UnixNano()), class: r.class, started: time.Now()}
		if !s.acct(ctx, "sessions", ss, rfc2866.AcctStatusType_Value_Start) {
			fmu.Lock()
			failed = append(failed, num)
			fmu.Unlock()
			return
		}
		s.sessMu.Lock()
		b := ss.started.Unix() % int64(len(s.buckets))
		s.buckets[b] = append(s.buckets[b], ss)
		s.sessMu.Unlock()
		s.sessions.Add(1)
	}
	pass := func(nums []int) {
		gap := time.Duration(float64(time.Second) / tps)
		for _, num := range nums {
			if ctx.Err() != nil {
				return
			}
			if !s.runAuth(ctx, "sessions", list, num, done) {
				fmu.Lock()
				failed = append(failed, num)
				fmu.Unlock()
			}
			time.Sleep(gap)
		}
	}
	all := make([]int, 0, to-from+1)
	for num := from; num <= to; num++ {
		all = append(all, num)
	}
	pass(all)
	for s.inflight.Load() > 0 && ctx.Err() == nil {
		time.Sleep(200 * time.Millisecond)
	}
	fmu.Lock()
	retry := failed
	failed = nil
	fmu.Unlock()
	if len(retry) > 0 {
		s.log.Info("セッションを作れなかった IMSI をやり直す", "count", len(retry))
		pass(retry)
	}
	s.log.Info("セッションを作り終えた", "tenant", tenant, "sessions", s.sessions.Load())
}

// acct は Accounting-Request を送って数える（label が空なら今の場面）。
func (s *server) acct(ctx context.Context, label string, ss *session, st rfc2866.AcctStatusType) bool {
	c := ss.ap.conn.Load()
	if c == nil {
		s.rec.add(label, counts{AcctSent: 1, AcctError: 1}, 0)
		return false
	}
	err := accounting(ctx, c, ss, st, s.timeout)
	cn := counts{AcctSent: 1}
	switch {
	case err == nil:
		cn.AcctOK = 1
	case errors.Is(err, errTimeout):
		cn.AcctTimeout = 1
	default:
		cn.AcctError = 1
	}
	s.rec.add(label, cn, 0)
	return err == nil
}

// interimLoop は毎秒、その秒の箱のセッションのうち始めてから間隔（既定 10 分）がたったものに Interim を送る。
func (s *server) interimLoop(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case now := <-t.C:
			s.sessMu.Lock()
			due := s.buckets[now.Unix()%int64(len(s.buckets))]
			s.sessMu.Unlock()
			for _, ss := range due {
				if now.Sub(ss.started) < s.interim-10*time.Second {
					continue
				}
				ss.interim++
				go s.acct(ctx, "", ss, rfc2866.AcctStatusType_Value_InterimUpdate)
			}
		case <-ctx.Done():
			return
		}
	}
}

// stopSessions は全部のセッションに Accounting-Stop を毎秒 tps で送る。
func (s *server) stopSessions(ctx context.Context, tps float64) {
	s.sessMu.Lock()
	var all []*session
	for i := range s.buckets {
		all = append(all, s.buckets[i]...)
		s.buckets[i] = nil
	}
	s.sessMu.Unlock()
	gap := time.Duration(float64(time.Second) / tps)
	var wg sync.WaitGroup
	for _, ss := range all {
		wg.Go(func() { s.acct(ctx, "stop", ss, rfc2866.AcctStatusType_Value_Stop) })
		time.Sleep(gap)
	}
	wg.Wait()
	s.sessions.Store(0)
}

// windows は 10 秒ごとに windows.jsonl へ書く。
func (s *server) windows(ctx context.Context) {
	f, err := os.OpenFile(filepath.Join(s.out, "windows.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		s.log.Error("windows.jsonl", "error", err)
		return
	}
	defer f.Close()
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	enc := json.NewEncoder(f)
	for {
		select {
		case now := <-t.C:
			label, c, p := s.rec.flush()
			_ = enc.Encode(window{Time: now.Format(time.RFC3339), Label: label, Rate: s.curRate(), ConnsUp: s.connsUp.Load(), Connects: s.connects.Load(),
				DialFail: s.dialFail.Load(), Lost: s.lost.Load(), Inflight: s.inflight.Load(), Sessions: s.sessions.Load(), Counts: c, Latency: p})
		case <-ctx.Done():
			return
		}
	}
}

// status は今の状態（GET /status）。
type status struct {
	Label    string         `json:"label"`
	Rate     float64        `json:"rate"`
	APs      int            `json:"aps"`
	ConnsUp  int64          `json:"conns_up"`
	Connects int64          `json:"connects"`
	DialFail int64          `json:"dial_fail"`
	Lost     int64          `json:"lost"`
	Inflight int64          `json:"inflight"`
	Sessions int64          `json:"sessions"`
	Building bool           `json:"building"`
	Summary  []labelSummary `json:"summary"`
}

func (s *server) status() status {
	return status{Label: s.rec.curLabel(), Rate: s.curRate(), APs: len(s.aps), ConnsUp: s.connsUp.Load(), Connects: s.connects.Load(), DialFail: s.dialFail.Load(),
		Lost: s.lost.Load(), Inflight: s.inflight.Load(), Sessions: s.sessions.Load(), Building: s.building.Load(), Summary: s.rec.summary()}
}

// routes は手元（127.0.0.1）の操作の口。
//
//	GET  /status                              今の状態と場面ごとのまとめ
//	POST /load?tps=50&label=p2                毎秒の認証の数と場面の名前（tps=0 で止める）
//	POST /sessions?tenant=sc0001&n=20000&tps=50  セッションを作る（認証と Accounting-Start、その後 10 分ごとに Interim）
//	POST /stop?stop_sessions=1&tps=100        止める（stop_sessions=1 なら全部のセッションに Accounting-Stop を送ってから）
func (s *server) routes(ctx context.Context) http.Handler {
	mux := http.NewServeMux()
	ok := func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(s.status())
	}
	num := func(r *http.Request, k string, def float64) float64 {
		v, err := strconv.ParseFloat(r.URL.Query().Get(k), 64)
		if err != nil {
			return def
		}
		return v
	}
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) { ok(w) })
	mux.HandleFunc("POST /load", func(w http.ResponseWriter, r *http.Request) {
		tps := num(r, "tps", 0)
		label := r.URL.Query().Get("label")
		if label == "" {
			label = fmt.Sprintf("tps%g", tps)
		}
		s.rec.setLabel(label)
		s.setRate(tps)
		s.log.Info("毎秒の数を変えた", "tps", tps, "label", label)
		ok(w)
	})
	mux.HandleFunc("POST /sessions", func(w http.ResponseWriter, r *http.Request) {
		tenant := r.URL.Query().Get("tenant")
		if len(s.byTenant[tenant]) == 0 || !s.building.CompareAndSwap(false, true) {
			http.Error(w, "テナントの AP がないか、セッションを作っている最中", http.StatusConflict)
			return
		}
		go s.buildSessions(ctx, tenant, int(num(r, "n", 20000)), num(r, "tps", 50))
		ok(w)
	})
	mux.HandleFunc("POST /stop", func(w http.ResponseWriter, r *http.Request) {
		s.setRate(0)
		if r.URL.Query().Get("stop_sessions") == "1" {
			s.stopSessions(ctx, num(r, "tps", 100))
		}
		ok(w)
		go s.stop()
	})
	return mux
}

// serve は aps.json の AP をつなぎ、操作の口で待つ。
func serve(apsFile, seedFile, out, listen string, dialRate float64, timeout, interim time.Duration, maxIn int) error {
	if interim < 20*time.Second {
		return errors.New("Interim の間隔は 20 秒以上")
	}
	seed, err := readSeed(seedFile)
	if err != nil {
		return err
	}
	b, err := os.ReadFile(apsFile)
	if err != nil {
		return err
	}
	var cfgs []apConfig
	if err := json.Unmarshal(b, &cfgs); err != nil {
		return fmt.Errorf("%s: %w", apsFile, err)
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	s := &server{log: log, seed: seed, store: newLockedStore(), byTenant: map[string][]*apState{}, timeout: timeout, maxIn: int64(maxIn),
		rec: newRecorder(), out: out, busy: map[int]struct{}{}, dialTokens: make(chan struct{}), interim: interim, buckets: make([][]*session, int(interim.Seconds()))}
	for i, c := range cfgs {
		tc, err := tlsConfigFor(c.Cert, c.Key, c.CA)
		if err != nil {
			return err
		}
		if c.From <= 0 || c.To < c.From {
			return fmt.Errorf("AP %s-%s の IMSI の範囲が正しくない", c.Tenant, c.Name)
		}
		a := &apState{cfg: c, idx: i, tls: tc, nas: c.Tenant + "-" + c.Name, mac: station(1<<32 | i)}
		s.aps = append(s.aps, a)
		s.byTenant[c.Tenant] = append(s.byTenant[c.Tenant], a)
	}
	if len(s.aps) == 0 {
		return errors.New("AP が 1 つもない")
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.stop = cancel
	go s.dialer(ctx, dialRate)
	for _, a := range s.aps {
		go s.keep(ctx, a)
	}
	go s.loadLoop(ctx)
	go s.interimLoop(ctx)
	go s.windows(ctx)
	srv := &http.Server{Addr: listen, Handler: s.routes(ctx), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	log.Info("始めた", "aps", len(s.aps), "tenants", len(s.byTenant), "listen", listen, "dial_rate", dialRate)
	err = srv.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	// 待っている認証を少し待ってから、まとめを書く
	for i := 0; i < 50 && s.inflight.Load() > 0; i++ {
		time.Sleep(200 * time.Millisecond)
	}
	if werr := writeJSON(filepath.Join(out, "summary.json"), s.rec.summary()); werr != nil && err == nil {
		err = werr
	}
	log.Info("止めた", "summary", filepath.Join(out, "summary.json"))
	return err
}
