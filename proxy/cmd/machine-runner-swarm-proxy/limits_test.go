package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestTheDefaultLimits(t *testing.T) {
	p := &proxy{}
	p.setDefaultLimits()
	if p.ipLimit.rate != 50 || p.ipLimit.burst != 200 {
		t.Errorf("limit for every path: %v a second, burst %v, want 50 and 200", p.ipLimit.rate, p.ipLimit.burst)
	}
	if p.limit.rate != 2 || p.limit.burst != 10 {
		t.Errorf("limit for claims: %v a second, burst %v, want 2 and 10", p.limit.rate, p.limit.burst)
	}
	if cap(p.slots) != 512 {
		t.Errorf("concurrent requests: %d, want 512", cap(p.slots))
	}
}

func TestEveryPathIsLimitedPerAddress(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	now := time.Now()
	e.p.setDefaultLimits()
	e.p.ipLimit.now = func() time.Time { return now }
	e.p.limit = nil // the claim limit has its own test
	e.p.ipLimitLog.every = time.Hour
	e.upstream200()
	for i := range 200 {
		if code := e.do(runnerA1, "GET", "/api/v2/task/config", taskToken); code != 200 {
			t.Fatalf("request %d of the burst: %d", i+1, code)
		}
	}
	for _, c := range [][2]string{{"GET", "/api/v2/task/config"}, {"POST", "/api/v2/task/events"}, {"GET", healthPath}, {"POST", claimPath}, {"GET", "/anything"}} {
		r := httptest.NewRequest(c[0], c[1], nil)
		r.RemoteAddr = runnerA1 + ":1"
		w := httptest.NewRecorder()
		e.p.ServeHTTP(w, r)
		if w.Code != http.StatusTooManyRequests || w.Header().Get("Retry-After") == "" {
			t.Errorf("%s %s after the burst: %d, Retry-After %q, want 429 with Retry-After", c[0], c[1], w.Code, w.Header().Get("Retry-After"))
		}
	}
	e.check(e.do(runnerA2, "GET", "/api/v2/task/config", taskToken), 200, "another address has its own bucket")
	now = now.Add(time.Second) // 50 tokens
	for i := range 50 {
		if code := e.do(runnerA1, "GET", "/api/v2/task/config", taskToken); code != 200 {
			t.Fatalf("request %d after one second: %d", i+1, code)
		}
	}
	e.check(e.do(runnerA1, "GET", "/api/v2/task/config", taskToken), 429, "the 51st after one second")
	if n := strings.Count(e.logs.String(), "too many requests"); n != 1 {
		t.Errorf("%d log lines for the refusals, want one (and a count)", n)
	}
	now = now.Add(time.Hour)
	e.p.ipLimit.gc()
	if len(e.p.ipLimit.buckets) != 0 {
		t.Errorf("%d buckets after an hour, want none", len(e.p.ipLimit.buckets))
	}
}

func TestTheProxyServesAtMostSomeRequestsAtOnce(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.p.slots = make(chan struct{}, 2)
	e.p.stats = newTally()
	e.p.busyLog.every = time.Hour
	release := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-release }))
	defer up.Close()
	e.p.upstream, _ = url.Parse(up.URL)
	done := make(chan int, 2)
	for range 2 {
		go func() { done <- e.do("10.9.9.9", "GET", "/api/v2/task/config", taskToken) }()
	}
	for len(e.p.slots) < 2 {
		time.Sleep(time.Millisecond)
	}
	for _, c := range [][2]string{{"GET", "/api/v2/task/config"}, {"POST", claimPath}} {
		r := httptest.NewRequest(c[0], c[1], nil)
		r.RemoteAddr = runnerA1 + ":1"
		w := httptest.NewRecorder()
		e.p.ServeHTTP(w, r)
		if w.Code != http.StatusServiceUnavailable || w.Header().Get("Retry-After") == "" {
			t.Errorf("%s %s over the cap: %d, Retry-After %q, want 503 with Retry-After", c[0], c[1], w.Code, w.Header().Get("Retry-After"))
		}
	}
	e.check(e.do("10.9.9.8", "GET", healthPath, ""), 200, "the health check is not held back by the cap")
	if line := e.p.stats.summary(time.Minute, false, 0); !strings.Contains(line, "over capacity 2") {
		t.Errorf("the summary does not count the refusals: %s", line)
	}
	close(release)
	e.check(<-done, 200, "a request in progress")
	e.check(<-done, 200, "a request in progress")
	e.check(e.do("10.9.9.9", "GET", "/api/v2/task/config", taskToken), 200, "a slot is free again")
	if len(e.p.slots) != 0 {
		t.Errorf("%d slots held after all requests are done", len(e.p.slots))
	}
	if n := strings.Count(e.logs.String(), "requests are being served"); n != 1 {
		t.Errorf("%d log lines for the refusals over the cap, want one (and a count)", n)
	}
}

func TestTheSummaryLine(t *testing.T) {
	e := newEnv(t, runnerA1, runnerA2)
	e.p.stats = newTally()
	e.status = []int{200, 204, 500, 200}
	e.check(e.claim(runnerA1), 200, "task")
	e.check(e.claim(runnerA1), 403, "second claim")
	e.check(e.claim(runnerA2), 204, "no task")
	e.check(e.claim(runnerA2), 500, "another status")
	e.check(e.claim("10.9.9.9"), 403, "not a runner")
	e.check(e.claim("10.9.9.8"), 403, "not a runner")
	want := "summary of the last 1m0s: claims forwarded 3 (no task 1, other status 1, task 1), latched 1 (task 1), " +
		"refused 3 (already claimed 1, not a runner 2); requests over the per-address limit 0, over capacity 0"
	if got := e.p.stats.summary(time.Minute, false, 0); got != want {
		t.Errorf("summary:\n got %s\nwant %s", got, want)
	}
	want = "summary of the last 1m0s: claims forwarded 0, latched 0, refused 0; requests over the per-address limit 0, over capacity 0; the state cannot be written"
	if got := e.p.stats.summary(time.Minute, true, 0); got != want {
		t.Errorf("the next interval starts at zero:\n got %s\nwant %s", got, want)
	}
	if got := e.p.stats.summary(time.Minute, false, 3); !strings.Contains(got, "; 3 DNS lookups fell back to the system resolver") {
		t.Errorf("the DNS fallbacks are not in the summary: %s", got)
	}
}

func TestANoTaskAnswerIsNotLogged(t *testing.T) {
	e := newEnv(t, runnerA1)
	e.status = []int{204, 204, 204, 200}
	for range 3 {
		e.check(e.claim(runnerA1), 204, "no task")
	}
	if strings.Contains(e.logs.String(), "upstream status") {
		t.Errorf("a claim without a task is logged:\n%s", e.logs.String())
	}
	e.check(e.claim(runnerA1), 200, "task")
	if !strings.Contains(e.logs.String(), "claim from "+runnerA1+" (tasks.class-a): upstream status 200") {
		t.Errorf("a task that is handed out is not logged:\n%s", e.logs.String())
	}
}

func TestAFloodOfRefusalsIsRateLimitedInTheLog(t *testing.T) {
	e := newEnv(t, runnerA1)
	now := time.Now()
	e.p.stats = newTally()
	e.p.events = newLimiter(1, 3)
	e.p.events.now = func() time.Time { return now }
	for i := range 50 {
		e.check(e.claim(fmt.Sprintf("10.9.8.%d", i)), 403, "not a runner")
	}
	if n := strings.Count(e.logs.String(), "refused: not a runner"); n != 3 {
		t.Errorf("%d event lines for 50 refusals, want the burst of 3", n)
	}
	line := e.p.stats.summary(time.Minute, false, 0)
	if !strings.Contains(line, "refused 50 (not a runner 50)") || !strings.Contains(line, "47 event lines left out of the log") {
		t.Errorf("the summary does not count all the refusals and the lines left out: %s", line)
	}
	now = now.Add(time.Minute)
	e.check(e.claim("10.9.7.1"), 403, "not a runner")
	if n := strings.Count(e.logs.String(), "refused: not a runner"); n != 4 {
		t.Errorf("%d event lines after a minute, want one more", n)
	}
}

func TestTheFirstDNSFallbackIsLoggedOnce(t *testing.T) {
	e := newEnv(t, runnerA1)
	dnsFallbacks.Store(0)
	var f fallbackNotice
	for range 5 {
		f.note("tasks.class-a", fmt.Errorf("the DNS client is stopped"))
	}
	if n := strings.Count(e.logs.String(), "using the system resolver"); n != 1 {
		t.Errorf("%d log lines for 5 fall backs, want 1:\n%s", n, e.logs.String())
	}
	if n := dnsFallbacks.Load(); n != 5 {
		t.Errorf("%d fall backs counted, want 5", n)
	}
	dnsFallbacks.Store(0)
}
