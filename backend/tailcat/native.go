package tailcat

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// Native backend (V0.2+): file/text transfer built directly on
// github.com/tailscale/tailcat (Server + Client), used for transfer while V0.1
// operations remain on the CLI adapter. See docs/file-transfer.md.

// TransferPort is the single dedicated port for manager file/text traffic.
// It is handled directly by the native Server (not proxied to localhost).
const TransferPort = 42421

// Protocol version for the wire messages below.
const protoV = 1

// wireMsg is one JSON-line message of the V0.2 framing protocol.
type wireMsg struct {
	V       int    `json:"v"`
	Op      string `json:"op"` // file|accept|reject|error|done|cancel|text
	Name    string `json:"name,omitempty"`
	Size    int64  `json:"size,omitempty"`
	SHA256  string `json:"sha256,omitempty"`
	Sender  string `json:"sender,omitempty"`
	Text    string `json:"text,omitempty"`
	Message string `json:"message,omitempty"`
}

// IncomingFile is an offered file awaiting the receiver's decision.
type IncomingFile struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Size      int64     `json:"size"`
	Sender    string    `json:"sender,omitempty"`
	SHA256    string    `json:"sha256,omitempty"`
	OfferedAt time.Time `json:"offeredAt"`
}

// TransferResult is the outcome of a completed/aborted transfer.
type TransferResult struct {
	OK     bool   `json:"ok"`
	File   string `json:"file"` // destination (receiver) or source (sender)
	SHA256 string `json:"sha256,omitempty"`
	Bytes  int64  `json:"bytes"`
	Error  string `json:"error,omitempty"`
}

// ProgressFunc receives byte-count updates (nil is fine).
type ProgressFunc func(sent, total int64)

// writeMsg marshals m as a single JSON line.
func writeMsg(w io.Writer, m wireMsg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

// readMsg reads one JSON line.
func readMsg(r *bufio.Reader) (wireMsg, error) {
	line, err := r.ReadBytes('\n')
	if err != nil {
		return wireMsg{}, err
	}
	var m wireMsg
	if err := json.Unmarshal(line, &m); err != nil {
		return wireMsg{}, err
	}
	return m, nil
}

// errWriter writes a wire error and returns a wrapped error.
func writeError(w io.Writer, message string) error {
	_ = writeMsg(w, wireMsg{V: protoV, Op: "error", Message: message})
	return fmt.Errorf("%s", message)
}

// safeBase sanitizes an offered filename: base name only, no path separators,
// no "..", no NUL, bounded length.
func safeBase(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || name == "." || name == ".." {
		return "", errors.New("invalid file name")
	}
	if strings.ContainsAny(name, "/\\\x00") {
		return "", errors.New("file name must not contain path separators")
	}
	if len(name) > 255 {
		name = name[:255]
	}
	// Reject pure-dot and control characters.
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			return "", errors.New("file name contains control characters")
		}
	}
	return name, nil
}

// sha256Hex returns the hex SHA-256 of a file (or "" if it can't be read).
func sha256Hex(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

// --- Sender side -----------------------------------------------------------

// SendFileOffer is the sender-side configuration for one file transfer.
type SendFileOffer struct {
	Name   string
	Size   int64
	SHA256 string // optional
	Sender string
	Reader io.Reader // file bytes
}

// SendFileStream drives the sender side of the protocol over an open conn:
// offer → wait for accept → stream bytes → half-close → wait for done.
func SendFileStream(ctx context.Context, c net.Conn, offer SendFileOffer, progress ProgressFunc) (TransferResult, error) {
	br := bufio.NewReader(c)
	if err := writeMsg(c, wireMsg{
		V: protoV, Op: "file", Name: offer.Name, Size: offer.Size,
		SHA256: offer.SHA256, Sender: offer.Sender,
	}); err != nil {
		return TransferResult{}, err
	}
	// Wait for the receiver's decision.
	dec, err := readMsg(br)
	if err != nil {
		return TransferResult{}, err
	}
	switch dec.Op {
	case "reject":
		return TransferResult{}, fmt.Errorf("receiver rejected: %s", dec.Message)
	case "error":
		return TransferResult{}, fmt.Errorf("receiver error: %s", dec.Message)
	case "accept":
		// proceed
	default:
		return TransferResult{}, fmt.Errorf("unexpected response %q", dec.Op)
	}
	// Stream the file.
	buf := make([]byte, 256<<10)
	var sent int64
	for {
		if err := ctx.Err(); err != nil {
			_ = writeMsg(c, wireMsg{V: protoV, Op: "cancel"})
			return TransferResult{}, err
		}
		n, rerr := offer.Reader.Read(buf)
		if n > 0 {
			if _, werr := c.Write(buf[:n]); werr != nil {
				return TransferResult{}, werr
			}
			sent += int64(n)
			if progress != nil {
				progress(sent, offer.Size)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return TransferResult{}, rerr
		}
	}
	// Half-close so the receiver sees EOF (peer-EOF confirms delivery).
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		if err := cw.CloseWrite(); err != nil {
			return TransferResult{}, err
		}
	}
	// Wait for done / error.
	res, err := readMsg(br)
	if err != nil {
		return TransferResult{}, err
	}
	switch res.Op {
	case "done":
		return TransferResult{OK: true, Bytes: sent, SHA256: res.SHA256}, nil
	case "cancel":
		return TransferResult{}, errors.New("transfer cancelled by receiver")
	case "error":
		return TransferResult{}, fmt.Errorf("receiver error: %s", res.Message)
	default:
		return TransferResult{}, fmt.Errorf("unexpected final message %q", res.Op)
	}
}

// --- Receiver side ---------------------------------------------------------

// ReceiveOptions configures the receiver side.
type ReceiveOptions struct {
	// Decide is called for each offered file; return dest (chosen path) and ok.
	// Returning ok=false rejects. Decide runs on the connection handler
	// goroutine; it must return promptly (wire to a UI/queue).
	Decide func(IncomingFile) (dest string, ok bool)
	// Progress (optional) receives byte updates, tagged with the offer id.
	Progress func(id string, sent, total int64)
	// OnResult (optional) reports the terminal outcome of a connection.
	OnResult func(in IncomingFile, res TransferResult)
}

// finishRecv reports the outcome to OnResult (if set).
func (o ReceiveOptions) finish(in IncomingFile, res TransferResult) {
	if o.OnResult != nil {
		o.OnResult(in, res)
	}
}

// ReceiveFileStream drives the receiver side: read offer → decide → accept/
// reject → stream to dest (safe writes) → verify → done.
func ReceiveFileStream(c net.Conn, opts ReceiveOptions) (TransferResult, error) {
	br := bufio.NewReader(c)
	off, err := readMsg(br)
	if err != nil {
		return TransferResult{}, err
	}
	if off.Op != "file" {
		return TransferResult{}, fmt.Errorf("expected file offer, got %q", off.Op)
	}
	in := IncomingFile{
		ID: fmt.Sprintf("%x", time.Now().UnixNano()), Name: off.Name, Size: off.Size,
		Sender: off.Sender, SHA256: off.SHA256, OfferedAt: time.Now(),
	}
	if in.Name, err = safeBase(in.Name); err != nil {
		_ = writeMsg(c, wireMsg{V: protoV, Op: "reject", Message: err.Error()})
		res := TransferResult{Error: err.Error()}
		opts.finish(in, res)
		return res, err
	}
	if opts.Decide == nil {
		opts.Decide = func(IncomingFile) (string, bool) { return "", false }
	}
	dest, ok := opts.Decide(in)
	if !ok {
		_ = writeMsg(c, wireMsg{V: protoV, Op: "reject", Message: "rejected"})
		res := TransferResult{Error: "rejected"}
		opts.finish(in, res)
		return res, errors.New("rejected")
	}
	if err := writeMsg(c, wireMsg{V: protoV, Op: "accept"}); err != nil {
		return TransferResult{}, err
	}
	// Write to dest safely: never follow symlinks, refuse existing (O_EXCL)
	// unless the UI explicitly chose to overwrite (dest already resolved).
	if err := os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
		msg := "destination not writable"
		_ = writeMsg(c, wireMsg{V: protoV, Op: "error", Message: msg})
		res := TransferResult{Error: msg}
		opts.finish(in, res)
		return res, err
	}
	flag := os.O_WRONLY | os.O_CREATE | os.O_EXCL
	f, err := os.OpenFile(dest, flag, 0600)
	if err != nil {
		// Collision not resolved by the UI: refuse rather than overwrite.
		msg := "destination exists: " + filepath.Base(dest)
		_ = writeMsg(c, wireMsg{V: protoV, Op: "error", Message: msg})
		res := TransferResult{File: dest, Error: msg}
		opts.finish(in, res)
		return res, err
	}
	defer f.Close()
	h := sha256.New()
	buf := make([]byte, 256<<10)
	var received int64
	tr := io.TeeReader(br, h)
	for {
		n, rerr := tr.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				msg := "write failed"
				_ = writeMsg(c, wireMsg{V: protoV, Op: "error", Message: msg})
				res := TransferResult{File: dest, Bytes: received, Error: msg}
				opts.finish(in, res)
				return res, werr
			}
			received += int64(n)
			if opts.Progress != nil {
				opts.Progress(in.ID, received, in.Size)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			msg := "read failed"
			_ = writeMsg(c, wireMsg{V: protoV, Op: "error", Message: msg})
			res := TransferResult{File: dest, Bytes: received, Error: msg}
			opts.finish(in, res)
			return res, rerr
		}
	}
	got := hex.EncodeToString(h.Sum(nil))
	if in.SHA256 != "" && !strings.EqualFold(in.SHA256, got) {
		msg := "integrity mismatch"
		_ = writeMsg(c, wireMsg{V: protoV, Op: "error", Message: msg})
		os.Remove(dest)
		res := TransferResult{File: dest, Bytes: received, Error: msg}
		opts.finish(in, res)
		return res, errors.New("integrity mismatch")
	}
	_ = writeMsg(c, wireMsg{V: protoV, Op: "done", SHA256: got})
	res := TransferResult{OK: true, File: dest, Bytes: received, SHA256: got}
	opts.finish(in, res)
	return res, nil
}

// --- Native dial / server helpers -----------------------------------------

// SendFileToToken dials the transfer port of the server named by token and
// sends path (with an optional display name). Returns the transfer result.
func SendFileToToken(ctx context.Context, token, derpMapURL, path, name string, progress ProgressFunc) (TransferResult, error) {
	f, err := os.Open(path)
	if err != nil {
		return TransferResult{}, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return TransferResult{}, err
	}
	if name == "" {
		name = filepath.Base(path)
	}
	c, cl, err := DialToken(ctx, token, derpMapURL)
	if err != nil {
		return TransferResult{}, err
	}
	defer cl.Close()
	defer c.Close()
	offer := SendFileOffer{
		Name:   name,
		Size:   fi.Size(),
		SHA256: sha256Hex(path),
		Sender: filepath.Base(strings.TrimSuffix(os.Args[0], ".exe")),
		Reader: f,
	}
	return SendFileStream(ctx, c, offer, progress)
}

// DialToken opens the transfer-port stream to the server named by token,
// establishing the tunnel lazily. It retries the initial meow handshake until
// it succeeds or ctx expires: a freshly started receiver may still be coming
// up on DERP when we dial, and a single lost handshake would otherwise fail
// the transfer.
func DialToken(ctx context.Context, token, derpMapURL string) (net.Conn, *tailcat.Client, error) {
	cl := tailcat.NewClient(tailcat.ConnBlob(token))
	if derpMapURL != "" {
		cl.DERPMapURL = derpMapURL
	}
	cl.Logf = logger.Discard
	if ctx.Err() != nil {
		cl.Close()
		return nil, nil, ctx.Err()
	}
	for {
		pctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		_, err := cl.Ping(pctx)
		cancel()
		if err == nil {
			break
		}
		if ctx.Err() != nil {
			cl.Close()
			return nil, nil, err
		}
		select {
		case <-time.After(500 * time.Millisecond):
		case <-ctx.Done():
			cl.Close()
			return nil, nil, ctx.Err()
		}
	}
	c, err := cl.DialTCPPort(ctx, TransferPort)
	if err != nil {
		cl.Close()
		return nil, nil, err
	}
	return c, cl, nil
}

// ReceiverOptions selects the bootstrap DERP for a native receiver.
type ReceiverOptions struct {
	// DERPMapURL fetches the DERP map (like the CLI's --derpmap-url).
	DERPMapURL string
	// Region, if set, is used directly (no map fetch); mutually exclusive
	// with DERPMapURL.
	Region *tailcfg.DERPRegion
	// Logf, if non-nil, receives server diagnostics (default: discard).
	Logf logger.Logf
}

// Receiver is a long-running native file receiver (a tailcat.Server with the
// transfer port handled in-process).
type Receiver struct {
	srv    *tailcat.Server
	opts   ReceiveOptions
	mu     sync.Mutex
	closed bool
}

// StartReceiver builds and starts a native Server that accepts file offers on
// TransferPort. priv may be zero (ephemeral identity).
//
// The returned conn blob is a SHORT token (region-ID reference), matching the
// CLI server's default: embedded (full-address) regions are restored to
// RegionID 1 by ParseConnBlob and break DERP routing for any real region
// (upstream quirk), so we let clients resolve the region via the DERP map.
func StartReceiver(ctx context.Context, priv key.NodePrivate, opts ReceiverOptions, ropts ReceiveOptions) (*Receiver, string, error) {
	if priv.IsZero() {
		priv = key.NewNode()
	}
	logf := opts.Logf
	if logf == nil {
		logf = logger.Discard
	}
	// Resolve the bootstrap region so we can emit a short token referencing it.
	var reg *tailcfg.DERPRegion
	if opts.Region != nil {
		reg = opts.Region
	} else {
		ci := &tailcat.ConnInfo{RegionID: -1}
		exopts := []any{tailcat.ExpandForServer}
		if opts.DERPMapURL != "" {
			exopts = append(exopts, tailcat.DERPMapURL(opts.DERPMapURL))
		}
		if err := ci.Expand(ctx, exopts...); err != nil {
			return nil, "", err
		}
		reg = ci.Region[0]
	}
	s := &tailcat.Server{
		Key:        priv,
		Logf:       logf,
		Region:     reg,
		DERPMapURL: opts.DERPMapURL,
		OnTCP: func(port uint16) func(net.Conn) {
			if port != TransferPort {
				return nil
			}
			return func(c net.Conn) {
				_, _ = ReceiveFileStream(c, ropts)
			}
		},
	}
	if err := s.Start(); err != nil {
		return nil, "", err
	}
	tok := (&tailcat.ConnInfo{
		ServerPublic:      tailcat.NodePublic{NodePublic: priv.Public()},
		ServerDiscoPublic: tailcat.DiscoPublicForNode(priv),
		RegionID:          reg.RegionID,
	}).ConnBlob()
	return &Receiver{srv: s, opts: ropts}, string(tok), nil
}

// Close stops the receiver.
func (r *Receiver) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil
	}
	r.closed = true
	return r.srv.Close()
}
