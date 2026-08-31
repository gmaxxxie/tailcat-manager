// Hermetic end-to-end tests for the V0.2 native file-transfer adapter.
//
// Two layers:
//  1. Protocol tests over real TCP loopback conns (no tailcat/DERP needed) —
//     framing, reject, collision, name sanitization, integrity.
//  2. One full connectivity test through the real tailcat data plane: a local
//     DERP+STUN server (tailscale.com/tstest/integration), a receiver and a
//     sender each running as a separate `nativedemo` process (the way the
//     real product runs), all offline.
package e2e

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/tstest/integration"
	"tailscale.com/types/logger"

	"omarchy-tailcat/tailcat"
)

// tcpPair returns a connected TCP conn pair on loopback (supports CloseWrite).
func tcpPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	type res struct {
		c net.Conn
		e error
	}
	ch := make(chan res, 1)
	go func() {
		c, e := ln.Accept()
		ch <- res{c, e}
	}()
	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	r := <-ch
	if r.e != nil {
		t.Fatal(r.e)
	}
	return client, r.c
}

func shaHex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// runSend drives the sender side over c and returns the result.
func runSend(t *testing.T, c net.Conn, name string, payload []byte, sha string) (tailcat.TransferResult, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	offer := tailcat.SendFileOffer{Name: name, Size: int64(len(payload)), SHA256: sha, Reader: bytes.NewReader(payload)}
	return tailcat.SendFileStream(ctx, c, offer, nil)
}

// runRecv drives the receiver side over c and returns the result.
func runRecv(t *testing.T, c net.Conn, dest string, accept bool) (tailcat.TransferResult, error) {
	t.Helper()
	return tailcat.ReceiveFileStream(c, tailcat.ReceiveOptions{
		Decide: func(in tailcat.IncomingFile) (string, bool) {
			if !accept {
				return "", false
			}
			return filepath.Join(dest, in.Name), true
		},
	})
}

func TestProtocolHappyPath(t *testing.T) {
	dir := t.TempDir()
	payload := []byte("hello " + strings.Repeat("x", 100000))
	sha := shaHex(payload)

	sender, receiver := tcpPair(t)
	defer sender.Close()
	defer receiver.Close()

	var recvRes tailcat.TransferResult
	var recvErr error
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		recvRes, recvErr = runRecv(t, receiver, dir, true)
	}()

	res, err := runSend(t, sender, "presentation.pdf", payload, sha)
	wg.Wait()
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	if recvErr != nil {
		t.Fatalf("recv: %v", recvErr)
	}
	if !res.OK || res.SHA256 != sha || res.Bytes != int64(len(payload)) {
		t.Fatalf("send result: %+v", res)
	}
	if !recvRes.OK || recvRes.SHA256 != sha {
		t.Fatalf("recv result: %+v", recvRes)
	}
	got, err := os.ReadFile(filepath.Join(dir, "presentation.pdf"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("written file mismatch: %v", err)
	}
}

func TestProtocolReject(t *testing.T) {
	dir := t.TempDir()
	sender, receiver := tcpPair(t)
	defer sender.Close()
	defer receiver.Close()

	var recvErr error
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, recvErr = runRecv(t, receiver, dir, false)
	}()
	_, err := runSend(t, sender, "x.pdf", []byte("data"), "")
	wg.Wait()
	if err == nil || !strings.Contains(err.Error(), "rejected") {
		t.Fatalf("expected rejection, got %v", err)
	}
	if recvErr == nil || !strings.Contains(recvErr.Error(), "rejected") {
		t.Fatalf("receiver should also report rejection, got %v", recvErr)
	}
}

func TestProtocolNameSanitized(t *testing.T) {
	dir := t.TempDir()
	// "../evil" must be rejected by the receiver before the decision callback.
	sender, receiver := tcpPair(t)
	defer sender.Close()
	defer receiver.Close()
	gotName := ""
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _ = tailcat.ReceiveFileStream(receiver, tailcat.ReceiveOptions{
			Decide: func(in tailcat.IncomingFile) (string, bool) {
				gotName = in.Name
				return filepath.Join(dir, in.Name), true
			},
		})
	}()
	_, err := runSend(t, sender, "../evil.txt", []byte("nope"), "")
	wg.Wait()
	if err == nil {
		t.Fatalf("traversal name should be rejected")
	}
	if gotName != "" {
		t.Fatalf("Decide should not be called for unsafe names (got %q)", gotName)
	}
	if _, statErr := os.Stat(filepath.Join(dir, "evil.txt")); !os.IsNotExist(statErr) {
		t.Fatalf("unsafe path was written")
	}
}

func TestProtocolCollision(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("first"), 0600); err != nil {
		t.Fatal(err)
	}
	sender, receiver := tcpPair(t)
	defer sender.Close()
	defer receiver.Close()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _ = runRecv(t, receiver, dir, true) // auto-accept into dir
	}()
	_, err := runSend(t, sender, "a.txt", []byte("second"), "")
	wg.Wait()
	if err == nil || !strings.Contains(err.Error(), "exists") {
		t.Fatalf("expected collision refusal (no silent overwrite), got %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "a.txt"))
	if string(got) != "first" {
		t.Fatalf("original overwritten: %q", got)
	}
}

func TestProtocolIntegrityMismatch(t *testing.T) {
	dir := t.TempDir()
	sender, receiver := tcpPair(t)
	defer sender.Close()
	defer receiver.Close()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _ = runRecv(t, receiver, dir, true)
	}()
	// Offer a wrong SHA-256.
	_, err := runSend(t, sender, "i.pdf", []byte("payload"), "0000deadbeef")
	wg.Wait()
	if err == nil || !strings.Contains(err.Error(), "integrity") {
		t.Fatalf("expected integrity failure, got %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(dir, "i.pdf")); !os.IsNotExist(statErr) {
		t.Fatalf("partial file not removed")
	}
}

func TestProtocolProgress(t *testing.T) {
	dir := t.TempDir()
	payload := bytes.Repeat([]byte("z"), 1<<20)
	sender, receiver := tcpPair(t)
	defer sender.Close()
	defer receiver.Close()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _ = tailcat.ReceiveFileStream(receiver, tailcat.ReceiveOptions{
			Decide:   func(in tailcat.IncomingFile) (string, bool) { return filepath.Join(dir, in.Name), true },
			Progress: func(id string, sent, total int64) {},
		})
	}()
	var lastSent atomicInt64
	res, err := tailcat.SendFileStream(context.Background(), sender,
		tailcat.SendFileOffer{Name: "big.bin", Size: int64(len(payload)), Reader: bytes.NewReader(payload)},
		func(sent, total int64) { lastSent.store(sent) })
	wg.Wait()
	if err != nil || !res.OK || lastSent.load() != int64(len(payload)) {
		t.Fatalf("progress: res=%+v err=%v last=%d", res, err, lastSent.load())
	}
}

// --- full connectivity through the real tailcat data plane -----------------

func buildNativeDemo(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "nativedemo")
	out, err := exec.Command("go", "build", "-o", bin, "omarchy-tailcat/cmd/nativedemo").CombinedOutput()
	if err != nil {
		t.Fatalf("build nativedemo: %v\n%s", err, out)
	}
	return bin
}

// startLocalDERPMap starts a hermetic localhost DERP+STUN server and an HTTP
// server serving its DERP map (the upstream CLI-test pattern).
func startLocalDERPMap(t *testing.T) string {
	t.Helper()
	dm := integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1")
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		b, _ := json.Marshal(dm)
		w.Write(b)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL
}

// startReceiverProc runs nativedemo recv as a background process and returns
// its conn blob.
func startReceiverProc(t *testing.T, bin, mapURL, outdir string) string {
	t.Helper()
	cmd := exec.Command(bin, "recv", "--derp-map-url="+mapURL, "--outdir="+outdir)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill() })
	// Read the single JSON line with the blob (the process stays alive, so
	// read one line, not all of stdout).
	lineCh := make(chan string, 1)
	errCh := make(chan error, 1)
	go func() {
		r := bufio.NewReader(stdout)
		line, err := r.ReadString('\n')
		if err != nil {
			errCh <- err
			return
		}
		lineCh <- line
	}()
	select {
	case line := <-lineCh:
		var m struct {
			Blob string `json:"blob"`
		}
		if err := json.Unmarshal([]byte(line), &m); err != nil || m.Blob == "" {
			t.Fatalf("bad receiver output %q", line)
		}
		return m.Blob
	case err := <-errCh:
		t.Fatalf("reading receiver: %v", err)
	case <-time.After(30 * time.Second):
		t.Fatal("receiver did not publish a blob")
	}
	return ""
}

func TestNativeEndToEndThroughDERP(t *testing.T) {
	bin := buildNativeDemo(t)
	mapURL := startLocalDERPMap(t)
	outdir := t.TempDir()
	blob := startReceiverProc(t, bin, mapURL, outdir)

	// Build a real source file.
	src := filepath.Join(t.TempDir(), "real.pdf")
	payload := []byte("real tailcat data plane transfer " + strings.Repeat("q", 200000))
	if err := os.WriteFile(src, payload, 0600); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	res, err := tailcat.SendFileToToken(ctx, blob, mapURL, src, "real.pdf", nil)
	if err != nil {
		t.Fatalf("send through derp: %v", err)
	}
	if !res.OK || res.SHA256 != shaHex(payload) || res.Bytes != int64(len(payload)) {
		t.Fatalf("result: %+v", res)
	}
	got, err := os.ReadFile(filepath.Join(outdir, "real.pdf"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("received file mismatch: %v", err)
	}
}

// minimal atomic int64 helper (avoids an extra dep).
type atomicInt64 struct {
	mu sync.Mutex
	v  int64
}

func (a *atomicInt64) store(v int64) { a.mu.Lock(); a.v = v; a.mu.Unlock() }
func (a *atomicInt64) load() int64   { a.mu.Lock(); defer a.mu.Unlock(); return a.v }
