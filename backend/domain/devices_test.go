package domain

import (
	"strings"
	"testing"
	"time"
)

// memStore is an in-memory DeviceStore for tests.
type memStore struct{ devs []Device }

func (m *memStore) Devices() []Device           { return m.devs }
func (m *memStore) SetDevices(d []Device) error { m.devs = d; return nil }

func newTestRegistry() (*Registry, *memStore) {
	ms := &memStore{}
	return NewRegistry(ms), ms
}

const goodTok = "tcGOODAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

func TestAddAndList(t *testing.T) {
	r, _ := newTestRegistry()
	d, err := r.Add("ThinkPad X12", goodTok)
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if d.ID == "" || d.Name != "ThinkPad X12" || d.Kind != DeviceToken || d.CreatedAt.IsZero() {
		t.Fatalf("bad device: %+v", d)
	}
	devs, _ := r.List()
	if len(devs) != 1 || devs[0].Target != goodTok {
		t.Fatalf("list: %+v", devs)
	}
}

func TestAddDNS(t *testing.T) {
	r, _ := newTestRegistry()
	d, err := r.Add("Home Server", "home.example.com")
	if err != nil || d.Kind != DeviceDNS {
		t.Fatalf("dns device: %+v err=%v", d, err)
	}
}

func TestAddRejectsInvalid(t *testing.T) {
	r, _ := newTestRegistry()
	for _, target := range []string{"", "rm -rf /", "http://x", "tc", "tc!!", "../x"} {
		if _, err := r.Add("X", target); err == nil {
			t.Errorf("Add with %q should fail", target)
		}
	}
	if _, err := r.Add("  ", goodTok); err == nil {
		t.Errorf("Add with blank name should fail")
	}
}

func TestAddDuplicateTarget(t *testing.T) {
	r, _ := newTestRegistry()
	if _, err := r.Add("A", goodTok); err != nil {
		t.Fatal(err)
	}
	// Exact token duplicate rejected.
	if _, err := r.Add("B", goodTok); err == nil || !strings.Contains(err.Error(), "already saved") {
		t.Fatalf("expected duplicate error, got %v", err)
	}
	// DNS case-insensitive duplicate rejected.
	if _, err := r.Add("C", "home.example.com"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Add("D", "HOME.Example.COM"); err == nil || !strings.Contains(err.Error(), "already saved") {
		t.Fatalf("expected DNS case-insensitive duplicate error, got %v", err)
	}
	// A genuinely different token is accepted (no false duplicate).
	d, err := r.Add("E", goodTok+"Y")
	if err != nil || d.Target == goodTok {
		t.Fatalf("distinct token should be accepted: %v %+v", err, d)
	}
}

func TestRemoveAndRename(t *testing.T) {
	r, _ := newTestRegistry()
	d, _ := r.Add("A", goodTok)
	if err := r.Rename(d.ID, "B"); err != nil {
		t.Fatal(err)
	}
	if err := r.MarkConnected(d.ID); err != nil {
		t.Fatal(err)
	}
	if err := r.Remove(d.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get(d.ID); err == nil {
		t.Fatalf("Get after Remove should fail")
	}
	if err := r.Remove("nope"); err == nil {
		t.Fatalf("Remove unknown id should fail")
	}
	if err := r.Rename("nope", "x"); err == nil {
		t.Fatalf("Rename unknown id should fail")
	}
}

func TestMarkConnectedSetsTime(t *testing.T) {
	r, _ := newTestRegistry()
	d, _ := r.Add("A", goodTok)
	before := time.Now().Add(-time.Minute)
	if err := r.MarkConnected(d.ID); err != nil {
		t.Fatal(err)
	}
	got, _ := r.Get(d.ID)
	if got.LastConnectedAt.Before(before) {
		t.Fatalf("LastConnectedAt not set: %+v", got)
	}
}

func TestListNewestFirst(t *testing.T) {
	r, ms := newTestRegistry()
	d1, _ := r.Add("old", goodTok+"X") // second token (different)
	// Backdate d1 then add a newer one.
	ms.devs[0].CreatedAt = time.Now().Add(-time.Hour)
	d2, _ := r.Add("new", goodTok+"Y")
	devs, _ := r.List()
	if len(devs) != 2 || devs[0].ID != d2.ID || devs[1].ID != d1.ID {
		t.Fatalf("expected newest-first, got %+v", devs)
	}
}
