// Package atomicfile provides secure same-directory atomic writes used for all
// manager state (config, listener state). Never overwrites a valid file with
// partial data; on crash, the old file remains.
package atomicfile

import (
	"errors"
	"os"
	"path/filepath"
)

// Write writes data to path atomically: write to a temp file in the same
// directory, fsync it, rename over path, then fsync the directory. The file
// gets perm (e.g. 0600 for sensitive state).
func Write(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op after successful rename

	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	// fsync the directory so the rename is durable.
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// ErrNotFound is returned by Read when the file does not exist.
var ErrNotFound = errors.New("file not found")

// Read returns the file contents, or ErrNotFound if it does not exist.
func Read(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return b, nil
}

// Remove deletes path, ignoring a missing file.
func Remove(path string) error {
	err := os.Remove(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
