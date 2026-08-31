// Package config is the manager's persisted configuration:
// ~/.config/omarchy-tailcat/config.json (or $OMARCHY_TAILCAT_CONFIG_DIR).
// It is separate from Tailcat's own config (~/.config/tailcat/), which we never
// write. All writes are atomic (temp + fsync + rename) with 0600 perms.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"omarchy-tailcat/atomicfile"
	"omarchy-tailcat/domain"
)

// SchemaVersion is the current config schema version.
const SchemaVersion = 1

// Settings holds manager preferences.
type Settings struct {
	Backend       string            `json:"backend"`                 // "cli" | "native"
	IdentityKinds map[string]string `json:"identityKinds,omitempty"` // key name -> "server"|"client"
	DerpMapURL    string            `json:"derpmapURL,omitempty"`
}

// Config is the versioned on-disk schema.
type Config struct {
	Version  int             `json:"version"`
	Devices  []domain.Device `json:"devices"`
	Settings Settings        `json:"settings"`
}

// Default returns a fresh config with current schema.
func Default() *Config {
	return &Config{
		Version: SchemaVersion,
		Devices: []domain.Device{},
		Settings: Settings{
			Backend:       "cli",
			IdentityKinds: map[string]string{},
		},
	}
}

// CorruptionWarning is returned when the config file was unreadable; the
// manager starts with defaults and preserves the broken file.
type CorruptionWarning struct{ BackupPath string }

func (c *CorruptionWarning) Error() string {
	return "config was corrupt; backed up to " + c.BackupPath
}

// Dir returns the manager config directory, honoring
// OMARCHY_TAILCAT_CONFIG_DIR for tests/portability.
func Dir() string {
	if d := os.Getenv("OMARCHY_TAILCAT_CONFIG_DIR"); d != "" {
		return d
	}
	cd, err := os.UserConfigDir()
	if err != nil {
		cd = os.Getenv("HOME")
	}
	return filepath.Join(cd, "omarchy-tailcat")
}

// Path returns the config file path.
func Path() string { return filepath.Join(Dir(), "config.json") }

// Load reads the config. A missing file yields defaults (no error). A corrupt
// file is moved aside and defaults are returned, with a CorruptionWarning.
func Load() (*Config, error) {
	return loadPath(Path())
}

func loadPath(path string) (*Config, error) {
	b, err := atomicfile.Read(path)
	if errors.Is(err, atomicfile.ErrNotFound) {
		return Default(), nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading config: %w", err)
	}
	cfg := &Config{}
	if err := json.Unmarshal(b, cfg); err != nil {
		// Preserve the broken file for diagnosis; start fresh.
		backup := fmt.Sprintf("%s.corrupt-%d", path, time.Now().Unix())
		_ = os.Rename(path, backup)
		return Default(), &CorruptionWarning{BackupPath: backup}
	}
	if cfg.Version == 0 {
		cfg.Version = SchemaVersion
	}
	if cfg.Settings.IdentityKinds == nil {
		cfg.Settings.IdentityKinds = map[string]string{}
	}
	if cfg.Settings.Backend == "" {
		cfg.Settings.Backend = "cli"
	}
	return cfg, nil
}

// Save writes cfg atomically with 0600 perms.
func Save(cfg *Config) error {
	return SavePath(Path(), cfg)
}

// SavePath writes cfg to path atomically.
func SavePath(path string, cfg *Config) error {
	if cfg.Version == 0 {
		cfg.Version = SchemaVersion
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return atomicfile.Write(path, data, 0600)
}

// Store is a concurrency-safe, persistence-backed view of Config that also
// implements domain.DeviceStore.
type Store struct {
	mu   sync.Mutex
	cfg  *Config
	path string
}

// Open loads (or creates) the config and returns a Store.
func Open() (*Store, error) {
	return OpenPath(Path())
}

// OpenPath loads the config at path.
func OpenPath(path string) (*Store, error) {
	cfg, err := loadPath(path)
	if err != nil {
		return nil, err
	}
	return &Store{cfg: cfg, path: path}, nil
}

// Config returns the current config snapshot (copy).
func (s *Store) Config() *Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := *s.cfg
	out.Devices = append([]domain.Device(nil), s.cfg.Devices...)
	kinds := map[string]string{}
	for k, v := range s.cfg.Settings.IdentityKinds {
		kinds[k] = v
	}
	out.Settings.IdentityKinds = kinds
	return &out
}

// SetBackend sets the backend implementation name.
func (s *Store) SetBackend(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg.Settings.Backend = name
	return s.save()
}

// IdentityKind returns the recorded kind ("server"/"client") for a key name,
// or "" if unknown.
func (s *Store) IdentityKind(name string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg.Settings.IdentityKinds[name]
}

// SetIdentityKind records the kind of a saved key (manager-local hint; the
// backend cannot reliably distinguish server vs client keys).
func (s *Store) SetIdentityKind(name, kind string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cfg.Settings.IdentityKinds == nil {
		s.cfg.Settings.IdentityKinds = map[string]string{}
	}
	s.cfg.Settings.IdentityKinds[name] = kind
	return s.save()
}

// RemoveIdentityKind forgets the kind hint (e.g. after deletion).
func (s *Store) RemoveIdentityKind(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.cfg.Settings.IdentityKinds, name)
	return s.save()
}

// Devices implements domain.DeviceStore.
func (s *Store) Devices() []domain.Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]domain.Device(nil), s.cfg.Devices...)
}

// SetDevices implements domain.DeviceStore.
func (s *Store) SetDevices(devs []domain.Device) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg.Devices = append([]domain.Device(nil), devs...)
	return s.save()
}

func (s *Store) save() error {
	data, err := json.MarshalIndent(s.cfg, "", "  ")
	if err != nil {
		return err
	}
	return atomicfile.Write(s.path, data, 0600)
}
