package main

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// breakSaves makes every write of the state fail from now on, and says how to mend it: a directory in the place of the temporary file
// (with a file in it, so that the cleanup of a failed save cannot remove it).
func breakSaves(t *testing.T, dir string) (mend func()) {
	t.Helper()
	tmp := filepath.Join(dir, stateFile+".tmp")
	if err := os.MkdirAll(tmp, 0o700); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(tmp, "x"), nil, 0o600)
	return func() { os.RemoveAll(tmp) }
}

func exists(path string) bool { _, err := os.Stat(path); return err == nil }

func TestAFailedSaveFailsTheClaimAndTheNextStartFailsSafe(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
	e.check(e.claim(runnerA1), 200, "a claim, saved")
	if !strings.Contains(readFile(t, filepath.Join(dir, stateFile)), runnerA1) {
		t.Fatal("the state does not hold the first claim")
	}
	mend := breakSaves(t, dir)
	before := e.calls.Load()
	e.check(e.claim(runnerA2), 503, "a claim whose latch cannot be saved gets no task")
	if e.calls.Load() != before+1 {
		t.Fatal("the claim did not reach the upstream: the test does not test the save")
	}
	if exists(filepath.Join(dir, stateFile)) || !exists(filepath.Join(dir, stateMarker)) {
		t.Error("a failed save must remove state.json and keep the marker, so that the next start fails safe")
	}
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 503, "unhealthy")
	e.check(e.claim(runnerA2), 403, "the runner whose claim failed stays latched in memory")
	// no further task is handed out while the state cannot be written, and the upstream is not asked
	before = e.calls.Load()
	e.check(e.claim(runnerB1), 503, "no claim while the state cannot be written")
	if e.calls.Load() != before {
		t.Error("a claim reached the upstream while the state could not be written")
	}
	// the proxy restarts now: no state and a marker, which is the fail-safe path: CircleCI says that a task runs, so every runner present is refused
	if kind, _, _ := e.p.store.load(); kind != stateLost {
		t.Errorf("a restart reads start kind %d, want a lost state", kind)
	}
	mend()
	e.running[tokenA] = 1
	if what := e.restart(); !strings.Contains(what, "state lost") {
		t.Errorf("want a lost state, got: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "the runner that claimed before the failure")
	e.check(e.claim(runnerA2), 403, "the runner whose claim was lost")
	e.check(e.claim(runnerB1), 200, "class b has no task running")
}

func TestTheStateIsWrittenAgainWhenTheDiskWorksAgain(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
	e.check(e.claim(runnerA1), 200, "claim")
	mend := breakSaves(t, dir)
	e.check(e.claim(runnerA2), 503, "claim that cannot be saved")
	mend()
	e.polls(1) // the poll tries again
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 200, "healthy again")
	st := readFile(t, filepath.Join(dir, stateFile))
	if !strings.Contains(st, runnerA1) || !strings.Contains(st, runnerA2) {
		t.Errorf("the state written after the failure lacks a latch: %s", st)
	}
	if what := e.restart(); !strings.Contains(what, "state restored") || !strings.Contains(what, "tasks.class-a: 2 runner(s) have claimed") {
		t.Errorf("got: %s", what)
	}
}

func TestAFailedSaveWhileReleasingRemovesTheState(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
	e.check(e.claim(runnerA1), 200, "claim")
	breakSaves(t, dir)
	e.dns[dnsA] = []string{runnerA2}
	e.polls(3) // the release has to be saved, and cannot
	if exists(filepath.Join(dir, stateFile)) {
		t.Error("a failed save while releasing left a state that is behind the latches")
	}
	if e.p.stateErr == nil {
		t.Error("the proxy does not know that its state is not written")
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestARestartLatchesEverySavedAddressWhateverDNSSays(t *testing.T) {
	for name, dnsAtStart := range map[string][]string{
		"no answer (the name is not known yet)": nil,
		"a partial answer":                      {runnerA2},
		"another address":                       {"10.0.1.99"},
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, runnerA1, runnerA2)
			dir := t.TempDir()
			e.withState(dir)
			e.restart()
			e.check(e.claim(runnerA1), 200, "claim")
			e.check(e.claim(runnerA2), 200, "claim")
			e.dns[dnsA] = dnsAtStart
			if what := e.restart(); !strings.Contains(what, "tasks.class-a: 2 runner(s) have claimed") {
				t.Errorf("both saved runners must be restored, got: %s", what)
			}
			if st := readFile(t, filepath.Join(dir, stateFile)); !strings.Contains(st, runnerA1) || !strings.Contains(st, runnerA2) {
				t.Errorf("the state that the restart wrote lost a latch: %s", st)
			}
			e.dns[dnsA] = []string{runnerA1, runnerA2} // DNS catches up
			e.check(e.claim(runnerA1), 403, "the runner that claimed, once DNS lists it")
			e.check(e.claim(runnerA2), 403, "the runner that claimed, once DNS lists it")
		})
	}
}

func TestALatchIsReleasedOnlyAfterSeveralPollsInARow(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.check(e.claim(runnerA1), 200, "claim")
	e.dns[dnsA] = []string{runnerA2}
	e.polls(2)
	e.dns[dnsA] = []string{runnerA1, runnerA2} // listed again: the count starts again
	e.polls(1)
	e.dns[dnsA] = []string{runnerA2}
	e.polls(2)
	e.dns[dnsA] = []string{runnerA1, runnerA2}
	e.check(e.claim(runnerA1), 403, "two polls without the address, twice, with one listing between")
	e.dns[dnsA] = []string{runnerA2}
	e.polls(1) // the third poll in a row
	e.dns[dnsA] = []string{runnerA1, runnerA2}
	e.check(e.claim(runnerA1), 200, "released after three polls in a row")
}

func TestAClassThatDNSDoesNotKnowIsOneMissingPoll(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.check(e.claim(runnerA1), 200, "claim")
	e.check(e.claim(runnerA2), 200, "claim")
	e.dns[dnsA] = nil // NXDOMAIN for the whole class
	e.polls(1)
	e.dns[dnsA] = []string{runnerA1, runnerA2} // the answer is back
	e.check(e.claim(runnerA1), 403, "NXDOMAIN once does not release")
	e.check(e.claim(runnerA2), 403, "NXDOMAIN once does not release")
}

func TestOnlyPollsCountAndOnlyAnswersCount(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.check(e.claim(runnerA1), 200, "claim")
	e.dns[dnsA] = []string{runnerA2}
	for range 10 { // claims look at DNS too, and do not count
		e.claim(runnerA1)
		e.claim("10.9.9.9")
	}
	e.polls(2)
	e.dnsErr = os.ErrDeadlineExceeded // DNS fails: a poll that says nothing
	for range 10 {
		if e.p.poll(context.Background()) == nil {
			t.Fatal("a failed lookup must be an error")
		}
	}
	e.dnsErr = nil
	e.dns[dnsA] = []string{runnerA1, runnerA2}
	e.check(e.claim(runnerA1), 403, "two missing polls, then failures that count for nothing")
}

func TestARefusalSaysNothingAboutTheClasses(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.check(e.claim(runnerA1), 200, "claim")
	for name, from := range map[string]string{"latched": runnerA1, "not a runner": "10.9.9.9"} {
		r := httptest.NewRequest("POST", claimPath, nil)
		r.RemoteAddr = from + ":1"
		w := httptest.NewRecorder()
		e.p.ServeHTTP(w, r)
		if w.Code != 403 || w.Body.String() != "claim refused\n" {
			t.Errorf("%s: %d %q, want 403 and a generic body", name, w.Code, w.Body.String())
		}
	}
	if !strings.Contains(e.logs.String(), "not a runner of any class (tasks.class-a lists [10.0.1.5]") {
		t.Errorf("the detail is not in the log:\n%s", e.logs.String())
	}
}
