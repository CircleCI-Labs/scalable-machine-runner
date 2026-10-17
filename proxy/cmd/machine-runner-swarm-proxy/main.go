// machine-runner-swarm-proxy keeps the CircleCI resource class tokens off machine runner containers on Docker Swarm.
//
// Runners point CIRCLECI_RUNNER_API_URL at this proxy and hold only a placeholder token. The proxy adds the
// class token to the task-claim call and to nothing else; every other call passes through untouched, because
// the runner and its task agent send the task-scoped token from the claim response themselves.
//
// One proxy serves every class of a stack. It finds its classes in its secrets directory (-secrets-dir): every file
// <service>-token is one class, whose runner containers are tasks.<service> (on the class overlay network) and whose token
// is in that file. A claim is allowed only from an IP that is currently in the DNS answer of a class, and it gets that class's
// token.
//
// One claim per runner container: after a claim that returns a task, that IP is latched and further claims from it
// get 403 until the IP has been missing from the DNS answer for several polls in a row (the container is gone). Single-task
// mode only: a continuous runner claims many times. The latch fails closed: a claim whose latch cannot be saved does not
// get its task, and any failure to write the state removes the state file, so that the next start takes the fail-safe path. A claim
// whose outcome is unknown is latched too: when the request reached CircleCI and the answer was lost (a reset, or no response headers
// within upstreamHeaderTimeout), the task may have been handed out, so the runner may not claim again. That costs one idle runner,
// which Swarm replaces. A claim that failed before the request was sent (no connection) is not latched.
//
// Every client IP is limited to ipRate requests a second (ipBurst burst) on all paths, and the proxy serves at most maxInFlight requests at
// a time (more get 503 with Retry-After): one job cannot starve the claims of every class. /healthz counts for the per-address limit and
// not for the cap, so that a busy proxy is not restarted by its own health check (a restart takes the fail-safe path). Once a minute
// the proxy logs one summary line of the claims (forwarded, latched, refused by reason).
//
// A restarted proxy must know who has claimed. With -state-dir it keeps the latched IPs in a small file of a volume,
// written before the claim's answer goes back to the runner, and a restart with that state refuses every IP that really
// claimed, whether DNS lists it yet or not. A class with no state (a proxy that never ran, a state that was lost, no
// -state-dir, a class that is new to the state) cannot know, so the proxy asks CircleCI: GET /api/v3/runner/scale with the
// token of that class says how many tasks of the class are running. With none running, no runner present can be holding a
// task, and the runners present may claim. With some running, or when the call fails or does not answer in time, the proxy
// fails safe and latches every IP present of that class. See state.go.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	claimPath  = "/api/v3/runner/claim"
	scalePath  = "/api/v3/runner/scale"
	healthPath = "/healthz"

	tokenSuffix = "-token" // a secret <service>-token is the class <service>
	// placeholderSecret is the made-up token that every runner reads. It is never mounted into the proxy, and it is never a class.
	placeholderSecret = "runner-placeholder-token"

	maxClaimBody  = 64 << 10 // a claim is a small JSON document
	releasePolls  = 30       // seconds of polls that DNS must omit a latched IP before the latch is released
	restoreWithin = 25 * time.Second

	// upstreamHeaderTimeout is how long CircleCI has to start its answer once the request is sent. A claim that hangs holds its
	// runner's in-flight mark, and the claim is latched when the time runs out (the outcome is unknown).
	upstreamHeaderTimeout = 60 * time.Second

	// Limits for every client IP and for the proxy as a whole, on all paths (a claim has its own, lower limit as well).
	ipRate      = 50  // requests a second from one IP
	ipBurst     = 200 // and bursts of up to this many
	maxInFlight = 512 // requests being served at once

	summaryEvery = time.Minute
)

var version = "dev" // -ldflags "-X main.version=..."

// A token file is either the bare token or a runner config with an auth_token line (the Swarm secret format).
var tokenLine = regexp.MustCompile(`(?m)^\s*auth_token:\s*["']?([^"'\s]+)`)

// class is one resource class: the runner containers of a Swarm service and the file with the token they claim with.
type class struct {
	dns       string // tasks.<service>: the IPs of the runner containers
	tokenFile string

	latched map[string]bool // runner IPs that have claimed a task
	absent  map[string]int  // latched IPs: how many polls in a row DNS has not listed them
	busy    map[string]bool // runner IPs with a claim in flight
}

func newClass(service, tokenFile string) *class {
	if !strings.HasPrefix(service, "tasks.") {
		service = "tasks." + service
	}
	return &class{dns: service, tokenFile: tokenFile, latched: map[string]bool{}, absent: map[string]int{}, busy: map[string]bool{}}
}

// discoverClasses finds the classes in dir: one for every file <service>-token, except the placeholder of the runners.
func discoverClasses(dir string) ([]*class, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var classes []*class
	for _, e := range entries { // sorted by name
		name := e.Name()
		service, ok := strings.CutSuffix(name, tokenSuffix)
		if !ok || service == "" || name == placeholderSecret {
			continue
		}
		if fi, err := os.Stat(filepath.Join(dir, name)); err != nil || fi.IsDir() { // a mounted secret may be a link to a file
			continue
		}
		classes = append(classes, newClass(service, filepath.Join(dir, name)))
	}
	if len(classes) == 0 {
		return nil, fmt.Errorf("no file *%s in %s", tokenSuffix, dir)
	}
	return classes, nil
}

type proxy struct {
	upstream *url.URL
	classes  []*class
	lookup   func(ctx context.Context, host string) ([]string, error)

	store    *store      // nil: no persistence: a restart asks CircleCI (scale) which runners may claim
	stateErr error       // the last failure to write the state, which makes the proxy unhealthy and refuses claims; guarded by mu
	stateBad atomic.Bool // stateErr != nil, readable without the lock (the health check)
	saveMu   sync.Mutex  // one save at a time, each with a snapshot taken after the one before it was written

	scaleTries      int           // attempts of the scale call at start (at least 1)
	scaleWait       time.Duration // between the attempts
	restoreDeadline time.Duration // all the scale calls of the start together; a class without an answer by then is latched
	releaseAfter    int           // polls without a class listing a latched IP before the latch goes (at least 1)

	limit     *limiter          // claims per source address
	ipLimit   *limiter          // all requests per source address
	slots     chan struct{}     // one slot per request being served (not /healthz); nil: no cap
	events    *limiter          // the lines about single requests; nil: all of them
	stats     *tally            // for the summary line; nil: no counts
	transport http.RoundTripper // to the upstream; nil: a transport with upstreamHeaderTimeout
	cacheTTL  time.Duration     // how long a claim may use the DNS answer of an earlier lookup

	mu sync.Mutex // guards the latched, absent and busy maps of every class and stateErr. It is not held while the state is written.

	cacheMu  sync.Mutex // one DNS lookup at a time for the claims
	cache    map[*class]map[string]bool
	cacheErr error // the lookup at cacheAt failed
	cacheAt  time.Time

	limitLog   logEvery // the refusals of the claim rate limit: a flood would fill the log
	ipLimitLog logEvery // the refusals of the limit on all requests
	busyLog    logEvery // the requests refused because the cap is reached
	stateLog   logEvery // the failures to write the state: every claim that comes while it fails tries again
}

// setDefaultLimits sets the limits of a running proxy.
func (p *proxy) setDefaultLimits() {
	p.limit = newLimiter(2, 10)
	p.ipLimit = newLimiter(ipRate, ipBurst)
	p.slots = make(chan struct{}, maxInFlight)
	p.events = newLimiter(2, 20)
	p.stats = newTally()
	p.limitLog.every, p.ipLimitLog.every, p.busyLog.every, p.stateLog.every = time.Minute, time.Minute, time.Minute, time.Minute
}

// describe lists what DNS says for every class, for the log line of a claim from an address that belongs to none: a runner that
// Swarm has just started, and a DNS answer that does not list it yet, look the same from the outside.
func describe(classes []*class, sets map[*class]map[string]bool) string {
	var parts []string
	for _, c := range classes {
		var ips []string
		for ip := range sets[c] {
			ips = append(ips, ip)
		}
		sort.Strings(ips)
		parts = append(parts, c.dns+" lists ["+strings.Join(ips, " ")+"]")
	}
	return strings.Join(parts, ", ")
}

func norm(s string) string {
	if a, err := netip.ParseAddr(s); err == nil {
		return a.Unmap().String()
	}
	return s
}

// token reads the class token on every claim, so a replaced file takes effect without a restart.
func (c *class) token() (string, error) {
	b, err := os.ReadFile(c.tokenFile)
	if err != nil {
		return "", err
	}
	s := strings.TrimSpace(string(b))
	if m := tokenLine.FindStringSubmatch(s); m != nil {
		s = m[1]
	}
	if s == "" || strings.ContainsAny(s, "\r\n") {
		return "", errors.New("token file holds no usable token")
	}
	return s, nil
}

// resolve returns the runner IPs of every class, looked up side by side. An unknown name (no running task) is an empty set; any other
// DNS failure is an error and changes nothing.
func (p *proxy) resolve(ctx context.Context) (map[*class]map[string]bool, error) {
	type answer struct {
		set map[string]bool
		err error
	}
	answers := make([]answer, len(p.classes))
	var wg sync.WaitGroup
	for i, c := range p.classes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			lctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			addrs, err := p.lookup(lctx, c.dns)
			var dnsErr *net.DNSError
			if err != nil && !(errors.As(err, &dnsErr) && dnsErr.IsNotFound) {
				answers[i].err = fmt.Errorf("%s: %w", c.dns, err)
				return
			}
			set := map[string]bool{}
			for _, a := range addrs {
				set[norm(a)] = true
			}
			answers[i].set = set
		}()
	}
	wg.Wait()
	sets := map[*class]map[string]bool{}
	for i, c := range p.classes {
		if answers[i].err != nil {
			return nil, answers[i].err
		}
		sets[c] = answers[i].set
	}
	return sets, nil
}

// membership is resolve for the claims: an answer, or a failure, that is younger than cacheTTL is reused, and the lookups of concurrent
// claims are one. The lookup does not end with the request that started it: the answer is for every claim that waits.
func (p *proxy) membership(ctx context.Context) (map[*class]map[string]bool, error) {
	p.cacheMu.Lock()
	defer p.cacheMu.Unlock()
	if !p.cacheAt.IsZero() && time.Since(p.cacheAt) < p.cacheTTL {
		return p.cache, p.cacheErr
	}
	p.cache, p.cacheErr = p.resolve(context.WithoutCancel(ctx))
	p.cacheAt = time.Now()
	return p.cache, p.cacheErr
}

// poll looks at DNS once and releases the latch of every IP that has been missing for releaseAfter polls in a row. A failed lookup
// says nothing and changes nothing (the latch stays), and an answer that lists the IP starts the count again. A whole class that DNS
// does not know (no task of the service runs) is one missing poll for each of its latched IPs, not a release.
func (p *proxy) poll(ctx context.Context) error {
	sets, err := p.resolve(ctx)
	if err != nil {
		return err
	}
	p.cacheMu.Lock()
	p.cache, p.cacheErr, p.cacheAt = sets, nil, time.Now()
	p.cacheMu.Unlock()
	changed := false
	p.mu.Lock()
	for _, c := range p.classes {
		for ip := range c.latched {
			if sets[c][ip] {
				delete(c.absent, ip)
				continue
			}
			c.absent[ip]++
			if c.absent[ip] >= max(p.releaseAfter, 1) {
				delete(c.latched, ip)
				delete(c.absent, ip)
				changed = true
				log.Printf("released %s (%s)", ip, c.dns)
			}
		}
	}
	p.mu.Unlock()
	if changed || p.stateBad.Load() { // a state that could not be written is tried again
		p.persist()
	}
	p.limit.gc()
	p.ipLimit.gc()
	return nil
}

// scale asks CircleCI how many tasks of class c are running and how many wait, with the token of that class. It tries scaleTries
// times, scaleWait apart, because a proxy that starts together with its network may not reach the API at once.
func (p *proxy) scale(ctx context.Context, c *class) (running, unclaimed int, err error) {
	tok, err := c.token()
	if err != nil {
		return 0, 0, err
	}
	for try := 1; ; try++ {
		running, unclaimed, err = p.scaleOnce(ctx, tok)
		if err == nil || try >= max(p.scaleTries, 1) || ctx.Err() != nil {
			return running, unclaimed, err
		}
		select {
		case <-ctx.Done():
			return 0, 0, ctx.Err()
		case <-time.After(p.scaleWait):
		}
	}
}

// scaleOnce reads GET /api/v3/runner/scale: {"data":{"attributes":{"running_task_count":N,"unclaimed_task_count":M}}}. Both counts must be
// there and be whole numbers of 0 or more; anything else is an error, which latches the runners of the class.
func (p *proxy) scaleOnce(ctx context.Context, tok string) (running, unclaimed int, err error) {
	u := *p.upstream
	u.Path = strings.TrimRight(u.Path, "/") + scalePath
	u.RawQuery = ""
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return 0, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "machine-runner-swarm-proxy/"+version)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, 0, fmt.Errorf("%s answered %d", scalePath, resp.StatusCode)
	}
	var doc struct {
		Data struct {
			Attributes map[string]json.RawMessage `json:"attributes"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&doc); err != nil {
		return 0, 0, fmt.Errorf("%s: cannot read the answer: %w", scalePath, err)
	}
	count := func(name string) (int, error) {
		var v *float64 // a null is not a count: it would read as 0 and allow every runner
		if json.Unmarshal(doc.Data.Attributes[name], &v) != nil || v == nil || *v < 0 || *v != math.Trunc(*v) || *v >= 1<<31 {
			return 0, fmt.Errorf("%s: data.attributes.%s is missing or not a count", scalePath, name)
		}
		return int(*v), nil
	}
	if running, err = count("running_task_count"); err != nil {
		return 0, 0, err
	}
	if unclaimed, err = count("unclaimed_task_count"); err != nil {
		return 0, 0, err
	}
	return running, unclaimed, nil
}

// storeError is a failure of the state directory at start, which no retry mends: the proxy stops.
type storeError struct{ err error }

func (e *storeError) Error() string { return e.err.Error() }
func (e *storeError) Unwrap() error { return e.err }

// restore sets the latches at start and returns what it did, for the log. A class with a saved state (the IPs that claimed) gets exactly
// those latched, whether DNS lists them yet or not. A class with none cannot know who has claimed, so it asks CircleCI (scale), all the
// classes at once and within restoreDeadline: no running task of the class means that no runner present holds one, and they may claim;
// otherwise, or when the answer is missing or late, every IP present is latched, which only costs those runners their claim (they leave
// and are replaced). An error from DNS is worth a retry; a *storeError is not.
func (p *proxy) restore(ctx context.Context) (string, error) {
	sets, err := p.resolve(ctx)
	if err != nil {
		return "", err
	}
	kind, saved, err := p.store.load()
	if err != nil {
		return "", &storeError{err}
	}
	why := map[startKind]string{
		stateOK:      "state restored",
		stateNone:    "no state (a first start)",
		stateLost:    "state lost",
		stateNoStore: "no state directory",
	}[kind]
	type verdict struct {
		latch []string // IPs to latch
		what  string
	}
	verdicts := make([]verdict, len(p.classes))
	pctx, cancel := context.WithTimeout(ctx, orDefault(p.restoreDeadline, restoreWithin))
	defer cancel()
	var wg sync.WaitGroup
	for i, c := range p.classes {
		var ips []string
		for ip := range sets[c] {
			ips = append(ips, ip)
		}
		sort.Strings(ips)
		v := &verdicts[i]
		switch {
		case kind == stateOK && saved[c.dns] != nil:
			v.latch = saved[c.dns]
			v.what = fmt.Sprintf("%d runner(s) have claimed and stay refused; the others may claim", len(v.latch))
		case len(ips) == 0:
			v.what = "no runner present"
		default:
			wg.Add(1)
			go func() {
				defer wg.Done()
				if running, unclaimed, err := p.scale(pctx, c); err != nil {
					v.latch = ips
					v.what = fmt.Sprintf("CircleCI does not say how many tasks run (%v): failing safe, latching the %d runner(s) present", err, len(ips))
				} else if running > 0 {
					v.latch = ips
					v.what = fmt.Sprintf("CircleCI reports %d running task(s), %d unclaimed: failing safe, latching the %d runner(s) present", running, unclaimed, len(ips))
				} else {
					v.what = fmt.Sprintf("CircleCI reports 0 running tasks, %d unclaimed: the %d runner(s) present may claim", unclaimed, len(ips))
				}
			}()
		}
	}
	wg.Wait()
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	var lines []string
	p.mu.Lock()
	for i, c := range p.classes {
		for _, ip := range verdicts[i].latch {
			c.latched[ip] = true
		}
		lines = append(lines, c.dns+": "+verdicts[i].what)
	}
	p.mu.Unlock()
	if err := p.persist(); err != nil {
		return "", &storeError{err}
	}
	return why + "; " + strings.Join(lines, "; "), nil
}

// start is restore, tried again after every failure of DNS (the network of a new proxy may not be up yet), wait apart. A failure of the
// state directory (*storeError), or the end of ctx, ends it.
func (p *proxy) start(ctx context.Context, wait time.Duration) (string, error) {
	for {
		what, err := p.restore(ctx)
		var se *storeError
		if err == nil || ctx.Err() != nil || errors.As(err, &se) {
			return what, err
		}
		log.Printf("waiting for DNS: %v", err)
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(wait):
		}
	}
}

func orDefault(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

// persist writes the latched IPs to the state directory, if there is one, and returns the failure: a latch that is not on disk is not
// to be relied on. A failed write removes the state file (store.save), so that a restart does not read a state that is behind.
// The caller does not hold p.mu: the snapshot of the latches is taken under it, and the fsyncs run without it, so that a slow volume does
// not stall the other claims or the health check. Saves are one at a time (saveMu), and each takes its snapshot after the one before has
// been written, so that it holds every latch that was set before the call (and maybe more, which is safe): the claim that calls persist
// has set its latch first, and does not answer its runner before the state holds it.
func (p *proxy) persist() error {
	p.saveMu.Lock()
	defer p.saveMu.Unlock()
	p.mu.Lock()
	snap := snapshotLatched(p.classes)
	p.mu.Unlock()
	err := p.store.save(snap)
	p.mu.Lock()
	p.stateErr = err
	p.mu.Unlock()
	p.stateBad.Store(err != nil)
	if err != nil {
		p.stateLog.printf("state: cannot write it: %v", err)
	}
	return err
}

// errNotLatched: the upstream answered a claim with a task, but its latch could not be saved. The runner does not get the task.
var errNotLatched = errors.New("the latch of the claim could not be saved")

// refuse answers a claim that is not allowed. The reason goes to the log only: the body says nothing about the classes or the runners.
// The line is one of the lines about single requests (eventf), and the refusal is counted under kind for the summary line.
func (p *proxy) refuse(w http.ResponseWriter, ip, kind, why string, code int) {
	p.stats.refuse(kind)
	p.eventf("claim from %s refused: %s", ip, why)
	body := "claim refused"
	if code != http.StatusForbidden {
		body = "unavailable"
	}
	http.Error(w, body, code)
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ap, _ := netip.ParseAddrPort(r.RemoteAddr)
	ip := ap.Addr().Unmap().String()
	if !p.ipLimit.allow(ip) { // every path, the health check too
		p.stats.limit()
		p.ipLimitLog.printf("request from %s refused: too many requests", ip)
		w.Header().Set("Retry-After", "1")
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}
	if r.URL.Path == healthPath {
		p.health(w)
		return
	}
	if p.slots != nil {
		select {
		case p.slots <- struct{}{}:
			defer func() { <-p.slots }()
		default:
			p.stats.overload()
			p.busyLog.printf("request from %s refused: %d requests are being served", ip, cap(p.slots))
			w.Header().Set("Retry-After", "1")
			http.Error(w, "too many requests in progress", http.StatusServiceUnavailable)
			return
		}
	}
	if r.Method != http.MethodPost || r.URL.Path != claimPath {
		p.forward(w, r, "", nil, "")
		return
	}
	if !p.limit.allow(ip) {
		p.stats.refuse(refRate)
		p.limitLog.printf("claim from %s refused: too many claims", ip)
		w.Header().Set("Retry-After", "1")
		http.Error(w, "too many claims", http.StatusTooManyRequests)
		return
	}
	if r.ContentLength > maxClaimBody {
		p.stats.refuse(refTooLarge)
		http.Error(w, "claim too large", http.StatusRequestEntityTooLarge)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxClaimBody)
	// An address that has claimed, or has a claim in flight, is refused from memory: no DNS lookup is spent on it.
	p.mu.Lock()
	kind, why := "", ""
	for _, k := range p.classes {
		if k.latched[ip] {
			kind, why = refAlready, "this runner has already claimed a task"
		} else if k.busy[ip] && why == "" {
			kind, why = refInFlight, "a claim from this runner is in flight"
		}
	}
	p.mu.Unlock()
	if why != "" {
		p.refuse(w, ip, kind, why, http.StatusForbidden)
		return
	}
	sets, err := p.membership(r.Context())
	if err != nil {
		p.stats.refuse(refDNS)
		p.eventf("claim from %s refused: cannot resolve the runners: %v", ip, err)
		http.Error(w, "cannot resolve the runners", http.StatusServiceUnavailable)
		return
	}
	var c *class
	code := http.StatusForbidden
	p.mu.Lock()
	owners := 0
	for _, k := range p.classes {
		if sets[k][ip] {
			owners++
			c = k
		}
	}
	switch {
	case owners == 0:
		kind, why = refNotRunner, "not a runner of any class ("+describe(p.classes, sets)+")"
	case owners > 1: // overlapping networks: do not guess whose token this is
		kind, why = refSeveral, "the address belongs to several classes"
	case c.latched[ip]: // it claimed while the lookup ran
		kind, why = refAlready, "this runner has already claimed a task"
	case c.busy[ip]:
		kind, why = refInFlight, "a claim from this runner is in flight"
	default:
		c.busy[ip] = true
	}
	p.mu.Unlock()
	if why == "" && p.stateBad.Load() && p.persist() != nil { // no task that the latch could not hold
		p.mu.Lock()
		delete(c.busy, ip)
		p.mu.Unlock()
		kind, why, code = refState, "the state cannot be written", http.StatusServiceUnavailable
	}
	if why != "" {
		p.refuse(w, ip, kind, why, code)
		return
	}
	defer func() { p.mu.Lock(); delete(c.busy, ip); p.mu.Unlock() }()
	if tok, err := c.token(); err != nil {
		p.stats.refuse(refNoToken)
		p.eventf("claim from %s (%s) failed: %v", ip, c.dns, err)
		http.Error(w, "no token", http.StatusServiceUnavailable)
	} else {
		p.forward(w, r, tok, c, ip)
	}
}

// health answers 200 when every class has a usable token file. It never says which class or why. It takes no lock that a claim holds.
func (p *proxy) health(w http.ResponseWriter) {
	if p.stateBad.Load() {
		http.Error(w, "unhealthy", http.StatusServiceUnavailable)
		return
	}
	for _, c := range p.classes {
		if _, err := c.token(); err != nil {
			p.eventf("health: %s: %v", c.dns, err)
			http.Error(w, "unhealthy", http.StatusServiceUnavailable)
			return
		}
	}
	fmt.Fprintln(w, "ok")
}

// upstreamTransport is the transport to the upstream: the default one, with a limit on the wait for the response headers.
var upstreamTransport = func() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.ResponseHeaderTimeout = upstreamHeaderTimeout
	return t
}()

// trackedBody remembers that reading the body of a request failed (it was cut at the cap, or the runner went away): the request that
// the upstream got was then not complete, and it cannot have acted on it.
type trackedBody struct {
	io.ReadCloser
	failed *atomic.Bool
}

func (b trackedBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if err != nil && err != io.EOF {
		b.failed.Store(true)
	}
	return n, err
}

// forward proxies r upstream. With tok set it adds the bearer token; with c and ip set a task in the response latches ip, and so does
// a failure after the request reached the upstream (the outcome of the claim is unknown: fail closed).
func (p *proxy) forward(w http.ResponseWriter, r *http.Request, tok string, c *class, ip string) {
	var connected, bodyFailed atomic.Bool // a connection to the upstream was in use; the body of the claim could not be read to its end
	var transport http.RoundTripper = upstreamTransport
	if p.transport != nil {
		transport = p.transport
	}
	(&httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(p.upstream)
			if tok != "" {
				pr.Out.Header.Set("Authorization", "Bearer "+tok)
			}
			if ua := pr.Out.UserAgent(); ua != "" { // tell CircleCI which requests came through this proxy
				pr.Out.Header.Set("User-Agent", ua+" machine-runner-swarm-proxy/"+version)
			}
			if c != nil {
				pr.Out = pr.Out.WithContext(httptrace.WithClientTrace(pr.Out.Context(), &httptrace.ClientTrace{
					GotConn: func(httptrace.GotConnInfo) { connected.Store(true) },
				}))
				if pr.Out.Body != nil {
					pr.Out.Body = trackedBody{pr.Out.Body, &bodyFailed}
				}
			}
		},
		ModifyResponse: func(resp *http.Response) error {
			if c == nil {
				return nil
			}
			switch {
			case resp.StatusCode/100 == 2 && resp.StatusCode != http.StatusNoContent: // 204: no task yet
				p.stats.forward(fwdTask)
				log.Printf("claim from %s (%s): upstream status %d", ip, c.dns, resp.StatusCode)
				p.latch(c, ip, latchTask)
				if p.persist() != nil { // before the runner gets its task: a restart must know that it has claimed
					return errNotLatched // the runner does not get the task; the latch stays in memory
				}
			case resp.StatusCode == http.StatusNoContent:
				p.stats.forward(fwdNone) // not logged: an idle runner asks about every five seconds
			default:
				p.stats.forward(fwdStatus)
				p.eventf("claim from %s (%s): upstream status %d", ip, c.dns, resp.StatusCode)
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			switch {
			case errors.Is(err, errNotLatched):
				p.stats.refuse(refState)
				log.Printf("claim from %s (%s): %v: the task is not handed to the runner", ip, c.dns, err)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			case c == nil:
				p.eventf("upstream error: %v", err)
			case connected.Load() && !bodyFailed.Load():
				// The request was sent on a connection and the answer is lost (a reset, a timeout, the runner gave up): CircleCI may have
				// handed out a task. The runner must not claim again, as for a claim that answered with a task.
				p.stats.forward(fwdError)
				p.latch(c, ip, latchUnknown)
				log.Printf("claim from %s (%s): outcome unknown (%v): latched, the runner may not claim again", ip, c.dns, err)
				p.persist() // a failure is logged, and makes the proxy refuse claims until a write works
			default:
				p.stats.forward(fwdError)
				p.eventf("claim from %s (%s): the request was not sent: %v", ip, c.dns, err)
			}
			w.WriteHeader(http.StatusBadGateway)
		},
	}).ServeHTTP(w, r)
}

// latch marks ip of class c as having claimed. The caller saves the state afterwards (persist).
func (p *proxy) latch(c *class, ip, kind string) {
	p.mu.Lock()
	c.latched[ip] = true
	delete(c.absent, ip)
	p.mu.Unlock()
	p.stats.latch(kind)
}

// checkHealth is the -healthcheck flag: the exit status of one GET of /healthz on the address that -listen names.
func checkHealth(listen string) int {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return 1
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + healthPath)
	if err != nil {
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

// newServer is the server of the proxy, with limits on what a runner network can send it.
func newServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute, // headers and body of one request: the calls that pass through carry job output
		IdleTimeout:       time.Minute,
		MaxHeaderBytes:    32 << 10,
	}
}

// serve runs srv on ln until ctx is done, then shuts it down within grace, and returns only after that: a claim that CircleCI has
// answered and that is latched must reach its runner before the process exits.
func serve(ctx context.Context, srv *http.Server, ln net.Listener, grace time.Duration) error {
	done := make(chan struct{})
	go func() {
		defer close(done)
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), grace)
		defer cancel()
		if srv.Shutdown(sctx) != nil {
			srv.Close()
		}
	}()
	if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	<-done
	return nil
}

// pollLoop polls every interval until ctx is done. A poll that fails is logged, at most once a minute.
func (p *proxy) pollLoop(ctx context.Context, interval time.Duration) {
	failing := logEvery{every: time.Minute}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := p.poll(ctx); err != nil && ctx.Err() == nil {
				failing.printf("poll: cannot resolve the runners, no latch is released: %v", err)
			}
		}
	}
}

// logEvery limits a message that repeats (every poll fails the same way) to one line for each interval.
type logEvery struct {
	every time.Duration

	mu   sync.Mutex
	last time.Time
	held int // messages since the last line, that one included
}

func (l *logEvery) printf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.held++
	if !l.last.IsZero() && time.Since(l.last) < l.every {
		return
	}
	if l.held > 1 {
		format += fmt.Sprintf(" (%d times)", l.held)
	}
	log.Printf(format, args...)
	l.last, l.held = time.Now(), 0
}

func main() {
	defaultSecrets := "/run/secrets"
	if runtime.GOOS == "windows" {
		defaultSecrets = `C:\ProgramData\Docker\secrets`
	}
	secretsDir := flag.String("secrets-dir", defaultSecrets, "the directory of the class tokens: every file <service>"+tokenSuffix+" is the class <service>, whose runners are tasks.<service> (a token file is bare or a runner config with auth_token)")
	listen, upstream := flag.String("listen", ":8080", "address to listen on"), flag.String("upstream", "https://runner.circleci.com", "the runner API")
	poll := flag.Duration("poll", time.Second, "how often to look for runners that have left")
	stateDir := flag.String("state-dir", "", "a directory of a volume that keeps the latched runner addresses across restarts (empty: none, and every restart asks CircleCI which runners may claim)")
	showVersion := flag.Bool("version", false, "print the version and exit")
	healthcheck := flag.Bool("healthcheck", false, "ask the proxy on -listen for /healthz, print nothing and exit 0 when it is healthy, else 1 (for the HEALTHCHECK of an image that has no curl)")
	flag.Parse()
	if *showVersion {
		fmt.Println("machine-runner-swarm-proxy", version)
		return
	}
	if *healthcheck {
		os.Exit(checkHealth(*listen))
	}
	u, err := url.Parse(*upstream)
	if err != nil || u.Host == "" || *poll <= 0 { // usage
		log.Fatal("usage: machine-runner-swarm-proxy [-secrets-dir DIR] [-upstream URL] [-listen ADDR] [-state-dir DIR] [-poll DURATION]")
	}
	classes, err := discoverClasses(*secretsDir)
	if err != nil {
		log.Fatalf("classes: %v", err) // fail closed: no token, no proxy
	}
	st, err := openStore(*stateDir)
	if err != nil {
		log.Fatalf("state directory: %v", err) // fail closed: a proxy that cannot keep its state does not start
	}
	p := &proxy{
		upstream: u, classes: classes, store: st, lookup: lookupHost,
		scaleTries: 3, scaleWait: 2 * time.Second, restoreDeadline: restoreWithin,
		releaseAfter: int(math.Ceil(releasePolls * float64(time.Second) / float64(*poll))),
		cacheTTL:     time.Second,
	}
	p.setDefaultLimits()
	for _, c := range classes { // fail closed: no token, no proxy
		if _, err := c.token(); err != nil {
			log.Fatalf("token file of %s: %v", c.dns, err)
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	// a restarted proxy must know who has claimed (state.go): from its state, or else it fails safe
	what, err := p.start(ctx, time.Second)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		log.Fatalf("state: %v", err) // a full disk or a permission is not mended by waiting
	}
	log.Print(what)
	go p.pollLoop(ctx, *poll)
	go p.summaryLoop(ctx, summaryEvery)
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	var names []string
	for _, c := range classes {
		names = append(names, c.dns)
	}
	log.Printf("machine-runner-swarm-proxy %s listening on %s, upstream %s, classes %s", version, *listen, u.Host, strings.Join(names, ","))
	if err := serve(ctx, newServer(*listen, p), ln, 8*time.Second); err != nil {
		log.Fatal(err)
	}
}
