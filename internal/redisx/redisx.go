// Package redisx builds the Redis client every service uses, with the short timeouts of
// docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 1.
//
// Every use of Redis has a fallback, so a call must fail fast rather than wait: New neither
// pings nor retries, and a service starts while Redis is down.
package redisx

import (
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/extra/redisotel/v9"
	"github.com/redis/go-redis/v9"
	"github.com/redis/go-redis/v9/maintnotifications"
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

// New returns a client for rawURL (redis://host:port/db, or rediss:// for TLS) with the options
// of Options. It does not connect: the first command does.
//
// Every command and pipeline gets a span from the global tracer provider (a root span when the
// context has none) named after the command only: spans never carry the command's keys or
// arguments, which hold hashed emails and IPs (docs/adr/0011-observability-stage3.md, section 2).
// Pool statistics and connection times (db.client.connections.*) go to the global meter provider.
func New(rawURL string) (*redis.Client, error) {
	opts, err := Options(rawURL)
	if err != nil {
		return nil, err
	}
	c := redis.NewClient(opts)
	if err := redisotel.InstrumentTracing(c, redisotel.WithDBStatement(false)); err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("redisx: instrument tracing: %w", err)
	}
	if err := redisotel.InstrumentMetrics(c); err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("redisx: instrument metrics: %w", err)
	}
	return c, nil
}

// Options parses rawURL into fresh options with the timeouts above, deadlines taken from the
// context, and one attempt per command. Timeouts and retries set in the URL's query are
// overridden.
func Options(rawURL string) (*redis.Options, error) {
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
	// Maintenance notifications are a feature of Redis Enterprise and Redis Cloud. The local Redis
	// rejects the CLIENT MAINT_NOTIFICATIONS that go-redis sends on every new connection by
	// default, and each rejection shows up as a failed span.
	opts.MaintNotificationsConfig = &maintnotifications.Config{Mode: maintnotifications.ModeDisabled}
	return opts, nil
}
