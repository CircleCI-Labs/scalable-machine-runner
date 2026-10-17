//go:build !windows

package main

import "os"

// syncDir makes a directory entry durable after a rename into it. On Unix the directory must be opened and synced.
func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = f.Sync()
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
