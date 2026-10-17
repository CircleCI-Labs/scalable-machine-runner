package main

import (
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestStoreWritePersistsState(t *testing.T) {
	dir := t.TempDir()
	st, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	c := newClass("class-a", filepath.Join(dir, "token"))
	c.latched["10.0.0.1"] = true
	if err := st.write(snapshotLatched([]*class{c})); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, stateMarker)); err != nil {
		t.Fatalf("marker: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(dir, stateFile))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "10.0.0.1") {
		t.Fatalf("state does not hold the latch: %s", b)
	}
}

func TestTheMarkerIsWrittenOnceWhenTheDirectoryIsOpened(t *testing.T) {
	dir := t.TempDir()
	st, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(dir, stateMarker)
	if !exists(marker) {
		t.Fatal("no marker after openStore")
	}
	if kind, _, _ := st.load(); kind != stateNone {
		t.Errorf("a directory that is new is start kind %d, want a first start", kind)
	}
	c := newClass("class-a", filepath.Join(dir, "token"))
	c.latched["10.0.0.1"] = true
	os.Remove(marker) // a save must not write it again
	for range 3 {
		if err := st.save(snapshotLatched([]*class{c})); err != nil {
			t.Fatal(err)
		}
	}
	if exists(marker) {
		t.Error("a save wrote the marker")
	}
	if kind, _, _ := st.load(); kind != stateOK {
		t.Errorf("after a save: start kind %d, want a usable state", kind)
	}
	// a directory opened again keeps its marker, and loses its first-start status
	os.WriteFile(marker, nil, 0o600)
	again, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if kind, _, _ := again.load(); kind != stateOK {
		t.Errorf("a directory with a state: start kind %d, want a usable state", kind)
	}
	os.Remove(filepath.Join(dir, stateFile))
	lost, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if kind, _, _ := lost.load(); kind != stateLost {
		t.Errorf("a directory with a marker and no state: start kind %d, want a lost state", kind)
	}
}

func TestTheHealthCheckAndTheClaimsDoNotWaitForTheStateToBeWritten(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.withState(t.TempDir())
	e.restart()
	var held, healthy bool
	e.p.store.beforeWrite = func() {
		if e.p.mu.TryLock() { // the lock of the claims is free while the files are written
			e.p.mu.Unlock()
		} else {
			held = true
		}
		rec := httptest.NewRecorder()
		e.p.health(rec) // and the health check does not wait for any lock
		healthy = rec.Code == 200
	}
	e.check(e.claim(runnerA1), 200, "claim")
	if held {
		t.Error("the global lock was held while the state was written")
	}
	if !healthy {
		t.Error("the health check did not answer while the state was written")
	}
	e.p.mu.Lock() // the health check takes no lock
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 200, "health")
	e.p.mu.Unlock()
}

func TestConcurrentClaimsAreAllSaved(t *testing.T) {
	var ips []string
	for i := range 40 {
		ips = append(ips, fmt.Sprintf("10.0.1.%d", 10+i))
	}
	e := newEnv(t, ips...)
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
	var wg sync.WaitGroup
	for _, ip := range ips {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if code := e.claim(ip); code != 200 {
				t.Errorf("claim of %s: %d", ip, code)
			}
		}()
	}
	wg.Wait()
	st := readFile(t, filepath.Join(dir, stateFile))
	for _, ip := range ips {
		if !strings.Contains(st, `"`+ip+`"`) {
			t.Errorf("%s is not in the state: %s", ip, st)
		}
	}
	if what := e.restart(); !strings.Contains(what, "tasks.class-a: 40 runner(s) have claimed") {
		t.Errorf("got: %s", what)
	}
}
