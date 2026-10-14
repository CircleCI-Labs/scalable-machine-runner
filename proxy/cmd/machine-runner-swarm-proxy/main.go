// machine-runner-swarm-proxy keeps the CircleCI resource class tokens off machine runner containers on Docker Swarm.
//
// Runners point CIRCLECI_RUNNER_API_URL at this proxy and hold only a placeholder token. The proxy adds the
// class token to the task-claim call and to nothing else; every other call passes through untouched, because
// the runner and its task agent send the task-scoped token from the claim response themselves.
//
// One proxy serves every class of a stack. Each -class SERVICE=TOKEN-FILE pair names the DNS name of the runner
// containers of one class (tasks.<service>, on the class overlay network) and the file with that class's token.
// A claim is allowed only from an IP that is currently in the DNS answer of a class, and it gets that class's token.
//
// One claim per runner container: after a claim that returns a task, that IP is latched and further claims from it
// get 403 until the IP leaves the DNS answer (the container is gone). Single-task mode only: a continuous runner claims
// many times.
//
// A restarted proxy must know who has claimed. With -state-dir it keeps the latched IPs in a small file of a volume,
// written before the claim's answer goes back to the runner, and a restart with that state refuses only the IPs that
// really claimed. Without a state file the proxy cannot know, so it asks the directory: a directory that was never
// used is a first start and allows every runner (they cannot have claimed through this proxy); a directory with a
// marker but no usable state has lost it, and the proxy fails safe and latches every IP present, like a proxy without
// -state-dir does. See state.go.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	claimPath  = "/api/v3/runner/claim"
	healthPath = "/healthz"
	// classEnvPrefix: every environment variable with this prefix holds one -class value. Stack files merge
	// environment variables by name but replace a command, so an add-on stack file adds its class this way.
	classEnvPrefix = "MACHINE_RUNNER_SWARM_PROXY_CLASS_"
)

var version = "dev" // -ldflags "-X main.version=..."

// A token file is either the bare token or a runner config with an auth_token line (the Swarm secret format).
var tokenLine = regexp.MustCompile(`(?m)^\s*auth_token:\s*["']?([^"'\s]+)`)

// class is one resource class: the runner containers of a Swarm service and the file with the token they claim with.
type class struct {
	dns       string // tasks.<service>: the IPs of the runner containers
	tokenFile string

	latched map[string]bool // runner IPs that have claimed a task
	busy    map[string]bool // runner IPs with a claim in flight
}

func newClass(service, tokenFile string) *class {
	if !strings.HasPrefix(service, "tasks.") {
		service = "tasks." + service
	}
	return &class{dns: service, tokenFile: tokenFile, latched: map[string]bool{}, busy: map[string]bool{}}
}

type proxy struct {
	upstream *url.URL
	classes  []*class
	lookup   func(ctx context.Context, host string) ([]string, error)

	store    *store // nil: no persistence, a restart latches every runner present
	stateErr error  // the last failure to write the state, which makes the proxy unhealthy

	mu sync.Mutex // guards the latched and busy maps of every class, and the state file
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

// resolve returns the runner IPs of every class. An unknown name (no running task) is an empty set; any other DNS failure is an error
// and changes nothing.
func (p *proxy) resolve(ctx context.Context) (map[*class]map[string]bool, error) {
	sets := map[*class]map[string]bool{}
	for _, c := range p.classes {
		addrs, err := p.lookup(ctx, c.dns)
		var dnsErr *net.DNSError
		if err != nil && !(errors.As(err, &dnsErr) && dnsErr.IsNotFound) {
			return nil, fmt.Errorf("%s: %w", c.dns, err)
		}
		set := map[string]bool{}
		for _, a := range addrs {
			set[norm(a)] = true
		}
		sets[c] = set
	}
	return sets, nil
}

// members resolves the runner IPs of every class and releases the latch of every IP that has left.
func (p *proxy) members(ctx context.Context) (map[*class]map[string]bool, error) {
	sets, err := p.resolve(ctx)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	changed := false
	for c, set := range sets {
		for ip := range c.latched {
			if !set[ip] {
				delete(c.latched, ip)
				changed = true
				log.Printf("released %s (%s)", ip, c.dns)
			}
		}
	}
	if changed {
		p.persist()
	}
	return sets, nil
}

// restore sets the latches at start: from the state file when there is a usable one (the IPs that claimed and are still there), else
// by the rules in the package comment. It returns what it did, for the log.
func (p *proxy) restore(ctx context.Context, noState string) (string, error) {
	sets, err := p.resolve(ctx)
	if err != nil {
		return "", err
	}
	kind, saved, err := p.store.load()
	if err != nil {
		return "", err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	latchAll := func() int {
		n := 0
		for c, set := range sets {
			for ip := range set {
				c.latched[ip] = true
				n++
			}
		}
		return n
	}
	var what string
	switch {
	case kind == stateOK:
		n := 0
		for c, set := range sets {
			for _, ip := range saved[c.dns] {
				if set[ip] {
					c.latched[ip] = true
					n++
				}
			}
		}
		what = fmt.Sprintf("state restored: %d runner(s) have claimed and stay refused; the others may claim", n)
	case kind == stateNone && noState == noStateAllow:
		what = "no state: a first start, so no runner has claimed through this proxy and every runner present may claim"
	case kind == stateNone:
		what = fmt.Sprintf("no state and -no-state latch: latching all %d runner(s) present", latchAll())
	case kind == stateLost:
		what = fmt.Sprintf("state lost: failing safe, latching all %d runner(s) present", latchAll())
	default: // no store: nothing persists, and a restart cannot know who claimed
		what = fmt.Sprintf("no state directory: latching all %d runner(s) present", latchAll())
	}
	if err := p.store.save(p.classes); err != nil {
		return "", err
	}
	return what, nil
}

// persist writes the latched IPs to the state directory, if there is one. The caller holds p.mu.
func (p *proxy) persist() {
	if err := p.store.save(p.classes); err != nil {
		p.stateErr = err
		log.Printf("state: cannot write it: %v", err)
		return
	}
	p.stateErr = nil
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == healthPath {
		p.health(w)
		return
	}
	if r.Method != http.MethodPost || r.URL.Path != claimPath {
		p.forward(w, r, "", nil, "")
		return
	}
	ap, _ := netip.ParseAddrPort(r.RemoteAddr)
	ip := ap.Addr().Unmap().String()
	sets, err := p.members(r.Context())
	if err != nil {
		log.Printf("claim from %s refused: cannot resolve the runners: %v", ip, err)
		http.Error(w, "cannot resolve the runners", http.StatusServiceUnavailable)
		return
	}
	var c *class
	p.mu.Lock()
	why := ""
	owners := 0
	for _, k := range p.classes {
		if sets[k][ip] {
			owners++
			c = k
		}
	}
	switch {
	case owners == 0:
		why = "not a runner of any class (" + describe(p.classes, sets) + ")"
	case owners > 1: // overlapping networks: do not guess whose token this is
		why = "the address belongs to several classes"
	case c.latched[ip]:
		why = "this runner has already claimed a task"
	case c.busy[ip]:
		why = "a claim from this runner is in flight"
	default:
		c.busy[ip] = true
	}
	p.mu.Unlock()
	if why != "" {
		log.Printf("claim from %s refused: %s", ip, why)
		http.Error(w, "claim refused: "+why, http.StatusForbidden)
		return
	}
	defer func() { p.mu.Lock(); delete(c.busy, ip); p.mu.Unlock() }()
	if tok, err := c.token(); err != nil {
		log.Printf("claim from %s (%s) failed: %v", ip, c.dns, err)
		http.Error(w, "no token", http.StatusServiceUnavailable)
	} else {
		p.forward(w, r, tok, c, ip)
	}
}

// health answers 200 when every class has a usable token file. It never says which class or why.
func (p *proxy) health(w http.ResponseWriter) {
	p.mu.Lock()
	stateErr := p.stateErr
	p.mu.Unlock()
	if stateErr != nil {
		http.Error(w, "unhealthy", http.StatusServiceUnavailable)
		return
	}
	for _, c := range p.classes {
		if _, err := c.token(); err != nil {
			log.Printf("health: %s: %v", c.dns, err)
			http.Error(w, "unhealthy", http.StatusServiceUnavailable)
			return
		}
	}
	fmt.Fprintln(w, "ok")
}

// forward proxies r upstream. With tok set it adds the bearer token; with c and ip set a task in the response latches ip.
func (p *proxy) forward(w http.ResponseWriter, r *http.Request, tok string, c *class, ip string) {
	(&httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(p.upstream)
			if tok != "" {
				pr.Out.Header.Set("Authorization", "Bearer "+tok)
			}
			if ua := pr.Out.UserAgent(); ua != "" { // tell CircleCI which requests came through this proxy
				pr.Out.Header.Set("User-Agent", ua+" machine-runner-swarm-proxy/"+version)
			}
		},
		ModifyResponse: func(resp *http.Response) error {
			if c != nil {
				log.Printf("claim from %s (%s): upstream status %d", ip, c.dns, resp.StatusCode)
				if resp.StatusCode/100 == 2 && resp.StatusCode != http.StatusNoContent { // 204: no task yet
					p.mu.Lock()
					c.latched[ip] = true
					p.persist() // before the runner gets its task: a restart must know that it has claimed
					p.mu.Unlock()
				}
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			log.Printf("upstream error: %v", err)
			w.WriteHeader(http.StatusBadGateway)
		},
	}).ServeHTTP(w, r)
}

// classFlags collects -class SERVICE=TOKEN-FILE (repeatable).
type classFlags []string

func (f *classFlags) String() string     { return strings.Join(*f, ",") }
func (f *classFlags) Set(v string) error { *f = append(*f, v); return nil }

// parseClasses builds the classes from the -class values and from the MACHINE_RUNNER_SWARM_PROXY_CLASS_* variables of env.
func parseClasses(flagValues, env []string) ([]*class, error) {
	specs := append([]string{}, flagValues...)
	var fromEnv []string
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok && strings.HasPrefix(k, classEnvPrefix) && v != "" {
			fromEnv = append(fromEnv, v)
		}
	}
	sort.Strings(fromEnv)
	specs = append(specs, fromEnv...)
	var classes []*class
	seen := map[string]bool{}
	for _, s := range specs {
		service, file, ok := strings.Cut(s, "=")
		if !ok || strings.TrimSpace(service) == "" || strings.TrimSpace(file) == "" {
			return nil, fmt.Errorf("class %q: want SERVICE=TOKEN-FILE", s)
		}
		c := newClass(strings.TrimSpace(service), strings.TrimSpace(file))
		if seen[c.dns] {
			return nil, fmt.Errorf("class %s is given twice", c.dns)
		}
		seen[c.dns] = true
		classes = append(classes, c)
	}
	if len(classes) == 0 {
		return nil, errors.New("no class")
	}
	return classes, nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	var cf classFlags
	flag.Var(&cf, "class", "SERVICE=TOKEN-FILE: the runner service of one resource class (tasks.<service> is resolved) and the file with its token, bare or a runner config with auth_token (repeatable; also "+classEnvPrefix+"* variables)")
	listen, upstream := flag.String("listen", ":8080", "address to listen on"), flag.String("upstream", "https://runner.circleci.com", "the runner API")
	poll := flag.Duration("poll", time.Second, "how often to look for runners that have left")
	stateDir := flag.String("state-dir", "", "a directory of a volume that keeps the latched runner addresses across restarts (empty: none, and a restart latches every runner present)")
	noState := flag.String("no-state", envOr("MACHINE_RUNNER_SWARM_PROXY_NO_STATE", noStateAllow), "a start with a state directory that was never used: allow (a first start: no runner has claimed) or latch (every runner present counts as having claimed). Also MACHINE_RUNNER_SWARM_PROXY_NO_STATE")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("machine-runner-swarm-proxy", version)
		return
	}
	u, err := url.Parse(*upstream)
	classes, cerr := parseClasses(cf, os.Environ())
	if err != nil || u.Host == "" || cerr != nil || (*noState != noStateAllow && *noState != noStateLatch) { // usage
		if cerr != nil {
			log.Print(cerr)
		}
		log.Fatal("usage: machine-runner-swarm-proxy -class <service>=<token-file> [-class ...] [-upstream URL] [-listen ADDR] [-state-dir DIR [-no-state allow|latch]]")
	}
	st, err := openStore(*stateDir)
	if err != nil {
		log.Fatalf("state directory: %v", err) // fail closed: a proxy that cannot keep its state does not start
	}
	p := &proxy{upstream: u, classes: classes, store: st,
		lookup: lookupHost}
	for _, c := range classes { // fail closed: no token, no proxy
		if _, err := c.token(); err != nil {
			log.Fatalf("token file of %s: %v", c.dns, err)
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	// a restarted proxy must know who has claimed (state.go): from its state, or else it fails safe
	for {
		what, err := p.restore(ctx, *noState)
		if err == nil {
			log.Print(what)
			break
		}
		if ctx.Err() != nil {
			return
		}
		log.Printf("waiting for DNS: %v", err)
		time.Sleep(time.Second)
	}
	go func() {
		for range time.Tick(*poll) {
			p.members(ctx)
		}
	}()
	srv := &http.Server{Addr: *listen, Handler: p, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if srv.Shutdown(sctx) != nil {
			srv.Close()
		}
	}()
	var names []string
	for _, c := range classes {
		names = append(names, c.dns)
	}
	log.Printf("machine-runner-swarm-proxy %s listening on %s, upstream %s, classes %s", version, *listen, u.Host, strings.Join(names, ","))
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
