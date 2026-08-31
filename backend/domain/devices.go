// Package domain is the manager's Tailcat-free domain layer: saved devices
// (a manager-local registry independent of Tailcat itself) and future
// transfers/diagnostics. It must not import the tailcat package.
package domain

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"omarchy-tailcat/validate"
)

// DeviceKind is the target kind of a saved device.
type DeviceKind string

const (
	DeviceToken DeviceKind = "token"
	DeviceDNS   DeviceKind = "dns"
)

// Device is a saved connection target (manager-local, not part of Tailcat).
type Device struct {
	ID              string     `json:"id"`
	Name            string     `json:"name"`
	Target          string     `json:"target"` // token or DNS name
	Kind            DeviceKind `json:"kind"`
	CreatedAt       time.Time  `json:"createdAt"`
	LastConnectedAt time.Time  `json:"lastConnectedAt,omitempty"`
	Notes           string     `json:"notes,omitempty"`
}

// DeviceStore is the persistence interface the registry needs. Implemented by
// the config package.
type DeviceStore interface {
	Devices() []Device
	SetDevices([]Device) error
}

// Registry is a device CRUD over a DeviceStore, with validation and
// deduplication.
type Registry struct {
	store DeviceStore
}

// NewRegistry returns a registry backed by store.
func NewRegistry(store DeviceStore) *Registry { return &Registry{store: store} }

// List returns all saved devices, most-recently-created first.
func (r *Registry) List() ([]Device, error) {
	devs := r.store.Devices()
	out := make([]Device, len(devs))
	copy(out, devs)
	// stable, newest first
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].CreatedAt.After(out[j-1].CreatedAt); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out, nil
}

// Get returns a device by ID.
func (r *Registry) Get(id string) (Device, error) {
	for _, d := range r.store.Devices() {
		if d.ID == id {
			return d, nil
		}
	}
	return Device{}, ErrDeviceNotFound(id)
}

// Add validates and adds a device, deduplicating by target (case-insensitive
// for tokens, which are base64url; DNS names are case-insensitive by nature).
func (r *Registry) Add(name, target string) (Device, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return Device{}, errors.New("device name is required")
	}
	kind, ok := validate.IsValidTarget(strings.TrimSpace(target))
	if !ok {
		return Device{}, errors.New("target must be a tc... token or a DNS name")
	}
	target = strings.TrimSpace(target)
	// Dedup: DNS names are case-insensitive; tokens are case-sensitive (they
	// are base64url and case matters).
	for _, d := range r.store.Devices() {
		if d.Kind == DeviceDNS {
			if strings.EqualFold(d.Target, target) {
				return Device{}, ErrDeviceExists(target)
			}
		} else if d.Target == target {
			return Device{}, ErrDeviceExists(target)
		}
	}
	d := Device{
		ID:        newID(),
		Name:      name,
		Target:    target,
		Kind:      DeviceKind(kind),
		CreatedAt: time.Now().UTC(),
	}
	devs := append(r.store.Devices(), d)
	if err := r.store.SetDevices(devs); err != nil {
		return Device{}, err
	}
	return d, nil
}

// Remove deletes a device by ID.
func (r *Registry) Remove(id string) error {
	devs := r.store.Devices()
	for i, d := range devs {
		if d.ID == id {
			devs = append(devs[:i], devs[i+1:]...)
			return r.store.SetDevices(devs)
		}
	}
	return ErrDeviceNotFound(id)
}

// Rename updates a device name.
func (r *Registry) Rename(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("device name is required")
	}
	devs := r.store.Devices()
	for i := range devs {
		if devs[i].ID == id {
			devs[i].Name = name
			return r.store.SetDevices(devs)
		}
	}
	return ErrDeviceNotFound(id)
}

// MarkConnected stamps LastConnectedAt on a device.
func (r *Registry) MarkConnected(id string) error {
	devs := r.store.Devices()
	for i := range devs {
		if devs[i].ID == id {
			devs[i].LastConnectedAt = time.Now().UTC()
			return r.store.SetDevices(devs)
		}
	}
	return ErrDeviceNotFound(id)
}

func newID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return strings.ReplaceAll(time.Now().UTC().Format("20060102150405.000000000"), ".", "")
	}
	return hex.EncodeToString(b[:])
}

// ErrDeviceExists reports a duplicate target.
func ErrDeviceExists(target string) error {
	return errors.New("a device with target " + redactTarget(target) + " is already saved")
}

// ErrDeviceNotFound reports a missing device ID.
func ErrDeviceNotFound(id string) error {
	return errors.New("no saved device with id " + id)
}

// redactTarget shortens a token for error text.
func redactTarget(t string) string {
	if len(t) > 12 && strings.HasPrefix(t, "tc") {
		return "tc…" + t[len(t)-4:]
	}
	return t
}
