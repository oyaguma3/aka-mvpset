package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/oyaguma3/eapaka_test/radiusc"
	"layeh.com/radius"
)

// RadSec（RFC 6614）の AP の側。TLS の上に RADIUS のパケットをそのまま並べ、共有の秘密は "radsec"。
// 1 本の接続で、Identifier（0〜255）ごとに要求を多重にやり取りする（エッジの radsecproxy は同じ Identifier で応える）。
var radsecSecret = []byte("radsec")

var (
	errClosed  = errors.New("接続が閉じた")
	errTimeout = errors.New("応答の時間切れ")
)

// tlsConfigFor は AP の証明書と、テナントのサーバー CA で確かめる設定を作る。IP でつなぐので（DNS を登録しない。L6-4）、
// 名前は照らさず、鎖だけを確かめる（段階 5 の AP の役と同じ）。
func tlsConfigFor(certFile, keyFile, caFile string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("AP の証明書と鍵 %s: %w", certFile, err)
	}
	pem, err := os.ReadFile(caFile)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("サーバー CA %s を読めない", caFile)
	}
	return &tls.Config{
		Certificates:       []tls.Certificate{cert},
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: true, // 名前を照らさないため。鎖は VerifyConnection で確かめる
		VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return errors.New("サーバー証明書がない")
			}
			inter := x509.NewCertPool()
			for _, c := range cs.PeerCertificates[1:] {
				inter.AddCert(c)
			}
			_, err := cs.PeerCertificates[0].Verify(x509.VerifyOptions{Roots: pool, Intermediates: inter, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}})
			return err
		},
	}, nil
}

// rsConn は 1 本の RadSec の接続。
type rsConn struct {
	c       *tls.Conn
	wmu     sync.Mutex
	ids     chan byte
	pmu     sync.Mutex
	pending [256]chan []byte
	done    chan struct{}
	once    sync.Once
}

func dialRadSec(ctx context.Context, addr string, cfg *tls.Config) (*rsConn, error) {
	d := tls.Dialer{NetDialer: &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 15 * time.Second}, Config: cfg}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	nc, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	r := &rsConn{c: nc.(*tls.Conn), ids: make(chan byte, 256), done: make(chan struct{})}
	for i := range 256 {
		r.ids <- byte(i)
	}
	go r.read()
	return r, nil
}

// close は接続を閉じ、待っている要求をすべて errClosed で終える。
func (r *rsConn) close() {
	r.once.Do(func() {
		close(r.done)
		_ = r.c.Close()
	})
}

// closed は閉じたら閉じるチャネル。
func (r *rsConn) closed() <-chan struct{} { return r.done }

func (r *rsConn) read() {
	defer r.close()
	var hdr [4]byte
	for {
		if _, err := io.ReadFull(r.c, hdr[:]); err != nil {
			return
		}
		n := int(binary.BigEndian.Uint16(hdr[2:4]))
		if n < 20 || n > radius.MaxPacketLength {
			return
		}
		b := make([]byte, n)
		copy(b, hdr[:])
		if _, err := io.ReadFull(r.c, b[4:]); err != nil {
			return
		}
		r.pmu.Lock()
		ch := r.pending[b[1]]
		r.pending[b[1]] = nil
		r.pmu.Unlock()
		if ch != nil {
			ch <- b
		}
	}
}

// exchange は要求を送って応答を待つ。Identifier を割り当て、Access-Request には Message-Authenticator を付ける。
// 応答の Response Authenticator（と Message-Authenticator があればそれ）を確かめる。
func (r *rsConn) exchange(ctx context.Context, p *radius.Packet, timeout time.Duration) (*radius.Packet, error) {
	var id byte
	select {
	case id = <-r.ids:
	case <-r.done:
		return nil, errClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	// 時間切れの後に遅れて届く応答が、同じ Identifier を使い回した次の要求に紛れないよう、時間切れの Identifier は 30 秒使わない
	quarantine := false
	defer func() {
		if !quarantine {
			r.ids <- id
			return
		}
		time.AfterFunc(30*time.Second, func() { r.ids <- id })
	}()
	p.Identifier = id
	if p.Code == radius.CodeAccessRequest {
		if err := radiusc.SetMessageAuthenticator(p); err != nil {
			return nil, err
		}
	}
	raw, err := p.Encode()
	if err != nil {
		return nil, err
	}
	ch := make(chan []byte, 1)
	r.pmu.Lock()
	r.pending[id] = ch
	r.pmu.Unlock()
	defer func() {
		r.pmu.Lock()
		if r.pending[id] == ch {
			r.pending[id] = nil
		}
		r.pmu.Unlock()
	}()
	r.wmu.Lock()
	_ = r.c.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err = r.c.Write(raw)
	r.wmu.Unlock()
	if err != nil {
		r.close()
		return nil, errClosed
	}
	t := time.NewTimer(timeout)
	defer t.Stop()
	select {
	case b := <-ch:
		if !radius.IsAuthenticResponse(b, raw, radsecSecret) {
			return nil, errors.New("応答の Authenticator が合わない")
		}
		resp, err := radius.Parse(b, radsecSecret)
		if err != nil {
			return nil, err
		}
		if p.Code == radius.CodeAccessRequest {
			if present, valid, err := radiusc.VerifyResponseMessageAuthenticator(resp, p.Authenticator, radsecSecret); err != nil || (present && !valid) {
				return nil, errors.New("応答の Message-Authenticator が合わない")
			}
		}
		return resp, nil
	case <-t.C:
		quarantine = true
		return nil, errTimeout
	case <-r.done:
		return nil, errClosed
	case <-ctx.Done():
		quarantine = true
		return nil, ctx.Err()
	}
}
