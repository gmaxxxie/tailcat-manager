package tailcat

import (
	"context"
	"time"
)

// Backend is the single integration boundary between the manager and Tailcat.
// The UI and domain layer depend only on this interface. Implementations:
//   - CLIBackend (backend/tailcat/cli.go)  — V0.1, wraps the tailcat binary
//   - NativeBackend (backend/tailcat/native.go) — V0.2, github.com/tailscale/tailcat
//
// Tailcat's CLI flags, Go API, and wire format have no stability promises, so
// everything Tailcat-specific stays inside these implementations.
type Backend interface {
	// Name identifies the backend implementation ("cli", "native").
	Name() string

	// Available reports whether the tailcat binary/library is installed and
	// usable, and whether its version satisfies our known-good pin.
	Available(ctx context.Context) (VersionInfo, error)

	// ValidateToken validates a connection target: a "tc..." token (decoded
	// locally via `tailcat parse`, no network) or a DNS name. It returns a
	// TokenInfo; invalid input returns ErrInvalidToken.
	ValidateToken(ctx context.Context, input string) (TokenInfo, error)

	// Identities (saved keys + the virtual ephemeral identity).
	ListIdentities(ctx context.Context) ([]Identity, error)
	CreateIdentity(ctx context.Context, name string, kind IdentityKind, region string) (Identity, error)
	DeleteIdentity(ctx context.Context, name string) error
	// CurrentClientPublicKey returns the nodekey:... public key of the client
	// identity that client modes would use (for building --allow lists).
	CurrentClientPublicKey(ctx context.Context) (string, error)

	// Listener lifecycle.
	StartListener(ctx context.Context, spec ListenerSpec) (ListenerStatus, error)
	StopListener(ctx context.Context) (ListenerStatus, error)
	RestartListener(ctx context.Context, spec ListenerSpec) (ListenerStatus, error)
	ListenerStatus(ctx context.Context) (ListenerStatus, error)

	// Connectivity diagnostics.
	Ping(ctx context.Context, target string, untilDirect bool, timeout time.Duration) (PingResult, error)

	// Diagnostics returns a redacted snapshot for the UI.
	Diagnostics(ctx context.Context) (DiagReport, error)
}
