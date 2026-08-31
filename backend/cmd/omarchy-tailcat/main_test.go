package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runBackend builds the binary once and runs it with args, returning stdout.
func runBackend(t *testing.T, env []string, args ...string) (string, error) {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "omarchy-tailcat")
	out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput()
	if err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), env...)
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	if err != nil && stdout.Len() == 0 {
		return "", err
	}
	return stdout.String(), err
}

func TestDevicesJSON(t *testing.T) {
	dir := t.TempDir()
	env := []string{"OMARCHY_TAILCAT_CONFIG_DIR=" + dir}
	tok := "tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

	out, err := runBackend(t, env, "devices", "add", "ThinkPad X12", tok)
	if err != nil {
		t.Fatalf("add: %v\n%s", err, out)
	}
	var d map[string]any
	if err := json.Unmarshal([]byte(out), &d); err != nil {
		t.Fatalf("add output not JSON: %v\n%s", err, out)
	}
	if d["id"] == "" || d["name"] != "ThinkPad X12" {
		t.Fatalf("add: %+v", d)
	}

	out, err = runBackend(t, env, "devices", "list")
	if err != nil {
		t.Fatal(err)
	}
	var list []map[string]any
	if err := json.Unmarshal([]byte(out), &list); err != nil || len(list) != 1 {
		t.Fatalf("list: %s", out)
	}

	// Error path: JSON error object on stdout.
	out, err = runBackend(t, env, "devices", "add", "Dup", tok)
	if err == nil {
		t.Fatalf("duplicate add should fail")
	}
	var e map[string]any
	if err := json.Unmarshal([]byte(out), &e); err != nil {
		t.Fatalf("error not JSON: %v\n%s", err, out)
	}
	if e["error"] == nil {
		t.Fatalf("expected error object, got %s", out)
	}

	out, err = runBackend(t, env, "devices", "remove", d["id"].(string))
	if err != nil {
		t.Fatalf("remove: %v\n%s", err, out)
	}
}

func TestValidateCommandShape(t *testing.T) {
	dir := t.TempDir()
	env := []string{"OMARCHY_TAILCAT_CONFIG_DIR=" + dir}
	out, err := runBackend(t, env, "validate", "not-a-token")
	if err == nil {
		t.Fatalf("validate garbage should fail")
	}
	var e map[string]any
	if err := json.Unmarshal([]byte(out), &e); err != nil {
		t.Fatalf("error not JSON: %v\n%s", err, out)
	}
	if e["error"] == nil {
		t.Fatalf("expected error object, got %s", out)
	}
}

func TestUnknownSubcommand(t *testing.T) {
	dir := t.TempDir()
	out, _ := runBackend(t, []string{"OMARCHY_TAILCAT_CONFIG_DIR=" + dir}, "frobnicate")
	var e map[string]any
	if err := json.Unmarshal([]byte(out), &e); err != nil || e["error"] == nil {
		t.Fatalf("expected error object, got %s", out)
	}
}
