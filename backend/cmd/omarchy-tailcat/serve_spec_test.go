package main

import (
	"encoding/json"
	"testing"
)

func TestServeSpecPersistedAndReported(t *testing.T) {
	env := []string{"OMARCHY_TAILCAT_CONFIG_DIR=" + t.TempDir()}

	// Set the persisted spec.
	out, err := runBackend(t, env, "serve", "spec", "no-auth-ssh", "--key=default")
	if err != nil {
		t.Fatalf("spec set: %v\n%s", err, out)
	}
	sp := decodeJSON(t, out)
	if sp["key"] != "default" {
		t.Fatalf("spec key: %s", out)
	}

	// Read it back.
	out, err = runBackend(t, env, "serve", "spec")
	if err != nil {
		t.Fatalf("spec get: %v\n%s", err, out)
	}
	sp = decodeJSON(t, out)
	svcs, _ := sp["services"].([]any)
	if len(svcs) != 1 || sp["key"] != "default" {
		t.Fatalf("spec get: %s", out)
	}

	// `status` reports the configured spec alongside the listener.
	out, err = runBackend(t, env, "status")
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	var st map[string]any
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatalf("status not JSON: %s", out)
	}
	cfg, _ := st["configured"].(map[string]any)
	if cfg == nil || cfg["key"] != "default" {
		t.Fatalf("status configured: %s", out)
	}

	// Clearing removes it.
	out, err = runBackend(t, env, "serve", "spec", "clear")
	if err != nil {
		t.Fatalf("spec clear: %v\n%s", err, out)
	}
	out, err = runBackend(t, env, "serve", "spec")
	if err != nil {
		t.Fatalf("spec get after clear: %v\n%s", err, out)
	}
	sp = decodeJSON(t, out)
	if _, ok := sp["key"]; ok && sp["key"] != "" {
		t.Fatalf("spec not cleared: %s", out)
	}
}

func TestSocksRejectsBadFlag(t *testing.T) {
	env := []string{"OMARCHY_TAILCAT_CONFIG_DIR=" + t.TempDir()}
	out, err := runBackend(t, env, "socks", "start", "--port=99999")
	if err == nil {
		t.Fatalf("bad port should fail: %s", out)
	}
	var e map[string]any
	if err := json.Unmarshal([]byte(out), &e); err != nil || e["error"] == nil {
		t.Fatalf("expected error object: %s", out)
	}
}
