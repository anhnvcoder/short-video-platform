// Package redisx builds the Redis client every service uses, with the short timeouts of
// docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 1.
//
// Every use of Redis has a fallback, so a call must fail fast rather than wait: New neither
// pings nor retries, and a service starts while Redis is down.
package redisx

import (
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

// Timeouts of ADR-0010, section 1.
const (
	DialTimeout  = 100 * time.Millisecond
	ReadTimeout  = 50 * time.Millisecond
	WriteTimeout = 50 * time.Millisecond
	PoolTimeout  = 50 * time.Millisecond
)

// ErrInvalidURL means the URL could not be parsed. It never carries the URL, which may hold a
// password.
var ErrInvalidURL = errors.New("redisx: invalid Redis URL; want redis://[user:password@]host:port/db, or rediss:// for TLS")

// New returns a client for rawURL (redis://host:port/db, or rediss:// for TLS). It does not
// connect: the first command does. Timeouts set in the URL's query are overridden.
func New(rawURL string) (*redis.Client, error) {
	opts, err := redis.ParseURL(rawURL)
	if err != nil {
		// The parse error may quote the URL, password included: drop it.
		return nil, ErrInvalidURL
	}
	opts.DialTimeout = DialTimeout
	opts.ReadTimeout = ReadTimeout
	opts.WriteTimeout = WriteTimeout
	opts.PoolTimeout = PoolTimeout
	opts.ContextTimeoutEnabled = true
	// go-redis retries a failed command 3 times and a failed dial 5 times, with backoff; with
	// Redis down that turns one call into seconds. One attempt keeps a call within the budget
	// above; callers that want a retry make it themselves.
	opts.MaxRetries = -1
	opts.DialerRetries = 1
	return redis.NewClient(opts), nil
}
