package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
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
	status   []int        // upstream statuses, one per request that reaches it (the last repeats)
	calls    atomic.Int32 // requests that reach the upstream, the scale calls not counted
	mu       sync.Mutex
	lastAuth string
	lastUA   string
	logs     bytes.Buffer

	// what the fake /api/v3/runner/scale of the upstream says, by the token of the call
	running     map[string]int    // running task count (default 0)
	scaleStatus map[string][]int  // statuses of the next calls, one each, instead of the counts
	scaleBody   map[string]string // a body instead of the counts
	scaleCalls  []string          // the Authorization header of every scale call
}

// newEnv makes a proxy for two classes: class-a with the given runner IPs, and class-b with runnerB1.
func newEnv(t *testing.T, ipsA ...string) *env {
	e := &env{t: t, dns: map[string][]string{dnsA: ipsA, dnsB: {runnerB1}}, status: []int{200}}
	e.running, e.scaleStatus, e.scaleBody = map[string]int{}, map[string][]int{}, map[string]string{}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == scalePath {
			e.serveScale(w, r)
			return
		}
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
	e.p = &proxy{upstream: u, classes: []*class{newClass("class-a", fileA), newClass(dnsB, fileB)}, scaleTries: 3, releaseAfter: 3}
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

// serveScale answers GET /api/v3/runner/scale like CircleCI: the counts of the class of the bearer token.
func (e *env) serveScale(w http.ResponseWriter, r *http.Request) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.scaleCalls = append(e.scaleCalls, r.Header.Get("Authorization"))
	tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if r.Method != http.MethodGet || (tok != tokenA && tok != tokenB) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if seq := e.scaleStatus[tok]; len(seq) > 0 { // the next call fails with this status
		e.scaleStatus[tok] = seq[1:]
		w.WriteHeader(seq[0])
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if b, ok := e.scaleBody[tok]; ok {
		io.WriteString(w, b)
		return
	}
	fmt.Fprintf(w, `{"data":{"type":"scale","attributes":{"unclaimed_task_count":4,"running_task_count":%d}}}`, e.running[tok])
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

// polls is what the poller does n times: look at DNS and count the latched addresses that it does not list.
func (e *env) polls(n int) {
	e.t.Helper()
	for range n {
		if err := e.p.poll(context.Background()); err != nil {
			e.t.Fatal(err)
		}
	}
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
	e.polls(2)
	e.check(e.claim(runnerA1), 403, "claim from a runner that left, two polls ago")
	e.polls(1)
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

func TestStartWithoutAStateDirectoryLatchesTheRunnersOfAClassWithRunningTasks(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.running[tokenA] = 2 // class a has running tasks, class b has none
	what, err := e.p.restore(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(what, "no state directory") || !strings.Contains(what, "tasks.class-a: CircleCI reports 2 running task(s)") {
		t.Errorf("the log line does not say what happened: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "runner of class a present at start, with running tasks")
	e.check(e.claim(runnerB1), 200, "class b has no running task: its runner may claim")
	e.dns[dnsA] = []string{runnerA1}
	e.polls(3) // A2 left and is released
	e.dns[dnsA] = []string{runnerA1, runnerA2}
	e.polls(1) // a new container for A2
	e.check(e.claim(runnerA2), 200, "runner A2 was released when it left")
	e.check(e.claim(runnerA1), 403, "runner A1 never left")
	if e.calls.Load() != 2 {
		t.Errorf("%d claims reached the upstream, want 2", e.calls.Load())
	}
}

func TestEachClassAsksWithItsOwnToken(t *testing.T) {
	e := newEnv(t, runnerA1)
	if _, err := e.p.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(slices.Sorted(slices.Values(e.scaleCalls)), ",")
	if want := "Bearer " + tokenA + ",Bearer " + tokenB; got != want {
		t.Errorf("want one scale call per class with the token of that class, got %d calls", len(e.scaleCalls))
	}
	if strings.Contains(e.logs.String(), tokenA) || strings.Contains(e.logs.String(), tokenB) {
		t.Error("a token is in the log")
	}
}

func TestAFailedScaleCallLatchesTheClass(t *testing.T) {
	for name, fail := range map[string]func(e *env){
		"a server error":     func(e *env) { e.scaleStatus[tokenA] = []int{500, 500, 500} },
		"a rejected token":   func(e *env) { e.scaleStatus[tokenA] = []int{401, 401, 401} },
		"not JSON":           func(e *env) { e.scaleBody[tokenA] = "<html>" },
		"no running count":   func(e *env) { e.scaleBody[tokenA] = `{"data":{"attributes":{"unclaimed_task_count":0}}}` },
		"no unclaimed count": func(e *env) { e.scaleBody[tokenA] = `{"data":{"attributes":{"running_task_count":0}}}` },
		"a null unclaimed": func(e *env) {
			e.scaleBody[tokenA] = `{"data":{"attributes":{"running_task_count":0,"unclaimed_task_count":null}}}`
		},
		"another name": func(e *env) { e.scaleBody[tokenA] = `{"data":{"attributes":{"running_tasks":0,"unclaimed_tasks":0}}}` },
		"another case": func(e *env) {
			e.scaleBody[tokenA] = `{"data":{"attributes":{"Running_Task_Count":0,"unclaimed_task_count":0}}}`
		},
		"no attributes": func(e *env) { e.scaleBody[tokenA] = `{"data":{}}` },
		"a null count": func(e *env) {
			e.scaleBody[tokenA] = `{"data":{"attributes":{"unclaimed_task_count":0,"running_task_count":null}}}`
		},
		"a text count": func(e *env) {
			e.scaleBody[tokenA] = `{"data":{"attributes":{"unclaimed_task_count":0,"running_task_count":"0"}}}`
		},
		"a negative count": func(e *env) {
			e.scaleBody[tokenA] = `{"data":{"attributes":{"unclaimed_task_count":0,"running_task_count":-1}}}`
		},
		"a fractional count": func(e *env) {
			e.scaleBody[tokenA] = `{"data":{"attributes":{"unclaimed_task_count":0,"running_task_count":0.5}}}`
		},
		"no token file": func(e *env) { os.Remove(e.p.classes[0].tokenFile) },
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, runnerA1, runnerA2)
			fail(e)
			what, err := e.p.restore(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(what, "tasks.class-a: CircleCI does not say how many tasks run") || !strings.Contains(what, "latching the 2 runner(s) present") {
				t.Errorf("want a fail-safe line, got: %s", what)
			}
			for _, ip := range []string{runnerA1, runnerA2} {
				if !e.p.classes[0].latched[ip] {
					t.Errorf("%s of the class whose count is not known must be latched", ip)
				}
			}
			if e.p.classes[1].latched[runnerB1] {
				t.Error("class b has a count of 0 running tasks and must not be latched")
			}
		})
	}
	t.Run("an unreachable API", func(t *testing.T) {
		e := newEnv(t, runnerA1)
		e.p.upstream, _ = url.Parse("http://127.0.0.1:1")
		if _, err := e.p.restore(context.Background()); err != nil {
			t.Fatal(err)
		}
		if !e.p.classes[0].latched[runnerA1] || !e.p.classes[1].latched[runnerB1] {
			t.Error("with no answer at all every runner present is latched")
		}
	})
}

func TestTheScaleCallIsTriedAgainAtStart(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.scaleStatus[tokenA] = []int{503, 502} // the third try answers
	if _, err := e.p.restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	e.check(e.claim(runnerA1), 200, "the API answered on the third try with 0 running tasks")
	n := 0
	for _, a := range e.scaleCalls {
		if a == "Bearer "+tokenA {
			n++
		}
	}
	if n != 3 {
		t.Errorf("%d scale calls for class a, want 3", n)
	}
}

func TestNoRunnerPresentAsksNothing(t *testing.T) {
	e := newEnv(t)
	e.dns[dnsB] = nil
	if what, err := e.p.restore(context.Background()); err != nil || !strings.Contains(what, "no runner present") {
		t.Fatalf("got %q, %v", what, err)
	}
	if len(e.scaleCalls) != 0 {
		t.Errorf("%d scale calls for classes without a runner, want none", len(e.scaleCalls))
	}
}

func TestOnlyTheExactCountsAreRead(t *testing.T) {
	for name, tc := range map[string]struct {
		body string
		want int // latched runners of class a
	}{
		"nothing runs":           {`{"data":{"attributes":{"running_task_count":0,"unclaimed_task_count":3}}}`, 0},
		"one runs":               {`{"data":{"attributes":{"running_task_count":1,"unclaimed_task_count":0}}}`, 1},
		"a whole number as 2.0":  {`{"data":{"attributes":{"running_task_count":2.0,"unclaimed_task_count":0}}}`, 1},
		"other attributes":       {`{"data":{"type":"scale","attributes":{"running_task_count":0,"unclaimed_task_count":0,"agents_running":7,"running_tasks":9}}}`, 0},
		"a name that is similar": {`{"data":{"attributes":{"running_tasks":0,"unclaimed_task_count":0}}}`, 1},
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, runnerA1)
			e.scaleBody[tokenA] = tc.body
			if _, err := e.p.restore(context.Background()); err != nil {
				t.Fatal(err)
			}
			if got := len(e.p.classes[0].latched); got != tc.want {
				t.Errorf("%d runner(s) latched, want %d", got, tc.want)
			}
		})
	}
}

func TestAClassThatIsNewToTheStateAsksCircleCI(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
	e.check(e.claim(runnerA1), 200, "claim")
	// an add-on stack file adds class c after that: the saved state has no entry for it
	fileC := filepath.Join(t.TempDir(), "c")
	os.WriteFile(fileC, []byte(tokenB+"\n"), 0o400)
	e.p.classes = append(e.p.classes, newClass("class-c", fileC))
	e.dns["tasks.class-c"] = []string{"10.0.3.5"}
	e.running[tokenB] = 1 // class c has the token of class b in this test: one task running
	what := e.restart()
	if !strings.Contains(what, "state restored") || !strings.Contains(what, "tasks.class-c: CircleCI reports 1 running task(s)") {
		t.Errorf("got: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "class a has its state: the runner that claimed stays refused")
	e.check(e.claim(runnerA2), 200, "class a has its state: the other may claim")
	e.check(e.claim("10.0.3.5"), 403, "class c has none, and a task is running: latched")
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

func TestDiscoverClasses(t *testing.T) {
	dir := t.TempDir()
	for _, f := range []string{"linux-java-token", "linux-default-token", placeholderSecret, "-token", "notes", "linux-x-token.bak", "token"} {
		os.WriteFile(filepath.Join(dir, f), []byte("t"), 0o400)
	}
	os.Mkdir(filepath.Join(dir, "a-dir-token"), 0o700)
	os.Symlink(filepath.Join(dir, "linux-java-token"), filepath.Join(dir, "linked-token")) // a mounted secret can be a link
	os.Symlink(filepath.Join(dir, "gone"), filepath.Join(dir, "dangling-token"))
	cs, err := discoverClasses(dir)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, c := range cs {
		got = append(got, c.dns+"="+filepath.Base(c.tokenFile))
	}
	want := "tasks.linked=linked-token tasks.linux-default=linux-default-token tasks.linux-java=linux-java-token"
	if strings.Join(got, " ") != want {
		t.Errorf("classes %q, want %q (the placeholder, a directory, a dangling link and other names are no class)", strings.Join(got, " "), want)
	}
	onlyPlaceholder := t.TempDir()
	os.WriteFile(filepath.Join(onlyPlaceholder, placeholderSecret), []byte("t"), 0o400)
	for _, bad := range []string{t.TempDir(), onlyPlaceholder, filepath.Join(dir, "missing")} {
		if _, err := discoverClasses(bad); err == nil {
			t.Errorf("%s has no class and must be refused", bad)
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
func (e *env) restart() string {
	for _, c := range e.p.classes {
		c.latched = map[string]bool{}
		c.absent = map[string]int{}
		c.busy = map[string]bool{}
	}
	what, err := e.p.restore(context.Background())
	if err != nil {
		e.t.Fatal(err)
	}
	return what
}

func TestAFirstStartAllowsEveryoneAndARestartRefusesOnlyWhoClaimed(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.withState(t.TempDir())
	if what := e.restart(); !strings.Contains(what, "no state (a first start)") || !strings.Contains(what, "0 running tasks") {
		t.Errorf("a new directory is a first start that asks CircleCI, got: %s", what)
	}
	e.check(e.claim(runnerA1), 200, "a runner that was there before the proxy")
	e.check(e.claim(runnerA1), 403, "and only one claim")
	// the proxy restarts: A1 claimed, A2 and B1 did not
	if what := e.restart(); !strings.Contains(what, "tasks.class-a: 1 runner(s) have claimed") {
		t.Errorf("want one runner restored, got: %s", what)
	}
	e.check(e.claim(runnerA1), 403, "the runner that claimed stays refused after the restart")
	e.check(e.claim(runnerA2), 200, "a runner that has not claimed may claim after the restart")
	e.check(e.claim(runnerB1), 200, "so may a runner of the other class")
	// and a second restart knows about all three
	e.restart()
	for _, ip := range []string{runnerA1, runnerA2, runnerB1} {
		e.check(e.claim(ip), 403, "claimed before the second restart: "+ip)
	}
}

func TestTheStateIsWrittenBeforeTheRunnerGetsItsAnswer(t *testing.T) {
	e := newEnv(t, runnerA1)
	dir := t.TempDir()
	e.withState(dir)
	e.restart()
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
	e.restart()
	e.check(e.claim(runnerA1), 200, "claim")
	e.dns[dnsA] = []string{runnerA2} // A1's container is gone
	e.polls(3)
	b, _ := os.ReadFile(filepath.Join(dir, stateFile))
	if strings.Contains(string(b), runnerA1) {
		t.Errorf("a runner that left is still in the state: %s", b)
	}
	e.dns[dnsA] = []string{runnerA1, runnerA2} // a new container takes the address
	e.restart()
	e.check(e.claim(runnerA1), 200, "the new container on the same address may claim")
}

func TestLostStateAsksCircleCI(t *testing.T) {
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
			e.restart()
			e.check(e.claim(runnerA1), 200, "claim")
			damage(dir)
			e.running[tokenA] = 1 // the claim is a running task
			if what := e.restart(); !strings.Contains(what, "state lost") {
				t.Errorf("want a lost state, got: %s", what)
			}
			for _, ip := range []string{runnerA1, runnerA2} {
				e.check(e.claim(ip), 403, "class a has a running task: every runner present is latched: "+ip)
			}
			e.check(e.claim(runnerB1), 200, "class b has none: its runner may claim")
		})
	}
	t.Run("nothing runs", func(t *testing.T) {
		e := newEnv(t, runnerA1, runnerA2)
		dir := t.TempDir()
		e.withState(dir)
		e.restart()
		os.Remove(filepath.Join(dir, stateFile))
		if what := e.restart(); !strings.Contains(what, "state lost") || !strings.Contains(what, "may claim") {
			t.Errorf("got: %s", what)
		}
		e.check(e.claim(runnerA1), 200, "no task of the class runs: the runner may claim")
	})
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
	e.restart()
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 200, "healthy")
	os.RemoveAll(dir) // the volume is gone
	e.check(e.claim(runnerA1), 503, "the latch of the claim cannot be saved: no task for the runner")
	e.check(e.do("10.9.9.9", "GET", healthPath, ""), 503, "the state cannot be written")
}

func TestHealthcheckFlag(t *testing.T) {
	status := atomic.Int32{}
	status.Store(200)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != healthPath {
			t.Errorf("asked for %s", r.URL.Path)
		}
		w.WriteHeader(int(status.Load()))
	}))
	defer srv.Close()
	listen := strings.TrimPrefix(srv.URL, "http://")
	if got := checkHealth(listen); got != 0 {
		t.Errorf("healthy proxy: exit %d, want 0", got)
	}
	_, port, _ := net.SplitHostPort(listen)
	if got := checkHealth(":" + port); got != 0 {
		t.Errorf("-listen :%s means this host: exit %d, want 0", port, got)
	}
	status.Store(503)
	if got := checkHealth(listen); got != 1 {
		t.Errorf("unhealthy proxy: exit %d, want 1", got)
	}
	srv.Close()
	if got := checkHealth(listen); got != 1 {
		t.Errorf("no proxy: exit %d, want 1", got)
	}
	if got := checkHealth("not an address"); got != 1 {
		t.Errorf("bad address: exit %d, want 1", got)
	}
}

func writeBytes(path, content string) error { return os.WriteFile(path, []byte(content), 0o600) }
