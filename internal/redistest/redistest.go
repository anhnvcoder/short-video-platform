// Package redistest gives integration tests a client to the local Redis named by
// SVP_TEST_REDIS_URL and a random key prefix of their own, and deletes the keys under that
// prefix afterwards.
//
// The local Redis is shared with other projects, so it refuses every URL but db 15 of
// 127.0.0.1:6379 (or localhost:6379) before it sends a command, and it never flushes a database.
package redistest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/anhnvcoder/short-video-platform/internal/redisx"
)

// EnvURL names the variable holding the test Redis URL; `make test` sets it.
const EnvURL = "SVP_TEST_REDIS_URL"

// DB is the project's test database.
const DB = 15

var (
	// ErrNoURL means EnvURL is unset: integration tests skip.
	ErrNoURL = errors.New(EnvURL + " is not set; integration tests need the local Redis (make test sets it)")
	// ErrNotTestDB means the URL points anywhere but db 15 of the local Redis.
	ErrNotTestDB = fmt.Errorf("%s must point at 127.0.0.1:6379 or localhost:6379, db %d", EnvURL, DB)
)

var allowedAddrs = map[string]bool{"127.0.0.1:6379": true, "localhost:6379": true}

// timeout caps the connection check and the whole cleanup (a SCAN loop of many commands). A
// Redis that is down already fails the first command within the client's own limits (clientTimeout
// below), well before this.
const timeout = 10 * time.Second

// clientTimeout is the dial, read, write and pool timeout of the client New returns. Services use
// the 50 to 100 ms of redisx so a slow Redis never holds a request; a test run is not a
// request: with every package running at once under -race, a local Redis call can take longer than
// that and the test fails on timing instead of on behavior. Tests of the fallback when Redis is
// down build their own client to an address that never answers.
const clientTimeout = 5 * time.Second

// New returns a client to the test database and a fresh key prefix (svp:test:<hex>:) that the
// test must put in front of every key it writes. When t ends, the keys under the prefix are
// deleted and the client closed. Without EnvURL the test is skipped; any other URL than the
// test database fails it.
func New(t testing.TB) (*redis.Client, string) {
	t.Helper()
	rawURL := os.Getenv(EnvURL)
	if rawURL == "" {
		t.Skip(ErrNoURL.Error())
	}
	client, err := open(rawURL)
	if err != nil {
		t.Fatalf("redistest: %v", err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), timeout)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		t.Fatalf("redistest: cannot reach Redis at %s db %d: %v", client.Options().Addr, DB, err)
	}

	prefix := newPrefix()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		if err := deletePrefix(ctx, client, prefix); err != nil {
			t.Errorf("redistest: delete keys %s*: %v", prefix, err)
		}
		_ = client.Close()
	})
	return client, prefix
}

// open checks rawURL names the test database and returns a client to it, without connecting.
func open(rawURL string) (*redis.Client, error) {
	o, err := options(rawURL)
	if err != nil {
		return nil, err
	}
	return redis.NewClient(o), nil
}

// options checks rawURL names the test database and returns the options of redisx.Options (one
// attempt, context deadlines) with the timeouts of clientTimeout. They are parsed afresh: options
// copied from a built client have lost the one-attempt setting (-1 is stored as 0, which a new
// client reads as 3 retries) and carry handlers a new client cannot register again.
func options(rawURL string) (*redis.Options, error) {
	o, err := redisx.Options(rawURL)
	if err != nil {
		return nil, err
	}
	if o.Network != "tcp" || !allowedAddrs[o.Addr] || o.DB != DB {
		return nil, fmt.Errorf("%w; got %s %s db %d", ErrNotTestDB, o.Network, o.Addr, o.DB)
	}
	o.DialTimeout = clientTimeout
	o.ReadTimeout = clientTimeout
	o.WriteTimeout = clientTimeout
	o.PoolTimeout = clientTimeout
	return o, nil
}

func newPrefix() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b) // never fails (crypto/rand documentation)
	return "svp:test:" + hex.EncodeToString(b) + ":"
}

// deletePrefix deletes every key under prefix, which holds only hex digits and colons, so it
// is safe in a MATCH pattern.
func deletePrefix(ctx context.Context, client *redis.Client, prefix string) error {
	var cursor uint64
	for {
		keys, next, err := client.Scan(ctx, cursor, prefix+"*", 100).Result()
		if err != nil {
			return err
		}
		if len(keys) > 0 {
			if err := client.Unlink(ctx, keys...).Err(); err != nil {
				return err
			}
		}
		if next == 0 {
			return nil
		}
		cursor = next
	}
}
