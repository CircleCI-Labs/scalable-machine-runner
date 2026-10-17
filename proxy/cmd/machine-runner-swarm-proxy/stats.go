package main

import (
	"context"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// What a claim came to, and why a request was refused: the names that the summary line prints.
const (
	fwdTask   = "task"           // the upstream answered 2xx other than 204: a task
	fwdNone   = "no task"        // the upstream answered 204
	fwdStatus = "other status"   // the upstream answered anything else
	fwdError  = "upstream error" // no answer: the request failed on the way

	latchTask    = "task"
	latchUnknown = "unknown outcome" // the request reached the upstream and the answer was lost

	refAlready   = "already claimed"
	refInFlight  = "claim in flight"
	refNotRunner = "not a runner"
	refSeveral   = "several classes"
	refRate      = "claim rate"
	refTooLarge  = "claim too large"
	refDNS       = "cannot resolve"
	refNoToken   = "no token"
	refState     = "state cannot be written"
)

// tally counts the claims of one interval for the summary line. A nil tally counts nothing.
type tally struct {
	mu sync.Mutex
	counts
}

type counts struct {
	forwarded, latched, refused   map[string]int
	limited, overloaded, silenced int
}

func newTally() *tally {
	t := &tally{}
	t.reset()
	return t
}

func (t *tally) reset() {
	t.counts = counts{forwarded: map[string]int{}, latched: map[string]int{}, refused: map[string]int{}}
}

func (t *tally) count(f func()) {
	if t == nil {
		return
	}
	t.mu.Lock()
	f()
	t.mu.Unlock()
}

func (t *tally) forward(kind string) { t.count(func() { t.forwarded[kind]++ }) }
func (t *tally) latch(kind string)   { t.count(func() { t.latched[kind]++ }) }
func (t *tally) refuse(why string)   { t.count(func() { t.refused[why]++ }) }
func (t *tally) limit()              { t.count(func() { t.limited++ }) }
func (t *tally) overload()           { t.count(func() { t.overloaded++ }) }
func (t *tally) silence()            { t.count(func() { t.silenced++ }) }

// breakdown prints "N (a X, b Y)", with the names in order, or just "0".
func breakdown(m map[string]int) string {
	total := 0
	var parts []string
	for k, n := range m {
		total += n
		parts = append(parts, fmt.Sprintf("%s %d", k, n))
	}
	if total == 0 {
		return "0"
	}
	sort.Strings(parts)
	return fmt.Sprintf("%d (%s)", total, strings.Join(parts, ", "))
}

// summary returns the line for the interval that ends now, and starts the next one.
func (t *tally) summary(every time.Duration, stateBad bool, dnsFallbacks int64) string {
	if t == nil {
		t = newTally()
	}
	t.mu.Lock()
	cur := t.counts
	t.reset()
	t.mu.Unlock()
	line := fmt.Sprintf("summary of the last %s: claims forwarded %s, latched %s, refused %s; requests over the per-address limit %d, over capacity %d",
		every.Round(time.Second), breakdown(cur.forwarded), breakdown(cur.latched), breakdown(cur.refused), cur.limited, cur.overloaded)
	if cur.silenced > 0 {
		line += fmt.Sprintf("; %d event lines left out of the log", cur.silenced)
	}
	if dnsFallbacks > 0 {
		line += fmt.Sprintf("; %d DNS lookups fell back to the system resolver", dnsFallbacks)
	}
	if stateBad {
		line += "; the state cannot be written"
	}
	return line
}

// summaryLoop logs the summary line every interval until ctx is done: the one place that shows the counts without reading every line.
func (p *proxy) summaryLoop(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			log.Print(p.stats.summary(every, p.stateBad.Load(), dnsFallbacks.Load()))
		}
	}
}

// eventf logs a line about one request, up to a rate: a flood of refusals (or of failures upstream) would fill the log and push out the
// lines that matter after an incident (latches, releases, the restore verdict, state errors). A line that is left out is counted in
// the summary line. A proxy with no events limiter logs every line.
func (p *proxy) eventf(format string, args ...any) {
	if !p.events.allow("") {
		p.stats.silence()
		return
	}
	log.Printf(format, args...)
}

// dnsFallbacks counts the lookups that fell back to the system resolver (Windows only), which can answer from a cache.
var dnsFallbacks atomic.Int64

// fallbackNotice logs the first fall back to the system resolver and says that the next ones are counted, not logged. The summary line
// shows the count.
type fallbackNotice struct{ once sync.Once }

func (f *fallbackNotice) note(host string, err error) {
	dnsFallbacks.Add(1)
	f.once.Do(func() {
		log.Printf("DNS: the query for %s failed (%v): using the system resolver, whose answers can be out of date; later fall backs are counted in the summary line, not logged", host, err)
	})
}
