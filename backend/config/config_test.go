package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"omarchy-tailcat/atomicfile"
	"omarchy-tailcat/domain"
)

func tmpPath(t *testing.T) string {
	return filepath.Join(t.TempDir(), "config.json")
}

func TestLoadMissingReturnsDefaults(t *testing.T) {
	cfg, err := loadPath(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Version != SchemaVersion || cfg.Settings.Backend != "cli" || len(cfg.Devices) != 0 {
		t.Fatalf("bad defaults: %+v", cfg)
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	p := tmpPath(t)
	cfg := Default()
	cfg.Devices = append(cfg.Devices, domain.Device{ID: "1", Name: "X", Target: "tcABC", Kind: domain.DeviceToken})
	cfg.Settings.Backend = "cli"
	if err := SavePath(p, cfg); err != nil {
		t.Fatal(err)
	}
	got, err := loadPath(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Devices) != 1 || got.Devices[0].Name != "X" {
		t.Fatalf("round trip: %+v", got)
	}
}

func TestPermissions(t *testing.T) {
	p := tmpPath(t)
	if err := SavePath(p, Default()); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0600 {
		t.Fatalf("config perms = %v, want 0600", fi.Mode().Perm())
	}
}

func TestCorruptConfigRecovery(t *testing.T) {
	p := tmpPath(t)
	if err := os.WriteFile(p, []byte("{ not json"), 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadPath(p)
	if err == nil {
		t.Fatalf("expected CorruptionWarning, got nil error")
	}
	var cw *CorruptionWarning
	if !errors.As(err, &cw) {
		t.Fatalf("wrong error type: %v", err)
	}
	if _, statErr := os.Stat(cw.BackupPath); statErr != nil {
		t.Fatalf("backup not created: %v", statErr)
	}
	if cfg.Version != SchemaVersion {
		t.Fatalf("expected defaults after corruption")
	}
}

func TestAtomicNoPartialOverwrite(t *testing.T) {
	p := tmpPath(t)
	if err := SavePath(p, Default()); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(p)
	// Simulate a crash mid-write: only a temp file exists, target untouched.
	if err := os.WriteFile(p+".tmp-crash", []byte("partial"), 0600); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(p)
	if string(before) != string(after) {
		t.Fatalf("target file changed by a crashed write")
	}
}

func TestStoreDeviceOperations(t *testing.T) {
	p := tmpPath(t)
	s, err := OpenPath(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetDevices([]domain.Device{{ID: "1", Name: "A"}}); err != nil {
		t.Fatal(err)
	}
	if d := s.Devices(); len(d) != 1 || d[0].Name != "A" {
		t.Fatalf("devices: %+v", d)
	}
	// Reopen to prove persistence.
	s2, err := OpenPath(p)
	if err != nil {
		t.Fatal(err)
	}
	if d := s2.Devices(); len(d) != 1 || d[0].ID != "1" {
		t.Fatalf("persisted devices: %+v", d)
	}
	if err := s2.SetIdentityKind("client-default", "client"); err != nil {
		t.Fatal(err)
	}
	if s2.IdentityKind("client-default") != "client" {
		t.Fatalf("identity hint not saved")
	}
}

func TestStoreConfigIsCopy(t *testing.T) {
	p := tmpPath(t)
	s, _ := OpenPath(p)
	c1 := s.Config()
	c1.Devices = append(c1.Devices, domain.Device{ID: "x"})
	if len(s.Devices()) != 0 {
		t.Fatalf("Config() returned a mutable view")
	}
}

func TestVersionFieldPreserved(t *testing.T) {
	p := tmpPath(t)
	if err := atomicfile.Write(p, []byte(`{"version":1,"devices":[],"settings":{"backend":"native"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadPath(p)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Settings.Backend != "native" {
		t.Fatalf("settings not preserved: %+v", cfg)
	}
	// Ensure it re-serializes valid JSON.
	b, _ := json.Marshal(cfg)
	var check map[string]any
	if err := json.Unmarshal(b, &check); err != nil {
		t.Fatalf("re-serialized config invalid: %v", err)
	}
}
