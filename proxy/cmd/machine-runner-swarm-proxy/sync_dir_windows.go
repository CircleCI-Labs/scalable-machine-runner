//go:build windows

package main

// syncDir is a no-op on Windows: opening a directory for sync is not supported there.
func syncDir(dir string) error {
	return nil
}
