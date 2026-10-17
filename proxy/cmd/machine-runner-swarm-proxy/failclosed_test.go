package main

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// closingUpstream is an upstream that accepts a connection, reads the request up to the end of its headers and closes the connection
// without an answer: the request reached it, and the answer is lost. It returns its URL and the number of requests it has read.
func closingUpstream(t *testing.T) (*url.URL, func() int) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	n := 0
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				br := bufio.NewReader(conn)
				for {
					line, err := br.ReadString('\n')
					if err != nil {
						return
					}
					if line == "\r\n" {
						break
					}
				}
				mu.Lock()
				n++
				mu.Unlock()
			}()
		}
	}()
	t.Cleanup(func() { ln.Close() })
	u, _ := url.Parse("http://" + ln.Addr().String())
	return u, func() int { mu.Lock(); defer mu.Unlock(); return n }
}

func TestAClaimWhoseAnswerIsLostIsLatched(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
	var reached func() int
	e.p.upstream, reached = closingUpstream(t)
	e.check(e.claim(runnerA1), 502, "the upstream got the claim and closed the connection")
	if reached() != 1 {
		t.Fatalf("the upstream read %d claims, want 1: the test does not test a lost answer", reached())
	}
	if !e.p.classes[0].latched[runnerA1] {
		t.Error("a claim whose outcome is unknown must latch the runner")
	}
	if !strings.Contains(readFile(t, filepath.Join(dir, stateFile)), runnerA1) {
		t.Error("the latch of a claim with an unknown outcome must be saved")
	}
	e.check(e.claim(runnerA1), 403, "the runner claims again")
	if reached() != 1 {
		t.Error("the second claim reached the upstream")
	}
	if !strings.Contains(e.logs.String(), "outcome unknown") {
		t.Errorf("the latch is not in the log:\n%s", e.logs.String())
	}
	e.running[tokenA] = 1 // a restart cannot tell: the saved state keeps it refused
	if what := e.restart(); !strings.Contains(what, "state restored") {
		t.Errorf("got: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "the runner stays refused after a restart")
	e.dns[dnsA] = []string{runnerA2}
	e.polls(3)
	e.dns[dnsA] = []string{runnerA1, runnerA2}
	e.upstream200()
	e.check(e.claim(runnerA1), 200, "a new container on the same address, once the old one is gone")
}

// upstream200 points the proxy at an upstream that answers every request with 200.
func (e *env) upstream200() {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	e.t.Cleanup(up.Close)
	e.p.upstream, _ = url.Parse(up.URL)
}

func TestAClaimThatGetsNoAnswerHeadersInTimeIsLatched(t *testing.T) {
	e := newEnv(t, runnerA1)
	release := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	defer up.Close()
	defer close(release)
	e.p.upstream, _ = url.Parse(up.URL)
	tr := upstreamTransport.Clone()
	tr.ResponseHeaderTimeout = 100 * time.Millisecond
	e.p.transport = tr
	e.check(e.claim(runnerA1), 502, "an upstream that does not answer")
	if !e.p.classes[0].latched[runnerA1] {
		t.Error("a claim that timed out after it was sent must latch the runner")
	}
	e.check(e.claim(runnerA1), 403, "the runner claims again")
}

func TestTheUpstreamTransportWaitsSixtySecondsForHeaders(t *testing.T) {
	if got := upstreamTransport.ResponseHeaderTimeout; got != 60*time.Second {
		t.Errorf("response header timeout %v, want 60s", got)
	}
}

func TestAClaimThatNeverReachedTheUpstreamIsNotLatched(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.p.upstream, _ = url.Parse("http://127.0.0.1:1") // nothing listens: the connection fails
	e.check(e.claim(runnerA1), 502, "no connection")
	if e.p.classes[0].latched[runnerA1] {
		t.Error("a claim that was never sent must not latch the runner")
	}
	e.upstream200()
	e.check(e.claim(runnerA1), 200, "the runner may claim when the upstream is back")
}

func TestAClaimWhoseBodyFailsIsNotLatched(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.upstream200()
	r := httptest.NewRequest("POST", claimPath, io.NopCloser(io.MultiReader(strings.NewReader(`{"agent":`), errReader{})))
	r.ContentLength = -1
	r.RemoteAddr = runnerA1 + ":1"
	w := httptest.NewRecorder()
	e.p.ServeHTTP(w, r)
	if w.Code == 200 || e.p.classes[0].latched[runnerA1] {
		t.Errorf("a claim that was cut: status %d, latched %v: the upstream cannot have answered a task", w.Code, e.p.classes[0].latched[runnerA1])
	}
}

type errReader struct{}

func (errReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

func TestAFailedPassThroughCallLatchesNobody(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.p.upstream, _ = closingUpstream(t)
	e.check(e.do(runnerA1, "GET", "/api/v2/task/config", taskToken), 502, "an upstream that closes")
	if e.p.classes[0].latched[runnerA1] {
		t.Error("only a claim latches")
	}
}
