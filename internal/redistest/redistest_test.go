package redistest

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/anhnvcoder/short-video-platform/internal/redisx"
)

func TestOpenRejectsAllButTestDB(t *testing.T) {
	const secret = "s3cret-pw"
	tests := []struct {
		name string
		url  string
	}{
		{name: "db 0", url: "redis://127.0.0.1:6379/0"},
		{name: "db 5", url: "redis://127.0.0.1:6379/5"},
		{name: "db 7", url: "redis://127.0.0.1:6379/7"},
		{name: "gateway db 10", url: "redis://127.0.0.1:6379/10"},
		{name: "no db", url: "redis://127.0.0.1:6379"},
		{name: "db 15 overridden by query", url: "redis://127.0.0.1:6379/15?db=0"},
		{name: "other host", url: "redis://10.0.0.1:6379/15"},
		{name: "compose host", url: "redis://host.docker.internal:6379/15"},
		{name: "other port", url: "redis://127.0.0.1:6380/15"},
		{name: "unix socket", url: "unix:///tmp/redis.sock?db=15"},
		{name: "password not echoed", url: "redis://svp:" + secret + "@10.0.0.1:6379/15"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, err := open(tt.url)
			if err == nil {
				_ = c.Close()
				t.Fatal("open() error = nil, want ErrNotTestDB")
			}
			if !errors.Is(err, ErrNotTestDB) {
				t.Errorf("open() error = %v, want ErrNotTestDB", err)
			}
			if strings.Contains(err.Error(), secret) {
				t.Errorf("error %q leaks the password", err)
			}
		})
	}
}

func TestOpenInvalidURL(t *testing.T) {
	_, err := open("redis://127.0.0.1:6379/fifteen")
	if !errors.Is(err, redisx.ErrInvalidURL) {
		t.Errorf("open() error = %v, want redisx.ErrInvalidURL", err)
	}
}

func TestOpenAcceptsTestDB(t *testing.T) {
	for _, u := range []string{
		"redis://127.0.0.1:6379/15",
		"redis://localhost:6379/15",
		"redis://127.0.0.1/15",
	} {
		t.Run(u, func(t *testing.T) {
			c, err := open(u)
			if err != nil {
				t.Fatalf("open() error = %v", err)
			}
			_ = c.Close()
		})
	}
}

// TestNewDeletesOnlyItsOwnKeys runs against the local Redis: a nested test writes more keys
// than one SCAN page under its prefix; when it ends they are gone and the keys under the outer
// test's prefix are still there.
func TestNewDeletesOnlyItsOwnKeys(t *testing.T) {
	outer, outerPrefix := New(t)
	// The test's own commands go through a client with long timeouts: under -race with every
	// package running at once, 250 SETs can miss the 50 ms write timeout of redisx.
	setup := patientClient(t, outer)
	ctx := t.Context()
	outerKey := outerPrefix + "kept"
	if err := setup.Set(ctx, outerKey, "1", time.Minute).Err(); err != nil {
		t.Fatalf("SET: %v", err)
	}

	var innerPrefix string
	t.Run("inner", func(t *testing.T) {
		_, prefix := New(t)
		innerPrefix = prefix
		if prefix == outerPrefix || !strings.HasPrefix(prefix, "svp:test:") {
			t.Fatalf("prefix %q, outer prefix %q: want a distinct svp:test: prefix", prefix, outerPrefix)
		}
		pipe := setup.Pipeline()
		for i := range 250 {
			pipe.Set(ctx, fmt.Sprintf("%sk%d", prefix, i), "1", time.Minute)
		}
		if _, err := pipe.Exec(ctx); err != nil {
			t.Fatalf("SET: %v", err)
		}
	})

	// KEYS walks the whole database in one call; fine on the small test database.
	left, err := setup.Keys(ctx, innerPrefix+"*").Result()
	if err != nil {
		t.Fatalf("KEYS: %v", err)
	}
	if len(left) != 0 {
		t.Errorf("%d keys under %s left after the test, want 0", len(left), innerPrefix)
	}
	if n, err := setup.Exists(ctx, outerKey).Result(); err != nil || n != 1 {
		t.Errorf("EXISTS %s = %d, %v; want 1, nil", outerKey, n, err)
	}
}

// patientClient returns a client to the same database as c, already checked by New, with
// timeouts of seconds instead of the milliseconds of redisx. It is closed when t ends, before
// the cleanup of New runs.
func patientClient(t *testing.T, c *redis.Client) *redis.Client {
	t.Helper()
	o := *c.Options()
	o.DialTimeout = 5 * time.Second
	o.ReadTimeout = 5 * time.Second
	o.WriteTimeout = 5 * time.Second
	o.PoolTimeout = 5 * time.Second
	p := redis.NewClient(&o)
	t.Cleanup(func() { _ = p.Close() })
	return p
}
