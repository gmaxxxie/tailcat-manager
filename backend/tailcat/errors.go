package tailcat

import "fmt"

// ErrorKind classifies backend failures so the UI can present a friendly,
// actionable message instead of a raw exit code.
type ErrorKind string

const (
	ErrNotInstalled    ErrorKind = "not_installed"
	ErrInvalidToken    ErrorKind = "invalid_token"
	ErrInvalidInput    ErrorKind = "invalid_input"
	ErrConnectTimeout  ErrorKind = "connect_timeout"
	ErrNoDirectPath    ErrorKind = "no_direct_path"
	ErrPingFailed      ErrorKind = "ping_failed"
	ErrListenerFailed  ErrorKind = "listener_failed"
	ErrListenerRunning ErrorKind = "listener_running"
	ErrKeyExists       ErrorKind = "key_exists"
	ErrKeyNotFound     ErrorKind = "key_not_found"
	ErrCommandFailed   ErrorKind = "command_failed"
	ErrDeviceExists    ErrorKind = "device_exists"
	ErrDeviceNotFound  ErrorKind = "device_not_found"
)

// Error is the backend's typed error. Message is user-friendly; Detail is raw,
// redacted diagnostic text shown only behind a "Details" disclosure.
type Error struct {
	Kind    ErrorKind `json:"kind"`
	Message string    `json:"message"`
	Detail  string    `json:"detail,omitempty"`
}

func (e *Error) Error() string { return e.Message }

func (e *Error) Unwrap() error { return nil }

// Errf builds a typed Error.
func Errf(kind ErrorKind, format string, args ...any) *Error {
	return &Error{Kind: kind, Message: fmt.Sprintf(format, args...)}
}

// AsError extracts a *Error from err, or wraps a generic failure.
func AsError(err error) *Error {
	if err == nil {
		return nil
	}
	var e *Error
	if ok := asErr(err, &e); ok && e != nil {
		return e
	}
	return &Error{Kind: ErrCommandFailed, Message: err.Error()}
}

func asErr(err error, target **Error) bool {
	type causer interface{ Unwrap() error }
	for err != nil {
		if e, ok := err.(*Error); ok {
			*target = e
			return true
		}
		c, ok := err.(causer)
		if !ok {
			break
		}
		err = c.Unwrap()
	}
	return false
}
