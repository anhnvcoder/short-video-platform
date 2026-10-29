package sentryx

import (
	"sync"
	"time"
)

type fingerprint struct{ service, message, route, kind string }

type limiter struct {
	mu      sync.Mutex
	sent    []time.Time
	last    map[fingerprint]time.Time
	warned  time.Time
	dropped uint64
	// flushing is set once a flush of the drops counted since warned is due.
	flushing bool
}

// allow reports whether the event key may be sent at now, and counts it when it may not. The
// first drop after a minute without a report is reported at once, in dropped. Later drops within
// that minute are kept for flush: the first of them returns flushIn, the delay after which the
// caller must call flush, so the tail of a burst is reported even when no event follows it.
func (l *limiter) allow(now time.Time, key fingerprint) (allowed bool, dropped uint64, flushIn time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for len(l.sent) > 0 && now.Sub(l.sent[0]) >= time.Minute {
		l.sent = l.sent[1:]
	}
	for k, at := range l.last {
		if now.Sub(at) >= 30*time.Second {
			delete(l.last, k)
		}
	}
	if _, duplicate := l.last[key]; !duplicate && len(l.sent) < 60 {
		if l.last == nil {
			l.last = make(map[fingerprint]time.Time)
		}
		l.last[key] = now
		l.sent = append(l.sent, now)
		return true, 0, 0
	}
	l.dropped++
	if l.warned.IsZero() || now.Sub(l.warned) >= time.Minute {
		dropped, l.dropped, l.warned = l.dropped, 0, now
		return false, dropped, 0
	}
	if !l.flushing {
		l.flushing = true
		// Callers read the clock before they wait for the lock, so now can be earlier than a
		// warning recorded meanwhile by another caller. Counting from now would add that wait to
		// the delay and push the flush past a minute after the warning.
		from := now
		if from.Before(l.warned) {
			from = l.warned
		}
		return false, 0, l.warned.Add(time.Minute).Sub(from)
	}
	return false, 0, 0
}

// flush returns the drops counted and not reported yet, and starts the minute of the next report
// at now when there were any.
func (l *limiter) flush(now time.Time) (dropped uint64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.flushing = false
	if l.dropped != 0 {
		dropped, l.dropped, l.warned = l.dropped, 0, now
	}
	return dropped
}
