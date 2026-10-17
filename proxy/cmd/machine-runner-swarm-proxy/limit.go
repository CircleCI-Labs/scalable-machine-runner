package main

import (
	"sync"
	"time"
)

// limiter is a token bucket for each source address: rate claims a second, with bursts of up to burst. A runner claims about every
// five seconds, so only a flood from one container goes over it.
type limiter struct {
	rate, burst float64
	now         func() time.Time

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	tokens float64
	at     time.Time
}

func newLimiter(rate, burst float64) *limiter {
	return &limiter{rate: rate, burst: burst, now: time.Now, buckets: map[string]*bucket{}}
}

// allow takes a token of ip, if it has one. A nil limiter allows everything.
func (l *limiter) allow(ip string) bool {
	if l == nil {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b := l.buckets[ip]
	if b == nil {
		b = &bucket{tokens: l.burst, at: now}
		l.buckets[ip] = b
	}
	b.tokens = min(l.burst, b.tokens+now.Sub(b.at).Seconds()*l.rate)
	b.at = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// gc forgets the addresses whose bucket has filled up again: they have not claimed for a while.
func (l *limiter) gc() {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	for ip, b := range l.buckets {
		if b.tokens+now.Sub(b.at).Seconds()*l.rate >= l.burst {
			delete(l.buckets, ip)
		}
	}
}
