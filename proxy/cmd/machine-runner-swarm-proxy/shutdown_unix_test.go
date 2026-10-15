//go:build !windows

package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// A SIGTERM while CircleCI is still answering a claim: serve returns only after that claim has been handled, so the runner gets the task
// that is latched and saved, and the process does not exit before.
func TestShutdownWaitsForAClaimThatIsInFlight(t *testing.T) {
	e := newEnv(t, "127.0.0.1")
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
	inFlight := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(inFlight)
		time.Sleep(500 * time.Millisecond) // a slow upstream
		w.WriteHeader(200)
	}))
	defer up.Close()
	e.p.upstream, _ = url.Parse(up.URL)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
	defer stop()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var handled atomic.Bool
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.p.ServeHTTP(w, r)
		handled.Store(true)
	})}
	served := make(chan error, 1)
	go func() { served <- serve(ctx, srv, ln, 10*time.Second) }()

	answer := make(chan int, 1)
	go func() {
		resp, err := http.Post("http://"+ln.Addr().String()+claimPath, "application/json", strings.NewReader("{}"))
		if err != nil {
			answer <- -1
			return
		}
		resp.Body.Close()
		answer <- resp.StatusCode
	}()
	<-inFlight
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-served:
		if err != nil {
			t.Errorf("serve: %v", err)
		}
		if !handled.Load() {
			t.Error("serve returned, and main with it, while a claim was still in flight")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("serve did not return after SIGTERM")
	}
	if code := <-answer; code != 200 {
		t.Errorf("the claim in flight got %d, want its answer", code)
	}
	if st, _ := os.ReadFile(filepath.Join(dir, stateFile)); !strings.Contains(string(st), "127.0.0.1") {
		t.Errorf("the claim that was answered is not in the state: %s", st)
	}
}

// A claim that does not end within the grace is cut: the process must not hang on a stuck upstream.
func TestShutdownGivesUpAfterTheGrace(t *testing.T) {
	e := newEnv(t, "127.0.0.1")
	stuck := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-stuck }))
	defer up.Close()
	defer close(stuck)
	e.p.upstream, _ = url.Parse(up.URL)
	ctx, cancel := context.WithCancel(context.Background())
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	served := make(chan error, 1)
	go func() { served <- serve(ctx, &http.Server{Handler: e.p}, ln, 200*time.Millisecond) }()
	go http.Post("http://"+ln.Addr().String()+claimPath, "application/json", strings.NewReader("{}"))
	time.Sleep(200 * time.Millisecond)
	cancel()
	select {
	case <-served:
	case <-time.After(5 * time.Second):
		t.Fatal("serve hangs on a stuck claim")
	}
}
