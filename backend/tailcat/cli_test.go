package tailcat

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// fakeTailcatPath returns the path to the fake tailcat script.
func fakeTailcatPath(t *testing.T) string {
	t.Helper()
	p := filepath.Join("..", "testdata", "fake-tailcat.sh")
	abs, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(abs, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return abs
}

func newFakeBackend(t *testing.T) *CLIBackend {
	t.Helper()
	t.Setenv("FAKE_KEYS_DIR", t.TempDir())
	return &CLIBackend{Bin: fakeTailcatPath(t)}
}

func TestAvailable(t *testing.T) {
	b := newFakeBackend(t)
	v, err := b.Available(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !v.Available || v.Version != "v0.1.0" || !v.MinOK {
		t.Fatalf("available: %+v", v)
	}
}

func TestAvailableNotInstalled(t *testing.T) {
	b := &CLIBackend{Bin: filepath.Join(t.TempDir(), "does-not-exist")}
	v, err := b.Available(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if v.Available {
		t.Fatalf("should not be available: %+v", v)
	}
}

func TestValidateToken(t *testing.T) {
	b := newFakeBackend(t)
	ctx := context.Background()

	ti, err := b.ValidateToken(ctx, "  tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  ")
	if err != nil {
		t.Fatalf("good token: %v", err)
	}
	if !ti.Valid || ti.IsDNSName || ti.Embedded || ti.RegionID != 302 {
		t.Fatalf("good token info: %+v", ti)
	}
	if !strings.HasPrefix(ti.ServerPub, "nodekey:") {
		t.Fatalf("server pub: %q", ti.ServerPub)
	}

	ti, err = b.ValidateToken(ctx, "tcEMBEDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	if err != nil {
		t.Fatalf("embedded token: %v", err)
	}
	if !ti.Embedded || ti.RegionCode != "sfo" || ti.RegionName != "San Francisco" {
		t.Fatalf("embedded info: %+v", ti)
	}

	ti, err = b.ValidateToken(ctx, "example.com")
	if err != nil || !ti.IsDNSName || !ti.Valid {
		t.Fatalf("dns name: %+v err=%v", ti, err)
	}

	for _, bad := range []string{"", "  ", "https://evil.example.com", "rm -rf /", "tc", "tc!!short", "../x"} {
		if _, err := b.ValidateToken(ctx, bad); err == nil {
			t.Errorf("ValidateToken(%q) should fail", bad)
		}
	}

	_, err = b.ValidateToken(ctx, "tcBADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	var te *Error
	if !errors.As(err, &te) || te.Kind != ErrInvalidToken {
		t.Fatalf("bad token should be ErrInvalidToken, got %v", err)
	}
}

func TestParseTokenJSON(t *testing.T) {
	ti, err := parseTokenJSON(`{"ServerPublic":"nodekey:abc","RegionID":302}`)
	if err != nil || ti.RegionID != 302 || ti.Embedded {
		t.Fatalf("short: %+v err=%v", ti, err)
	}
	ti, err = parseTokenJSON(`{"ServerPublic":"nodekey:abc","Region":[{"RegionID":302,"RegionCode":"sfo","RegionName":"San Francisco"}]}`)
	if err != nil || !ti.Embedded || ti.RegionCode != "sfo" {
		t.Fatalf("embedded: %+v err=%v", ti, err)
	}
	if _, err := parseTokenJSON("not json"); err == nil {
		t.Fatalf("bad json should fail")
	}
}

func TestCreateDeleteIdentity(t *testing.T) {
	b := newFakeBackend(t)
	ctx := context.Background()

	id, err := b.CreateIdentity(ctx, "work", IdentityServer, "")
	if err != nil {
		t.Fatalf("create server: %v", err)
	}
	if id.Name != "work" || !id.Persistent || id.Kind != IdentityServer {
		t.Fatalf("server identity: %+v", id)
	}

	cid, err := b.CreateIdentity(ctx, "laptop", IdentityClient, "")
	if err != nil {
		t.Fatalf("create client: %v", err)
	}
	if cid.Kind != IdentityClient || !strings.HasPrefix(cid.PublicKey, "nodekey:") {
		t.Fatalf("client identity: %+v", cid)
	}

	// Duplicate should map to ErrKeyExists.
	if _, err := b.CreateIdentity(ctx, "work", IdentityServer, ""); err == nil {
		t.Fatalf("duplicate should fail")
	} else {
		var te *Error
		if !errors.As(err, &te) || te.Kind != ErrKeyExists {
			t.Fatalf("duplicate kind = %v", err)
		}
	}

	ids, err := b.ListIdentities(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// Fake returns "default" and "client-default"; plus virtual ephemeral.
	if len(ids) < 3 || ids[0].Name != "new" {
		t.Fatalf("identities: %+v", ids)
	}

	if err := b.DeleteIdentity(ctx, "work"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if err := b.DeleteIdentity(ctx, "work"); err == nil {
		t.Fatalf("second delete should fail")
	}
}

func TestIdentityNameValidation(t *testing.T) {
	b := newFakeBackend(t)
	ctx := context.Background()
	for _, bad := range []string{"", "new", "../evil", "a/b", "has space", strings.Repeat("x", 65)} {
		if _, err := b.CreateIdentity(ctx, bad, IdentityServer, ""); err == nil {
			t.Errorf("CreateIdentity(%q) should fail", bad)
		}
	}
	// region=list is a listing mode, not a region.
	if _, err := b.CreateIdentity(ctx, "work", IdentityServer, "list"); err == nil {
		t.Errorf("region=list should be rejected")
	} else {
		var te *Error
		if !errors.As(err, &te) || te.Kind != ErrInvalidInput {
			t.Fatalf("region=list kind: %v", err)
		}
	}
}

func TestPing(t *testing.T) {
	b := newFakeBackend(t)
	ctx := context.Background()

	pr, err := b.Ping(ctx, "tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", false, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !pr.Ok || pr.Direct || pr.RegionCode != "sfo" || pr.Latency <= 0 {
		t.Fatalf("ping derp: %+v", pr)
	}

	pr, err = b.Ping(ctx, "tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", true, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !pr.Direct || !strings.Contains(pr.Endpoint, ":") {
		t.Fatalf("ping direct: %+v", pr)
	}

	_, err = b.Ping(ctx, "tcBADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", false, 10*time.Second)
	var te *Error
	if !errors.As(err, &te) || te.Kind != ErrPingFailed {
		t.Fatalf("bad ping kind: %v", err)
	}
}

func TestParsePong(t *testing.T) {
	pr, err := parsePong("pong in 42.1ms via DERP(sfo)")
	if err != nil || pr.Direct || pr.RegionCode != "sfo" || pr.Latency != 42100000 {
		t.Fatalf("derp: %+v err=%v", pr, err)
	}
	pr, err = parsePong("pong in 1.2ms via 203.0.113.7:41641")
	if err != nil || !pr.Direct || pr.Endpoint != "203.0.113.7:41641" {
		t.Fatalf("direct: %+v err=%v", pr, err)
	}
	if _, err := parsePong("bogus"); err == nil {
		t.Fatalf("bogus pong should fail")
	}
}

func TestBuildServiceArgs(t *testing.T) {
	svcs := []Service{
		{Name: "Web", Kind: ServicePortForward, Port: 8080, Enabled: true},
		{Name: "SSH", Kind: ServiceNoAuthSSH, Enabled: true},
	}
	args, broad, err := buildServiceArgs(svcs)
	if err != nil || broad {
		t.Fatalf("args=%v broad=%v err=%v", args, broad, err)
	}
	if strings.Join(args, ",") != "8080,no-auth-ssh" {
		t.Fatalf("args: %v", args)
	}

	// Empty services => broad "all".
	args, broad, err = buildServiceArgs(nil)
	if err != nil || !broad || strings.Join(args, ",") != "all" {
		t.Fatalf("empty: %v broad=%v err=%v", args, broad, err)
	}

	// All disabled => error.
	if _, _, err := buildServiceArgs([]Service{{Name: "x", Kind: ServicePortForward, Port: 1, Enabled: false}}); err == nil {
		t.Fatalf("all-disabled should error")
	}

	// Duplicate port => error.
	if _, _, err := buildServiceArgs([]Service{
		{Kind: ServicePortForward, Port: 80, Enabled: true},
		{Kind: ServicePortForward, Port: 80, Enabled: true},
	}); err == nil {
		t.Fatalf("duplicate port should error")
	}
}

func TestServeArgv(t *testing.T) {
	b := newFakeBackend(t)
	spec := ListenerSpec{
		Services: []Service{{Name: "Web", Kind: ServicePortForward, Port: 8080, Enabled: true}},
		Key:      "default",
		Allow:    []string{"nodekey:aaa", "nodekey:bbb"},
	}
	argv, broad, err := b.serveArgv(spec)
	if err != nil || broad {
		t.Fatalf("argv=%v broad=%v err=%v", argv, broad, err)
	}
	joined := strings.Join(argv, " ")
	if !strings.Contains(joined, "serve") || !strings.Contains(joined, "--key=default") ||
		!strings.Contains(joined, "--allow=nodekey:aaa,nodekey:bbb") || !strings.Contains(joined, "8080") {
		t.Fatalf("argv: %v", argv)
	}
	// No shell metacharacters allowed.
	for _, a := range argv {
		if strings.ContainsAny(a, ";|&$`<>") {
			t.Fatalf("dangerous argv element: %q", a)
		}
	}
}
