package ratelimit

import (
	"sync"
	"time"
)

// sweepInterval spaces out the scans that drop expired entries from memory.
const sweepInterval = time.Minute

// memory is the in-memory GCRA of one gateway instance, used while Redis fails. It holds one
// TAT per key; an entry whose TAT has passed means the same as no entry, so a periodic sweep
// drops those and the map never grows past the keys seen within one refill time.
type memory struct {
	now func() time.Time

	mu        sync.Mutex
	tats      map[string]time.Time
	nextSweep time.Time
}

func newMemory(now func() time.Time) *memory {
	return &memory{now: now, tats: map[string]time.Time{}}
}

// allow is the same step as gcraScript, on the local clock.
func (m *memory) allow(key string, lim Limit) (bool, time.Duration) {
	now := m.now()
	m.mu.Lock()
	defer m.mu.Unlock()
	if !now.Before(m.nextSweep) {
		for k, tat := range m.tats {
			if !tat.After(now) {
				delete(m.tats, k)
			}
		}
		m.nextSweep = now.Add(sweepInterval)
	}

	interval := lim.interval()
	limit := interval * time.Duration(lim.Burst)
	tat := m.tats[key]
	if tat.Before(now) {
		tat = now
	}
	ahead := tat.Add(interval).Sub(now)
	if ahead > limit {
		return false, ahead - limit
	}
	m.tats[key] = now.Add(ahead)
	return true, 0
}
