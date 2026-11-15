package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/oyaguma3/eapaka_test/eap"
	"github.com/oyaguma3/eapaka_test/eapmethod/aka"
	"github.com/oyaguma3/eapaka_test/radiusc"
	"github.com/oyaguma3/eapaka_test/sqnstore"
	"layeh.com/radius"
	"layeh.com/radius/rfc2865"
	"layeh.com/radius/rfc2866"
	"layeh.com/radius/rfc2869"
)

// 1 回の認証（EAP-AKA か EAP-AKA'）を最後まで通す。端末側の手順は eapaka_test の eap・eapmethod/aka（中で go-eapaka）を使う（確認事項 L6-2）。
const (
	realm   = "wlan.mnc010.mcc440.3gppnetwork.org"
	netName = "WLAN" // EAP-AKA' のネットワーク名（aka-radius の RADIUS_EAP_AKA_PRIME_NETWORK_NAME の既定）
	ssid    = "scale"
)

// lockedStore は eapaka_test の SQN の保存（sqnstore.Store）を、並べて使えるようにしたもの（MemoryStore は同時に使う作りでない）。
type lockedStore struct {
	mu sync.Mutex
	m  map[string]sqnstore.SubscriberState
}

func newLockedStore() *lockedStore { return &lockedStore{m: map[string]sqnstore.SubscriberState{}} }

func (s *lockedStore) Load(imsi string) (sqnstore.SubscriberState, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.m[imsi]
	return v, ok, nil
}

func (s *lockedStore) Save(imsi string, st sqnstore.SubscriberState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[imsi] = st
	return nil
}

func (s *lockedStore) Reset(imsi string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, imsi)
	return nil
}

// authResult は 1 回の認証の結果。
type authResult struct {
	accept bool
	code   radius.Code // 最後の応答（Accept・Reject）。時間切れや切断のときは 0
	class  []byte      // Access-Accept の Class（Accounting に入れる）
	err    error
	rounds int
}

// failKind は失敗の分け方（L6-5）: reject・timeout・closed（TLS の切断や接続がない）・error（そのほか）。
func (r authResult) failKind() string {
	switch {
	case r.accept:
		return ""
	case r.code == radius.CodeAccessReject:
		return "reject"
	case errors.Is(r.err, errTimeout):
		return "timeout"
	case errors.Is(r.err, errClosed):
		return "closed"
	default:
		return "error"
	}
}

// station は AP と端末の MAC の形の文字列（Called-Station-Id は <AP の MAC>:<SSID>）。
func station(n int) string {
	return fmt.Sprintf("02-%02X-%02X-%02X-%02X-%02X", byte(n>>32), byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
}

// authenticate は ap の接続で imsi の認証を通す。prime なら EAP-AKA'（Identity の頭は 6）、そうでなければ EAP-AKA（頭は 0）。
func authenticate(ctx context.Context, c *rsConn, a *apState, seed []byte, store sqnstore.Store, n int, prime bool, timeout time.Duration) authResult {
	imsi := imsiOf(n)
	ki, opc := keysOf(seed, imsi)
	opts := aka.Options{IMSI: imsi, KI: ki, OPC: opc, AMF: []byte{0x80, 0x00}, Realm: realm, SQNStore: store}
	o1, o2 := opts, opts
	o1.MethodType = eap.TypeAKA
	o2.MethodType, o2.NetName = eap.TypeAKAPrime, netName
	m1, err := aka.New(o1)
	if err != nil {
		return authResult{err: err}
	}
	m2, err := aka.New(o2)
	if err != nil {
		return authResult{err: err}
	}
	lead := "0"
	if prime {
		lead = "6"
	}
	user := lead + imsi + "@" + realm
	sess := &eap.Session{OuterIdentity: user}
	peer := eap.NewPeer(sess, m1, m2)
	resp := &eap.Packet{Code: eap.CodeResponse, Identifier: 0, Type: eap.TypeIdentity, TypeData: []byte(user)}
	var state []byte
	for round := 1; round <= 8; round++ {
		raw, err := resp.Encode()
		if err != nil {
			return authResult{err: err, rounds: round}
		}
		p := radius.New(radius.CodeAccessRequest, radsecSecret)
		_ = rfc2865.UserName_SetString(p, user)
		if err := radiusc.AddEAPMessage(p, raw); err != nil {
			return authResult{err: err, rounds: round}
		}
		if len(state) > 0 {
			_ = rfc2865.State_Set(p, state)
		}
		a.setAttrs(p, n)
		_ = rfc2865.FramedMTU_Set(p, 1400)
		r, err := c.exchange(ctx, p, timeout)
		if err != nil {
			return authResult{err: err, rounds: round}
		}
		switch r.Code {
		case radius.CodeAccessChallenge:
			state, _ = rfc2865.State_Lookup(r)
			msg, ok, err := radiusc.LookupEAPMessage(r)
			if err != nil || !ok {
				return authResult{err: fmt.Errorf("Access-Challenge に EAP-Message がない: %v", err), rounds: round}
			}
			req, err := eap.Parse(msg)
			if err != nil {
				return authResult{err: err, rounds: round}
			}
			next, err := peer.Handle(req)
			if err != nil {
				return authResult{err: err, rounds: round}
			}
			if next == nil {
				return authResult{err: errors.New("Challenge への応答がない"), rounds: round}
			}
			resp = next
			if sess.OuterIdentity != "" {
				user = sess.OuterIdentity
			}
		case radius.CodeAccessAccept:
			class, _ := rfc2865.Class_Lookup(r)
			return authResult{accept: true, code: r.Code, class: class, rounds: round}
		case radius.CodeAccessReject:
			return authResult{code: r.Code, rounds: round}
		default:
			return authResult{err: fmt.Errorf("思わぬ応答 %v", r.Code), rounds: round}
		}
	}
	return authResult{err: errors.New("8 回を超えた"), rounds: 8}
}

// session は Accounting を送っているセッション。
type session struct {
	n       int // IMSI の番号
	ap      *apState
	id      string // Acct-Session-Id
	class   []byte
	started time.Time
	interim int // 送った Interim の数
}

// accounting は Accounting-Request（Start・Interim・Stop）を送る。
func accounting(ctx context.Context, c *rsConn, s *session, status rfc2866.AcctStatusType, timeout time.Duration) error {
	p := radius.New(radius.CodeAccountingRequest, radsecSecret)
	_ = rfc2866.AcctStatusType_Set(p, status)
	_ = rfc2866.AcctSessionID_SetString(p, s.id)
	_ = rfc2865.UserName_SetString(p, "0"+imsiOf(s.n)+"@"+realm)
	if len(s.class) > 0 {
		_ = rfc2865.Class_Add(p, s.class)
	}
	s.ap.setAttrs(p, s.n)
	now := time.Now()
	_ = rfc2869.EventTimestamp_Set(p, now)
	if status != rfc2866.AcctStatusType_Value_Start {
		secs := uint32(now.Sub(s.started).Seconds())
		_ = rfc2866.AcctSessionTime_Set(p, rfc2866.AcctSessionTime(secs))
		// 1 秒に約 2 KB 受け、0.5 KB 送る端末の形
		_ = rfc2866.AcctInputOctets_Set(p, rfc2866.AcctInputOctets(secs*512))
		_ = rfc2866.AcctOutputOctets_Set(p, rfc2866.AcctOutputOctets(secs*2048))
	}
	r, err := c.exchange(ctx, p, timeout)
	if err != nil {
		return err
	}
	if r.Code != radius.CodeAccountingResponse {
		return fmt.Errorf("思わぬ応答 %v", r.Code)
	}
	return nil
}
