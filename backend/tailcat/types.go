// Package tailcat is the integration boundary for Tailcat. It defines the
// TailcatBackend interface plus the domain types shared between the CLI
// adapter (V0.1) and the native Go library adapter (V0.2). The UI and the
// manager domain layer depend only on this package, never on Tailcat specifics.
//
// This package must stay independent of any concrete implementation so that
// upstream Tailcat API/CLI churn is isolated behind one adapter.
package tailcat

import "time"

// IdentityKind says whether a saved key is a server identity (used by the
// listener, has a DERP region) or a client identity (used to authenticate to
// a server's --allow list; no region).
type IdentityKind string

const (
	IdentityServer IdentityKind = "server"
	IdentityClient IdentityKind = "client"
)

// ServiceKind is the kind of an inbound service on the listener.
type ServiceKind string

const (
	// ServicePortForward proxies the served port to localhost:<port>.
	ServicePortForward ServiceKind = "port-forward"
	// ServiceNoAuthSSH is the built-in auth-free SSH server (port 22).
	ServiceNoAuthSSH ServiceKind = "no-auth-ssh"
	// ServiceFiles serves a directory to SFTP clients (scp/sftp/ls).
	ServiceFiles ServiceKind = "files"
	// ServiceExitNode relays connections to arbitrary IP:port on the
	// server's network. Exposed as an optional service only; we build no
	// routing UI.
	ServiceExitNode ServiceKind = "exit-node"
)

// Service describes one inbound service on the listener.
type Service struct {
	Name    string      `json:"name"`
	Kind    ServiceKind `json:"kind"`
	Port    uint16      `json:"port,omitempty"` // ServicePortForward only
	Enabled bool        `json:"enabled"`
}

// VersionInfo describes whether the tailcat backend is available and usable.
type VersionInfo struct {
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	MinOK     bool   `json:"minOK"`
	Path      string `json:"path,omitempty"`
	Err       string `json:"error,omitempty"`
}

// TokenInfo is the result of validating a connection target (a tailcat token
// or a DNS name). It never carries the full token in serialized output.
type TokenInfo struct {
	Valid      bool   `json:"valid"`
	IsDNSName  bool   `json:"isDNSName"`
	Embedded   bool   `json:"embedded"` // token embeds full DERP region info
	RegionID   int    `json:"regionID,omitempty"`
	RegionCode string `json:"regionCode,omitempty"`
	RegionName string `json:"regionName,omitempty"`
	ServerPub  string `json:"serverPub,omitempty"` // nodekey:... (public only)
}

// Identity is a saved key (or the virtual ephemeral identity) surfaced to the
// user. Public key material only; private keys are never exposed.
type Identity struct {
	Name       string       `json:"name"`
	Kind       IdentityKind `json:"kind"`
	Persistent bool         `json:"persistent"` // saved key vs ephemeral
	IsDefault  bool         `json:"isDefault"`
	PublicKey  string       `json:"publicKey,omitempty"` // client identities only
}

// ListenerSpec configures the listener (server).
type ListenerSpec struct {
	Services  []Service `json:"services"`
	Key       string    `json:"key,omitempty"` // "" auto, "new" ephemeral, or saved key name
	Allow     []string  `json:"allow,omitempty"`
	AllowNone bool      `json:"allowNone,omitempty"`
	FilesDir  string    `json:"filesDir,omitempty"`  // ServiceFiles only
	FilesMode string    `json:"filesMode,omitempty"` // ro | rw | wo (default ro)
	FullAddr  bool      `json:"fullAddr,omitempty"`
}

// Empty reports whether the spec carries no services and no options — a caller
// passed nothing, so a saved spec (if any) should be reused.
func (s ListenerSpec) Empty() bool {
	return len(s.Services) == 0 && s.Key == "" && s.FilesDir == "" && len(s.Allow) == 0 && !s.AllowNone && !s.FullAddr
}

// ListenerStatus is a snapshot of the managed listener.
type ListenerStatus struct {
	Running   bool      `json:"running"`
	Addr      string    `json:"addr,omitempty"`
	KeyInUse  string    `json:"keyInUse,omitempty"` // "ephemeral" or saved key name
	Region    string    `json:"region,omitempty"`   // human region name if known
	RegionID  int       `json:"regionID,omitempty"`
	Services  []Service `json:"services,omitempty"`
	StartedAt time.Time `json:"startedAt,omitempty"`
	PID       int       `json:"pid,omitempty"`
	Broad     bool      `json:"broad,omitempty"` // serving "all" localhost ports
}

// PingResult reports connectivity and the path a pong took.
type PingResult struct {
	Ok         bool          `json:"ok"`
	Direct     bool          `json:"direct"`
	Endpoint   string        `json:"endpoint,omitempty"` // ip:port when direct
	RegionID   int           `json:"regionID,omitempty"`
	RegionCode string        `json:"regionCode,omitempty"`
	RegionName string        `json:"regionName,omitempty"`
	Latency    time.Duration `json:"latency"`
}

// DiagReport is a redacted diagnostics snapshot for the UI.
type DiagReport struct {
	Backend  string         `json:"backend"`
	Version  VersionInfo    `json:"version"`
	Listener ListenerStatus `json:"listener"`
	LogTail  []string       `json:"logTail,omitempty"` // redacted
}

// CurrentListenerProvider is implemented by backends that keep a supervised
// listener (currently the CLI backend).
type CurrentListenerProvider interface {
	CurrentListener() (ListenerStatus, ListenerSpec, bool)
}
