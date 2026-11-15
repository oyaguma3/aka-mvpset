package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"layeh.com/radius"
	"layeh.com/radius/rfc2866"
)

func TestIMSIAndKeys(t *testing.T) {
	if got := imsiOf(1); got != "440108000000001" || len(got) != 15 {
		t.Fatalf("imsiOf(1) = %s", got)
	}
	if got := imsiOf(200000); got != "440108000200000" {
		t.Fatalf("imsiOf(200000) = %s", got)
	}
	seed := bytes.Repeat([]byte{7}, 32)
	ki1, opc1 := keysOf(seed, imsiOf(1))
	ki2, opc2 := keysOf(seed, imsiOf(1))
	if !bytes.Equal(ki1, ki2) || !bytes.Equal(opc1, opc2) || len(ki1) != 16 || len(opc1) != 16 {
		t.Fatal("同じ種と IMSI から同じ鍵にならない")
	}
	if bytes.Equal(ki1, opc1) {
		t.Fatal("Ki と OPc が同じ")
	}
	ki3, _ := keysOf(seed, imsiOf(2))
	other := bytes.Repeat([]byte{8}, 32)
	ki4, _ := keysOf(other, imsiOf(1))
	if bytes.Equal(ki1, ki3) || bytes.Equal(ki1, ki4) {
		t.Fatal("IMSI か種が違うのに同じ鍵")
	}
}

func TestWriteCSV(t *testing.T) {
	seed := bytes.Repeat([]byte{1}, 32)
	var b bytes.Buffer
	if err := writeCSV(&b, "vecgen", seed, 9, 11); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(b.String()), "\n")
	if len(lines) != 4 || lines[0] != "imsi,ki,opc,amf,sqn" || !strings.HasPrefix(lines[1], "440108000000009,") || !strings.HasSuffix(lines[1], ",,") {
		t.Fatalf("vecgen の CSV: %q", lines)
	}
	b.Reset()
	if err := writeCSV(&b, "radius", seed, 1, 2); err != nil {
		t.Fatal(err)
	}
	if b.String() != "imsi\n440108000000001\n440108000000002\n" {
		t.Fatalf("radius の CSV: %q", b.String())
	}
	if err := writeCSV(&b, "x", seed, 1, 2); err == nil {
		t.Fatal("知らない種類を断らない")
	}
}

func TestReadSeed(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "seed")
	_ = os.WriteFile(p, make([]byte, 31), 0o600)
	if _, err := readSeed(p); err == nil {
		t.Fatal("31 バイトの種を断らない")
	}
	_ = os.WriteFile(p, make([]byte, 32), 0o600)
	if _, err := readSeed(p); err != nil {
		t.Fatal(err)
	}
}

func TestPercentiles(t *testing.T) {
	var v []float64
	for i := 1; i <= 100; i++ {
		v = append(v, float64(i)/1000)
	}
	p := percentilesOf(v)
	if p.N != 100 || p.P50 != 0.05 || p.P95 != 0.095 || p.P99 != 0.099 || p.Max != 0.1 {
		t.Fatalf("分位 = %+v", p)
	}
	if percentilesOf(nil).N != 0 {
		t.Fatal("空のとき")
	}
}

func TestRecorderLabels(t *testing.T) {
	r := newRecorder()
	r.setLabel("a")
	r.add("", counts{Started: 1, Accept: 1}, 0.01)
	r.add("b", counts{Started: 1, Timeout: 1}, 0)
	label, c, p := r.flush()
	if label != "a" || c.Started != 2 || p.N != 1 {
		t.Fatalf("窓 = %s %+v %+v", label, c, p)
	}
	s := r.summary()
	if len(s) != 2 || s[0].Label != "a" || s[1].Label != "b" || s[1].Failures != 1 {
		t.Fatalf("まとめ = %+v", s)
	}
}

// testPKI は試しの CA と、その CA で署名したサーバー証明書・クライアント証明書を作る。
func testPKI(t *testing.T) (dir string) {
	t.Helper()
	dir = t.TempDir()
	key := func() *ecdsa.PrivateKey {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return k
	}
	write := func(name string, der []byte, k *ecdsa.PrivateKey) {
		_ = os.WriteFile(filepath.Join(dir, name+".pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600)
		if k != nil {
			kb, _ := x509.MarshalECPrivateKey(k)
			_ = os.WriteFile(filepath.Join(dir, name+".key"), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600)
		}
	}
	caKey := key()
	caTmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ca"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER, _ := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	ca, _ := x509.ParseCertificate(caDER)
	write("ca", caDER, nil)
	for i, name := range []string{"server", "client"} {
		k := key()
		eku := x509.ExtKeyUsageServerAuth
		if name == "client" {
			eku = x509.ExtKeyUsageClientAuth
		}
		tmpl := &x509.Certificate{SerialNumber: big.NewInt(int64(i + 2)), Subject: pkix.Name{CommonName: name}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
			ExtKeyUsage: []x509.ExtKeyUsage{eku}, DNSNames: []string{"primary.example.net"}}
		der, _ := x509.CreateCertificate(rand.Reader, tmpl, ca, &k.PublicKey, caKey)
		write(name, der, k)
	}
	return dir
}

// TestRadSecExchange は、IP でつないで名前を照らさずに鎖を確かめ、Identifier ごとに応答を受け、時間切れと切断を分けることを確かめる。
func TestRadSecExchange(t *testing.T) {
	dir := testPKI(t)
	srvCert, err := tls.LoadX509KeyPair(filepath.Join(dir, "server.pem"), filepath.Join(dir, "server.key"))
	if err != nil {
		t.Fatal(err)
	}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{srvCert}, ClientAuth: tls.RequireAnyClientCert})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	// 偽のエッジ: Accounting-Request に応え、Acct-Session-Id が "slow" のものには応えない
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				hdr := make([]byte, 4)
				for {
					if _, err := io.ReadFull(c, hdr); err != nil {
						return
					}
					b := make([]byte, binary.BigEndian.Uint16(hdr[2:4]))
					copy(b, hdr)
					if _, err := io.ReadFull(c, b[4:]); err != nil {
						return
					}
					req, err := radius.Parse(b, radsecSecret)
					if err != nil {
						return
					}
					if rfc2866.AcctSessionID_GetString(req) == "slow" {
						continue
					}
					resp := req.Response(radius.CodeAccountingResponse)
					out, _ := resp.Encode()
					_, _ = c.Write(out)
				}
			}(c)
		}
	}()
	cfg, err := tlsConfigFor(filepath.Join(dir, "client.pem"), filepath.Join(dir, "client.key"), filepath.Join(dir, "ca.pem"))
	if err != nil {
		t.Fatal(err)
	}
	c, err := dialRadSec(context.Background(), ln.Addr().String(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.close()
	send := func(id string, timeout time.Duration) error {
		p := radius.New(radius.CodeAccountingRequest, radsecSecret)
		_ = rfc2866.AcctSessionID_SetString(p, id)
		_, err := c.exchange(context.Background(), p, timeout)
		return err
	}
	for i := range 300 { // Identifier を使い回す
		if err := send("ok", time.Second); err != nil {
			t.Fatalf("%d 回目: %v", i, err)
		}
	}
	if err := send("slow", 200*time.Millisecond); err != errTimeout {
		t.Fatalf("時間切れ: %v", err)
	}
	c.close()
	if err := send("ok", time.Second); err != errClosed {
		t.Fatalf("切断: %v", err)
	}
	// 別の CA のサーバー証明書は断る
	other := testPKI(t)
	bad, _ := tlsConfigFor(filepath.Join(dir, "client.pem"), filepath.Join(dir, "client.key"), filepath.Join(other, "ca.pem"))
	if _, err := dialRadSec(context.Background(), ln.Addr().String(), bad); err == nil {
		t.Fatal("別の CA のサーバー証明書を受けた")
	}
}
