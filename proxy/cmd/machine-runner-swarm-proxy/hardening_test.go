package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// countLookups wraps the DNS lookup of the proxy of e and returns the number of lookups so far.
func countLookups(e *env) func() int {
	var n atomic.Int32
	inner := e.p.lookup
	e.p.lookup = func(ctx context.Context, host string) ([]string, error) {
		n.Add(1)
		return inner(ctx, host)
	}
	return func() int { return int(n.Load()) }
}

func TestARunnerThatHasClaimedCostsNoDNSLookup(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.check(e.claim(runnerA1), 200, "claim")
	lookups := countLookups(e)
	for range 20 {
		e.check(e.claim(runnerA1), 403, "a claim from a latched runner")
	}
	if n := lookups(); n != 0 {
		t.Errorf("%d DNS lookups for claims from a latched runner, want none", n)
	}
}

func TestClaimsShareTheCachedMembership(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.p.cacheTTL = time.Hour
	lookups := countLookups(e)
	for range 20 {
		e.check(e.claim("10.9.9.9"), 403, "a claim from a container that is not a runner")
	}
	if n := lookups(); n != len(e.p.classes) {
		t.Errorf("%d DNS lookups for 20 claims, want one for each of the %d classes", n, len(e.p.classes))
	}
	e.check(e.claim(runnerA1), 200, "a runner is known from the same answer")
}

func TestAFailedLookupIsSharedByTheClaimsToo(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.p.cacheTTL = time.Hour
	e.dnsErr = errors.New("server misbehaving")
	lookups := countLookups(e)
	for range 20 {
		e.check(e.claim("10.9.9.9"), 503, "DNS fails")
	}
	if n := lookups(); n != len(e.p.classes) {
		t.Errorf("%d DNS lookups for 20 claims while DNS fails, want one for each of the %d classes", n, len(e.p.classes))
	}
}

func TestAClaimThatIsGivenUpDoesNotEndTheLookupForTheOthers(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.p.cacheTTL = time.Hour
	ctx, cancel := context.WithCancel(context.Background())
	e.p.lookup = func(lctx context.Context, host string) ([]string, error) {
		cancel() // the client that started the lookup goes away
		if err := lctx.Err(); err != nil {
			return nil, err
		}
		return []string{runnerA1}, nil
	}
	sets, err := e.p.membership(ctx)
	if err != nil || len(sets) != len(e.p.classes) {
		t.Errorf("a lookup that ends with its claim: %v, %v", sets, err)
	}
}

func TestClaimsFromOneAddressAreRateLimited(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	now := time.Now()
	e.p.limit = newLimiter(1, 3)
	e.p.limit.now = func() time.Time { return now }
	e.p.limitLog.every = time.Hour
	e.status = []int{204} // no task: nobody latches
	var codes []int
	for range 5 {
		codes = append(codes, e.claim(runnerA1))
	}
	if fmt.Sprint(codes) != "[204 204 204 429 429]" {
		t.Errorf("claims from one address: %v, want a burst of 3 and then 429", codes)
	}
	e.check(e.claim(runnerA2), 204, "another address has its own bucket")
	if e.calls.Load() != 4 {
		t.Errorf("%d claims reached the upstream, want 4", e.calls.Load())
	}
	now = now.Add(2 * time.Second)
	e.check(e.claim(runnerA1), 204, "after two seconds")
	e.check(e.claim(runnerA1), 204, "after two seconds")
	e.check(e.claim(runnerA1), 429, "after two seconds, two tokens")
	e.check(e.do(runnerA1, "GET", "/api/v2/task/config", taskToken), 204, "other calls are not limited")
	if n := strings.Count(e.logs.String(), "too many claims"); n != 1 {
		t.Errorf("%d log lines for the refusals of the rate limit, want one (and a count)", n)
	}
	now = now.Add(time.Hour)
	e.p.limit.gc()
	if len(e.p.limit.buckets) != 0 {
		t.Errorf("%d buckets after an hour, want none", len(e.p.limit.buckets))
	}
}

func TestAClaimThatIsTooLargeIsRefused(t *testing.T) {
	e := newEnv(t, runnerA1)
	big := strings.Repeat("x", maxClaimBody+1)
	r := httptest.NewRequest("POST", claimPath, strings.NewReader(big))
	r.RemoteAddr = runnerA1 + ":1"
	w := httptest.NewRecorder()
	e.p.ServeHTTP(w, r)
	if w.Code != http.StatusRequestEntityTooLarge || e.calls.Load() != 0 {
		t.Errorf("a claim of %d bytes: %d, upstream calls %d", len(big), w.Code, e.calls.Load())
	}
	// a body of unknown length is cut at the same size, and the claim fails
	var got atomic.Int64
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		got.Store(n)
		w.WriteHeader(200)
	}))
	defer up.Close()
	e.p.upstream, _ = url.Parse(up.URL)
	r = httptest.NewRequest("POST", claimPath, io.NopCloser(strings.NewReader(big)))
	r.ContentLength = -1
	r.RemoteAddr = runnerA1 + ":1"
	w = httptest.NewRecorder()
	e.p.ServeHTTP(w, r)
	if w.Code == 200 || e.p.classes[0].latched[runnerA1] {
		t.Errorf("a claim body of unknown length over the cap: %d, latched %v", w.Code, e.p.classes[0].latched[runnerA1])
	}
	r = httptest.NewRequest("POST", claimPath, strings.NewReader(`{"agent":{}}`))
	r.RemoteAddr = runnerA1 + ":1"
	w = httptest.NewRecorder()
	e.p.ServeHTTP(w, r)
	if w.Code != 200 || got.Load() != int64(len(`{"agent":{}}`)) {
		t.Errorf("a normal claim: %d, body of %d bytes at the upstream", w.Code, got.Load())
	}
}

func TestTheServerHasLimits(t *testing.T) {
	e := newEnv(t, runnerA1)
	srv := newServer(":0", e.p)
	if srv.ReadHeaderTimeout <= 0 || srv.ReadTimeout <= 0 || srv.IdleTimeout <= 0 || srv.MaxHeaderBytes <= 0 || srv.MaxHeaderBytes > 64<<10 {
		t.Errorf("limits: header %v, read %v, idle %v, max header bytes %d", srv.ReadHeaderTimeout, srv.ReadTimeout, srv.IdleTimeout, srv.MaxHeaderBytes)
	}
	ts := httptest.NewUnstartedServer(e.p)
	ts.Config.MaxHeaderBytes = srv.MaxHeaderBytes
	ts.Start()
	defer ts.Close()
	req, _ := http.NewRequest("GET", ts.URL+healthPath, nil)
	req.Header.Set("X-Big", strings.Repeat("x", 200<<10))
	resp, err := http.DefaultClient.Do(req)
	if err == nil {
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusRequestHeaderFieldsTooLarge {
			t.Errorf("a header of 200 KB: status %d", resp.StatusCode)
		}
	}
}

func TestStartRetriesDNSAndNotTheStore(t *testing.T) {
	t.Run("DNS comes up", func(t *testing.T) {
		e := newEnv(t, runnerA1)
		var n atomic.Int32
		inner := e.p.lookup
		e.p.lookup = func(ctx context.Context, host string) ([]string, error) {
			if n.Add(1) <= 4 { // the first two rounds of two classes
				return nil, errors.New("server misbehaving")
			}
			return inner(ctx, host)
		}
		what, err := e.p.start(context.Background(), time.Millisecond)
		if err != nil || !strings.Contains(what, "no state directory") {
			t.Fatalf("got %q, %v", what, err)
		}
		if !strings.Contains(e.logs.String(), "waiting for DNS") {
			t.Error("the wait for DNS is not in the log")
		}
	})
	t.Run("the wait ends with ctx", func(t *testing.T) {
		e := newEnv(t, runnerA1)
		e.dnsErr = errors.New("server misbehaving")
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error)
		go func() { _, err := e.p.start(ctx, time.Hour); done <- err }()
		time.Sleep(50 * time.Millisecond)
		cancel()
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				t.Errorf("got %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("the wait for DNS ignores ctx")
		}
	})
	for name, st := range map[string]*store{
		"the state cannot be read":    {dir: writeFile(t, "a file, not a directory") + "/sub"},
		"the state cannot be written": {dir: t.TempDir() + "/gone"},
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, runnerA1)
			e.p.store = st
			lookups := countLookups(e)
			_, err := e.p.start(context.Background(), time.Millisecond)
			var se *storeError
			if !errors.As(err, &se) {
				t.Fatalf("got %v, want a storeError, which ends the start", err)
			}
			if n := lookups(); n != len(e.p.classes) {
				t.Errorf("%d DNS lookups: the start was tried again after a store error", n)
			}
			if len(e.scaleCalls) != 0 && name == "the state cannot be read" {
				t.Error("CircleCI was asked although the state could not be read")
			}
		})
	}
}

func writeFile(t *testing.T, content string) string {
	t.Helper()
	f := t.TempDir() + "/file"
	if err := writeBytes(f, content); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestTheClassesAreProbedTogetherAndUnderOneDeadline(t *testing.T) {
	// both scale calls must be in flight at the same time to be answered: a serial probe would time out
	var arrived sync.WaitGroup
	arrived.Add(2)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		arrived.Done()
		ch := make(chan struct{})
		go func() { arrived.Wait(); close(ch) }()
		select {
		case <-ch:
			io.WriteString(w, `{"data":{"attributes":{"running_task_count":0,"unclaimed_task_count":0}}}`)
		case <-r.Context().Done():
		case <-time.After(3 * time.Second):
		}
	}))
	defer up.Close()
	e := newEnv(t, runnerA1)
	api := e.p.upstream
	e.p.upstream, _ = url.Parse(up.URL)
	what, err := e.p.restore(context.Background())
	if err != nil || strings.Contains(what, "failing safe") {
		t.Errorf("serial probes: %q, %v", what, err)
	}
	e.p.upstream = api
	e.check(e.claim(runnerA1), 200, "answered at the same time: may claim")
}

func TestAClassThatDoesNotAnswerInTimeIsLatchedAndTheStartDoesNotWait(t *testing.T) {
	release := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer up.Close()
	defer close(release)
	e := newEnv(t, runnerA1, runnerA2)
	e.p.upstream, _ = url.Parse(up.URL)
	e.p.restoreDeadline = 300 * time.Millisecond
	e.p.scaleTries, e.p.scaleWait = 100, time.Millisecond
	started := time.Now()
	what, err := e.p.restore(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if took := time.Since(started); took > 5*time.Second {
		t.Errorf("the start waited %v for classes that do not answer", took)
	}
	if !strings.Contains(what, "tasks.class-a: CircleCI does not say") || !strings.Contains(what, "tasks.class-b: CircleCI does not say") {
		t.Errorf("both classes are failing safe, got: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "latched")
	e.check(e.claim(runnerB1), 403, "latched")
}

func TestThePollLoopStopsWithCtxAndLogsFailuresRarely(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.dnsErr = errors.New("server misbehaving")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { e.p.pollLoop(ctx, time.Millisecond); close(done) }()
	time.Sleep(100 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the poll loop ignores ctx")
	}
	if n := strings.Count(e.logs.String(), "poll: cannot resolve the runners"); n != 1 {
		t.Errorf("%d log lines for a poll that fails every millisecond, want 1", n)
	}
}

func TestLogEveryCountsWhatItHoldsBack(t *testing.T) {
	e := newEnv(t, runnerA1)
	l := logEvery{every: time.Hour}
	for range 3 {
		l.printf("x")
	}
	l.last = time.Now().Add(-2 * time.Hour)
	l.printf("x")
	if got := e.logs.String(); strings.Count(got, "x") != 2 || !strings.Contains(got, "x (3 times)") { // the first, and the fourth with the two held back
		t.Errorf("log:\n%s", got)
	}
}
