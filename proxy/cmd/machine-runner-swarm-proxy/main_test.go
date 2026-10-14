package main

import (
	"bytes"
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

const (
	tokenA    = "CLASS-A-TOKEN-do-not-leak"
	tokenB    = "CLASS-B-TOKEN-do-not-leak"
	taskToken = "task-scoped-token"
	runnerA1  = "10.0.1.5"
	runnerA2  = "10.0.1.6"
	runnerB1  = "10.0.2.5"
	dnsA      = "tasks.class-a"
	dnsB      = "tasks.class-b"
)

type env struct {
	t        *testing.T
	p        *proxy
	dns      map[string][]string // DNS name -> IPs
	dnsErr   error
	status   []int // upstream statuses, one per request that reaches it (the last repeats)
	calls    atomic.Int32
	mu       sync.Mutex
	lastAuth string
	lastUA   string
	logs     bytes.Buffer
}

// newEnv makes a proxy for two classes: class-a with the given runner IPs, and class-b with runnerB1.
func newEnv(t *testing.T, ipsA ...string) *env {
	e := &env{t: t, dns: map[string][]string{dnsA: ipsA, dnsB: {runnerB1}}, status: []int{200}}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := int(e.calls.Add(1)) - 1
		e.mu.Lock()
		e.lastAuth = r.Header.Get("Authorization")
		e.lastUA = r.UserAgent()
		s := e.status[min(n, len(e.status)-1)]
		e.mu.Unlock()
		w.WriteHeader(s)
	}))
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	dir := t.TempDir()
	fileA, fileB := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	os.WriteFile(fileA, []byte("api:\n  auth_token: "+tokenA+"\n"), 0o400)
	os.WriteFile(fileB, []byte(tokenB+"\n"), 0o400)
	e.p = &proxy{upstream: u, classes: []*class{newClass("class-a", fileA), newClass(dnsB, fileB)}}
	e.p.lookup = func(_ context.Context, host string) ([]string, error) {
		e.mu.Lock()
		defer e.mu.Unlock()
		if e.dnsErr != nil {
			return nil, e.dnsErr
		}
		if ips, ok := e.dns[host]; ok && len(ips) > 0 {
			return ips, nil
		}
		return nil, &net.DNSError{IsNotFound: true}
	}
	log.SetOutput(&e.logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return e
}

func (e *env) do(from, method, path, auth string) int {
	r := httptest.NewRequest(method, path, nil)
	r.RemoteAddr = net.JoinHostPort(from, "40000")
	if auth != "" {
		r.Header.Set("Authorization", "Bearer "+auth)
	}
	w := httptest.NewRecorder()
	e.p.ServeHTTP(w, r)
	return w.Code
}

func (e *env) claim(from string) int { return e.do(from, "POST", claimPath, "placeholder") }

func (e *env) check(got, want int, what string) {
	e.t.Helper()
	if got != want {
		e.t.Errorf("%s: status %d, want %d", what, got, want)
	}
}

func TestEachClassGetsItsOwnToken(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.check(e.claim(runnerA1), 200, "claim of class a")
	if e.lastAuth != "Bearer "+tokenA {
		t.Errorf("a claim from class a carried %q, want the token of class a", e.lastAuth)
	}
	e.check(e.claim(runnerB1), 200, "claim of class b")
	if e.lastAuth != "Bearer "+tokenB {
		t.Errorf("a claim from class b carried %q, want the token of class b", e.lastAuth)
	}
	if e.calls.Load() != 2 {
		t.Errorf("%d claims reached the upstream, want 2", e.calls.Load())
	}
}

func TestClaimGetsClassTokenAndOthersPassThrough(t *testing.T) {
	e := newEnv(t, runnerA1)
	for _, from := range []string{runnerA1, "10.9.9.9"} { // any source: the call carries its own token
		e.check(e.do(from, "GET", "/api/v2/task/config", taskToken), 200, "other call")
		if e.lastAuth != "Bearer "+taskToken {
			t.Errorf("other call carried %q, want the task token untouched", e.lastAuth)
		}
	}
	e.check(e.do(runnerA1, "GET", "/api/v2/tasks/download", ""), 200, "call without a token")
	if e.lastAuth != "" {
		t.Errorf("a call without a token gained %q", e.lastAuth)
	}
}

func TestNeverInjectedOutsideTheExactClaimCall(t *testing.T) {
	e := newEnv(t, runnerA1)
	for _, c := range [][2]string{
		{"GET", claimPath}, {"PUT", claimPath}, {"POST", claimPath + "/"}, {"POST", "/" + claimPath},
		{"POST", "/API/v3/runner/claim"}, {"POST", "/api/v3/runner/./claim"}, {"POST", "/api/v3/runner/claim/x"},
	} {
		e.do(runnerA1, c[0], c[1], "guest")
		if e.lastAuth != "Bearer guest" {
			t.Errorf("%s %s carried %q, want the guest's own token", c[0], c[1], e.lastAuth)
		}
	}
}

func TestOnlyCurrentRunnersMayClaim(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.check(e.claim(runnerA2), 403, "claim from an IP that is not a runner")
	e.check(e.claim("127.0.0.1"), 403, "claim from loopback")
	e.check(e.claim("::ffff:10.9.9.9"), 403, "claim from a mapped IPv6 address that is not a runner")
	if e.calls.Load() != 0 {
		t.Error("a refused claim reached the upstream")
	}
}

func TestAClassNobodyServesHasNoRunners(t *testing.T) {
	// the runner of a service that the proxy is not configured for cannot claim, and neither can a class whose
	// service has no running task (its DNS name does not exist)
	e := newEnv(t, runnerA1)
	e.dns[dnsB] = nil
	e.check(e.claim(runnerB1), 403, "runner of a class without a DNS answer")
	e.check(e.claim("10.0.3.5"), 403, "runner of a class the proxy does not know")
	e.check(e.claim(runnerA1), 200, "the other class still works")
}

func TestAddressInTwoClassesIsRefused(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.dns[dnsB] = []string{runnerB1, runnerA1} // overlapping networks: whose token would it be?
	e.check(e.claim(runnerA1), 403, "an address of two classes")
	e.check(e.claim(runnerB1), 200, "an address of one class")
	if e.lastAuth != "Bearer "+tokenB {
		t.Errorf("claim carried %q", e.lastAuth)
	}
}

func TestOneClaimPerRunnerUntilItLeaves(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.status = []int{204, 204, 200, 200, 200}
	e.check(e.claim(runnerA1), 204, "no task yet")
	e.check(e.claim(runnerA1), 204, "still no task: not latched")
	e.check(e.claim(runnerA1), 200, "task")
	e.check(e.claim(runnerA1), 403, "second claim")
	e.check(e.claim(runnerA1), 403, "third claim")
	e.check(e.claim(runnerA2), 200, "another runner is independent")
	e.check(e.claim(runnerB1), 200, "a runner of another class is independent")
	if e.calls.Load() != 5 {
		t.Errorf("%d claims reached the upstream, want 5", e.calls.Load())
	}
	e.dns[dnsA] = []string{runnerA2} // runner A1's container is gone ...
	e.check(e.claim(runnerA1), 403, "claim from a runner that left")
	e.dns[dnsA] = []string{runnerA1, runnerA2} // ... and a new container takes its IP
	e.check(e.claim(runnerA1), 200, "new container on the same IP")
	e.check(e.claim(runnerA1), 403, "and only one claim")
}

func TestFailuresDoNotLatch(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.status = []int{401, 500, 200}
	e.check(e.claim(runnerA1), 401, "rejected")
	e.check(e.claim(runnerA1), 500, "server error")
	e.check(e.claim(runnerA1), 200, "task")
	e.check(e.claim(runnerA1), 403, "latched")
}

func TestFailsClosed(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.dnsErr = errors.New("servfail")
	e.check(e.claim(runnerA1), 503, "DNS failure")
	e.dnsErr = nil
	os.Remove(e.p.classes[0].tokenFile)
	e.check(e.claim(runnerA1), 503, "missing token file")
	if e.calls.Load() != 0 {
		t.Error("a claim reached the upstream without a token or without DNS")
	}
	e.check(e.claim(runnerB1), 200, "a class whose token file is fine is not affected by another's")
	e.dns = map[string][]string{}
	e.check(e.claim(runnerA1), 403, "no runners at all")
}

func TestStartWithoutAStateDirectoryLatchesEveryRunnerPresent(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	if _, err := e.p.restore(context.Background(), noStateAllow); err != nil {
		t.Fatal(err)
	}
	e.check(e.claim(runnerA1), 403, "runner of class a present at start")
	e.check(e.claim(runnerB1), 403, "runner of class b present at start")
	e.dns[dnsA] = []string{runnerA1}
	e.p.members(context.Background()) // A2 left and is released
	e.dns[dnsA] = []string{runnerA1, runnerA2}
	e.p.members(context.Background()) // a new container for A2
	e.check(e.claim(runnerA2), 200, "runner A2 was released when it left")
	e.check(e.claim(runnerA1), 403, "runner A1 never left")
	if e.calls.Load() != 1 {
		t.Errorf("%d claims reached the upstream, want 1", e.calls.Load())
	}
}

func TestOneClaimInFlightPerRunner(t *testing.T) {
	e := newEnv(t, runnerA1)
	release := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	defer up.Close()
	e.p.upstream, _ = url.Parse(up.URL)
	done := make(chan int)
	go func() { done <- e.claim(runnerA1) }()
	for { // wait for the first claim to hold the slot
		e.p.mu.Lock()
		b := e.p.classes[0].busy[runnerA1]
		e.p.mu.Unlock()
		if b {
			break
		}
	}
	e.check(e.claim(runnerA1), 403, "concurrent claim")
	close(release)
	e.check(<-done, 200, "first claim")
}

func TestTokensNeverLogged(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.status = []int{200}
	e.claim(runnerA1)
	e.claim(runnerA1)
	e.claim(runnerB1)
	e.claim("10.9.9.9")
	e.p.upstream, _ = url.Parse("http://127.0.0.1:1") // an unreachable upstream logs a transport error
	for _, c := range e.p.classes {
		c.latched = map[string]bool{}
	}
	e.claim(runnerA1)
	os.Remove(e.p.classes[1].tokenFile)
	e.do("10.9.9.9", "GET", healthPath, "") // a failing health check logs too
	e.p.health(httptest.NewRecorder())
	if e.logs.Len() == 0 || strings.Contains(e.logs.String(), tokenA) || strings.Contains(e.logs.String(), tokenB) {
		t.Errorf("log is empty or leaks a token:\n%s", e.logs.String())
	}
}

func TestHealth(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 200, "healthy")
	if e.calls.Load() != 0 {
		t.Error("the health check reached the upstream")
	}
	os.Remove(e.p.classes[1].tokenFile)
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 503, "a class without a token")
}

func TestTokenFileFormats(t *testing.T) {
	for in, want := range map[string]string{"abc\n": "abc", "api:\n  auth_token: abc\n": "abc", "api:\n  auth_token: \"abc\"\n": "abc"} {
		f := filepath.Join(t.TempDir(), "t")
		os.WriteFile(f, []byte(in), 0o400)
		if got, err := newClass("x", f).token(); err != nil || got != want {
			t.Errorf("%q: got %q, %v, want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"a\nb\n", "", "\n"} {
		f := filepath.Join(t.TempDir(), "t")
		os.WriteFile(f, []byte(in), 0o400)
		if _, err := newClass("x", f).token(); err == nil {
			t.Errorf("%q must not be used as a token", in)
		}
	}
}

func TestUserAgentIsTaggedOnEveryForwardedRequest(t *testing.T) {
	e := newEnv(t, runnerA1)
	for _, c := range [][2]string{{"POST", claimPath}, {"GET", "/api/v2/task/config"}} {
		r := httptest.NewRequest(c[0], c[1], nil)
		r.RemoteAddr = runnerA1 + ":1"
		r.Header.Set("User-Agent", "CircleCI-Machine-Runner/3.1.12 (linux; amd64) machine-runner-swarm-proxy/0.0.1") // a guest cannot suppress the tag
		e.p.ServeHTTP(httptest.NewRecorder(), r)
		if want := "CircleCI-Machine-Runner/3.1.12 (linux; amd64) machine-runner-swarm-proxy/0.0.1 machine-runner-swarm-proxy/" + version; e.lastUA != want {
			t.Errorf("%s %s: user agent %q, want %q", c[0], c[1], e.lastUA, want)
		}
	}
}

func TestParseClasses(t *testing.T) {
	cs, err := parseClasses([]string{"tasks.one=/run/secrets/one", "two = /run/secrets/two"},
		[]string{"PATH=/bin", classEnvPrefix + "B=three=/run/secrets/three", classEnvPrefix + "A=tasks.four=/run/secrets/four", classEnvPrefix + "EMPTY="})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, c := range cs {
		got = append(got, c.dns+"="+c.tokenFile)
	}
	want := "tasks.one=/run/secrets/one tasks.two=/run/secrets/two tasks.four=/run/secrets/four tasks.three=/run/secrets/three"
	if strings.Join(got, " ") != want {
		t.Errorf("classes %q, want %q", strings.Join(got, " "), want)
	}
	for _, bad := range [][]string{nil, {"noequals"}, {"=file"}, {"svc="}, {"a=/x", "tasks.a=/y"}} {
		if _, err := parseClasses(bad, nil); err == nil {
			t.Errorf("%q must be refused", bad)
		}
	}
}

// stateEnv is an env whose proxy keeps its state in dir, and a way to start "another process" on that directory.
func (e *env) withState(dir string) {
	st, err := openStore(dir)
	if err != nil {
		e.t.Fatal(err)
	}
	e.p.store = st
}

// restart is what a restarted proxy does: a new process with the same classes and the same directory, whose latches start empty.
func (e *env) restart(noState string) string {
	for _, c := range e.p.classes {
		c.latched = map[string]bool{}
		c.busy = map[string]bool{}
	}
	what, err := e.p.restore(context.Background(), noState)
	if err != nil {
		e.t.Fatal(err)
	}
	return what
}

func TestAFirstStartAllowsEveryoneAndARestartRefusesOnlyWhoClaimed(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.withState(t.TempDir())
	if what := e.restart(noStateAllow); !strings.Contains(what, "first start") {
		t.Errorf("a new directory is a first start, got: %s", what)
	}
	e.check(e.claim(runnerA1), 200, "a runner that was there before the proxy")
	e.check(e.claim(runnerA1), 403, "and only one claim")
	// the proxy restarts: A1 claimed, A2 and B1 did not
	if what := e.restart(noStateAllow); !strings.Contains(what, "state restored: 1 runner") {
		t.Errorf("want one runner restored, got: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "the runner that claimed stays refused after the restart")
	e.check(e.claim(runnerA2), 200, "a runner that has not claimed may claim after the restart")
	e.check(e.claim(runnerB1), 200, "so may a runner of the other class")
	// and a second restart knows about all three
	e.restart(noStateAllow)
	for _, ip := range []string{runnerA1, runnerA2, runnerB1} {
		e.check(e.claim(ip), 403, "claimed before the second restart: "+ip)
	}
}

func TestTheStateIsWrittenBeforeTheRunnerGetsItsAnswer(t *testing.T) {
	e := newEnv(t, runnerA1)
	dir := t.TempDir()
	e.withState(dir)
	e.restart(noStateAllow)
	var seen string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer up.Close()
	e.p.upstream, _ = url.Parse(up.URL)
	r := httptest.NewRequest("POST", claimPath, nil)
	r.RemoteAddr = runnerA1 + ":1"
	rec := &stateAtWrite{ResponseRecorder: httptest.NewRecorder(), read: func() { b, _ := os.ReadFile(filepath.Join(dir, stateFile)); seen = string(b) }}
	e.p.ServeHTTP(rec, r)
	if !strings.Contains(seen, runnerA1) {
		t.Errorf("the state did not hold the runner when the answer was written: %q", seen)
	}
}

// stateAtWrite reads the state file at the moment that the proxy writes the status line of its answer.
type stateAtWrite struct {
	*httptest.ResponseRecorder
	read func()
	once sync.Once
}

func (s *stateAtWrite) WriteHeader(code int) { s.once.Do(s.read); s.ResponseRecorder.WriteHeader(code) }

func TestReleasedRunnersLeaveTheState(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	dir := t.TempDir()
	e.withState(dir)
	e.restart(noStateAllow)
	e.check(e.claim(runnerA1), 200, "claim")
	e.dns[dnsA] = []string{runnerA2} // A1's container is gone
	e.p.members(context.Background())
	b, _ := os.ReadFile(filepath.Join(dir, stateFile))
	if strings.Contains(string(b), runnerA1) {
		t.Errorf("a runner that left is still in the state: %s", b)
	}
	e.dns[dnsA] = []string{runnerA1, runnerA2} // a new container takes the address
	e.restart(noStateAllow)
	e.check(e.claim(runnerA1), 200, "the new container on the same address may claim")
}

func TestLostStateFailsSafe(t *testing.T) {
	for name, damage := range map[string]func(dir string){
		"state file removed": func(dir string) { os.Remove(filepath.Join(dir, stateFile)) },
		"state file corrupt": func(dir string) { os.WriteFile(filepath.Join(dir, stateFile), []byte("{not json"), 0o600) },
		"state of a newer version": func(dir string) {
			os.WriteFile(filepath.Join(dir, stateFile), []byte(`{"version":2,"latched":{}}`), 0o600)
		},
		"state file empty": func(dir string) { os.WriteFile(filepath.Join(dir, stateFile), nil, 0o600) },
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, runnerA1, runnerA2)
			dir := t.TempDir()
			e.withState(dir)
			e.restart(noStateAllow)
			e.check(e.claim(runnerA1), 200, "claim")
			damage(dir)
			if what := e.restart(noStateAllow); !strings.Contains(what, "state lost") {
				t.Errorf("want a lost state, got: %s", what)
			}
			for _, ip := range []string{runnerA1, runnerA2, runnerB1} {
				e.check(e.claim(ip), 403, "every runner present is latched: "+ip)
			}
		})
	}
}

func TestNoStateLatchIsTheFailSafeStartOfAnUnusedDirectory(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.withState(t.TempDir())
	if what := e.restart(noStateLatch); !strings.Contains(what, "-no-state latch") {
		t.Errorf("got: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "latched by -no-state latch")
	e.check(e.claim(runnerB1), 403, "latched by -no-state latch")
}

func TestStateDirectoryMustBeWritable(t *testing.T) {
	f := filepath.Join(t.TempDir(), "file")
	os.WriteFile(f, nil, 0o600)
	if _, err := openStore(filepath.Join(f, "sub")); err == nil {
		t.Error("a state directory under a file must be refused")
	}
	if st, err := openStore(""); st != nil || err != nil {
		t.Error("an empty directory means no state")
	}
}

func TestAStateThatCannotBeWrittenMakesTheProxyUnhealthy(t *testing.T) {
	e := newEnv(t, runnerA1)
	dir := t.TempDir()
	e.withState(dir)
	e.restart(noStateAllow)
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 200, "healthy")
	os.RemoveAll(dir) // the volume is gone
	e.claim(runnerA1)
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 503, "the state cannot be written")
}
