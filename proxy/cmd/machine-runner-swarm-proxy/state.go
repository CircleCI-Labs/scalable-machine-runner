package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync/atomic"
)

// The state of the latch, in a directory of a volume that stays with the proxy:
//
//	state.json     {"version":1,"latched":{"tasks.<service>":["10.0.1.5", ...]}}, replaced atomically on every change
//	.initialized   created, and synced, once, when the directory is opened and before any state.json: a directory that has it has been used by a proxy
//
// A directory with neither file was never used (a first start). One with the marker but no readable state.json lost it.
const (
	stateFile   = "state.json"
	stateMarker = ".initialized"
)

type startKind int

const (
	stateNoStore startKind = iota // no -state-dir
	stateNone                     // an unused directory: a first start
	stateOK                       // a usable state.json
	stateLost                     // the marker, but no usable state.json
)

type store struct {
	dir string
	// fresh: the directory held neither the marker nor a state file when it was opened. openStore creates the marker, so this is what
	// tells a first start from a lost state, until the first state file is saved.
	fresh atomic.Bool

	beforeWrite func() // for tests: called at the start of every write, where the files are synced
}

// openStore makes sure that dir can be written and creates the marker, once, if it is not there. An empty dir means no persistence
// (a nil store).
func openStore(dir string) (*store, error) {
	if dir == "" {
		return nil, nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	probe := filepath.Join(dir, ".write-test")
	if err := os.WriteFile(probe, nil, 0o600); err != nil {
		return nil, fmt.Errorf("state directory is not writable: %w", err)
	}
	if err := os.Remove(probe); err != nil {
		return nil, err
	}
	s := &store{dir: dir}
	marker := filepath.Join(dir, stateMarker)
	_, markErr := os.Stat(marker)
	_, stateErr := os.Stat(filepath.Join(dir, stateFile))
	switch {
	case markErr == nil:
		return s, nil
	case !errors.Is(markErr, os.ErrNotExist):
		return nil, markErr
	case stateErr != nil && !errors.Is(stateErr, os.ErrNotExist):
		return nil, stateErr
	}
	s.fresh.Store(errors.Is(stateErr, os.ErrNotExist))
	f, err := os.OpenFile(marker, os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("state directory: cannot create the marker: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, fmt.Errorf("state directory: cannot sync the marker: %w", err)
	}
	if err := f.Close(); err != nil {
		return nil, err
	}
	if err := syncDir(dir); err != nil {
		return nil, fmt.Errorf("state directory: cannot sync it: %w", err)
	}
	return s, nil
}

type stateDoc struct {
	Version int                 `json:"version"`
	Latched map[string][]string `json:"latched"`
}

// load classifies the directory and returns the saved IPs of each class DNS name when the state is usable.
func (s *store) load() (startKind, map[string][]string, error) {
	if s == nil {
		return stateNoStore, nil, nil
	}
	_, markErr := os.Stat(filepath.Join(s.dir, stateMarker))
	if markErr != nil && !errors.Is(markErr, os.ErrNotExist) {
		return 0, nil, markErr
	}
	b, err := os.ReadFile(filepath.Join(s.dir, stateFile))
	switch {
	case errors.Is(err, os.ErrNotExist):
		if markErr == nil && !s.fresh.Load() {
			return stateLost, nil, nil
		}
		return stateNone, nil, nil
	case err != nil:
		return stateLost, nil, nil
	}
	var d stateDoc
	if json.Unmarshal(b, &d) != nil || d.Version != 1 || d.Latched == nil {
		return stateLost, nil, nil
	}
	return stateOK, d.Latched, nil
}

// snapshotLatched copies the latched IPs of every class, sorted, for save. The caller holds the lock that guards the latches; save
// itself needs no lock, so the lock is not held while the files are synced.
func snapshotLatched(classes []*class) map[string][]string {
	snap := map[string][]string{}
	for _, c := range classes {
		ips := make([]string, 0, len(c.latched))
		for ip := range c.latched {
			ips = append(ips, ip)
		}
		sort.Strings(ips)
		snap[c.dns] = ips
	}
	return snap
}

// save writes a snapshot of the latched IPs of every class in a temporary file that replaces the old state.json. On ANY failure it
// removes state.json (and keeps the marker): a state that is behind the latches in memory must not be the one that a restart reads, and
// with the marker and no state file the next start takes the fail-safe path (stateLost). If even the removal fails there is nothing more
// to do here, and the caller refuses the claims until a write works. Calls must not overlap, and each must take its snapshot after the
// call before it has finished (proxy.persist does that), so that an older snapshot never replaces a newer one.
func (s *store) save(latched map[string][]string) error {
	if s == nil {
		return nil
	}
	err := s.write(latched)
	s.fresh.Store(false) // the directory is in use now, saved or not
	if err != nil {
		os.Remove(filepath.Join(s.dir, stateFile+".tmp"))
		os.Remove(filepath.Join(s.dir, stateFile))
	}
	return err
}

func (s *store) write(latched map[string][]string) error {
	if s.beforeWrite != nil {
		s.beforeWrite()
	}
	b, err := json.Marshal(stateDoc{Version: 1, Latched: latched})
	if err != nil {
		return err
	}
	tmp := filepath.Join(s.dir, stateFile+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, stateFile)); err != nil {
		return err
	}
	return syncDir(s.dir)
}
