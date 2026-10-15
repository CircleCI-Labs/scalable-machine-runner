package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// The state of the latch, in a directory of a volume that stays with the proxy:
//
//	state.json     {"version":1,"latched":{"tasks.<service>":["10.0.1.5", ...]}}, replaced atomically on every change
//	.initialized   created before the first state.json: a directory that has it has been used by a proxy
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

type store struct{ dir string }

// openStore makes sure that dir can be written. An empty dir means no persistence (a nil store).
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
	return &store{dir: dir}, os.Remove(probe)
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
		if markErr == nil {
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

// save writes the latched IPs of every class: marker first, then the state in a temporary file that replaces the old one. On ANY failure
// it removes state.json (and keeps the marker): a state that is behind the latches in memory must not be the one that a restart reads, and
// with the marker and no state file the next start takes the fail-safe path (stateLost). If even the removal fails there is nothing more
// to do here, and the caller refuses the claims until a write works.
func (s *store) save(classes []*class) error {
	if s == nil {
		return nil
	}
	err := s.write(classes)
	if err != nil {
		os.Remove(filepath.Join(s.dir, stateFile+".tmp"))
		os.Remove(filepath.Join(s.dir, stateFile))
	}
	return err
}

func (s *store) write(classes []*class) error {
	d := stateDoc{Version: 1, Latched: map[string][]string{}}
	for _, c := range classes {
		ips := make([]string, 0, len(c.latched))
		for ip := range c.latched {
			ips = append(ips, ip)
		}
		sort.Strings(ips)
		d.Latched[c.dns] = ips
	}
	b, err := json.Marshal(d)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(s.dir, stateMarker), nil, 0o600); err != nil {
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
	return os.Rename(tmp, filepath.Join(s.dir, stateFile))
}
