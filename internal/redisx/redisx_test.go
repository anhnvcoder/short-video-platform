package redisx

import (
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

func TestNewValid(t *testing.T) {
	tests := []struct {
		name     string
		url      string
		wantAddr string
		wantDB   int
		wantTLS  bool
	}{
		{name: "host port db", url: "redis://127.0.0.1:6379/10", wantAddr: "127.0.0.1:6379", wantDB: 10},
		{name: "default port and db", url: "redis://localhost", wantAddr: "localhost:6379", wantDB: 0},
		{name: "compose host", url: "redis://host.docker.internal:6379/14", wantAddr: "host.docker.internal:6379", wantDB: 14},
		{name: "tls with password", url: "rediss://svp:s3cret@cache.example.com:6380/1", wantAddr: "cache.example.com:6380", wantDB: 1, wantTLS: true}, //nolint:gosec // a made-up password
		{name: "query timeouts overridden", url: "redis://127.0.0.1:6379/10?dial_timeout=5s&read_timeout=5s&max_retries=7", wantAddr: "127.0.0.1:6379", wantDB: 10},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, err := New(tt.url)
			if err != nil {
				t.Fatalf("New() error = %v", err)
			}
			t.Cleanup(func() { _ = c.Close() })
			o := c.Options()
			if o.Addr != tt.wantAddr || o.DB != tt.wantDB {
				t.Errorf("Addr, DB = %q, %d, want %q, %d", o.Addr, o.DB, tt.wantAddr, tt.wantDB)
			}
			if (o.TLSConfig != nil) != tt.wantTLS {
				t.Errorf("TLS = %v, want %v", o.TLSConfig != nil, tt.wantTLS)
			}
			if o.DialTimeout != DialTimeout || o.ReadTimeout != ReadTimeout || o.WriteTimeout != WriteTimeout || o.PoolTimeout != PoolTimeout {
				t.Errorf("timeouts dial %v read %v write %v pool %v, want %v %v %v %v",
					o.DialTimeout, o.ReadTimeout, o.WriteTimeout, o.PoolTimeout, DialTimeout, ReadTimeout, WriteTimeout, PoolTimeout)
			}
			if !o.ContextTimeoutEnabled {
				t.Error("ContextTimeoutEnabled = false, want true")
			}
			// go-redis stores "no retries" (-1) as 0 once the client is built.
			if o.MaxRetries != 0 || o.DialerRetries != 1 {
				t.Errorf("MaxRetries, DialerRetries = %d, %d, want 0, 1", o.MaxRetries, o.DialerRetries)
			}
		})
	}
}

func TestNewInvalidHidesURL(t *testing.T) {
	const secret = "s3cret-pw"
	tests := []struct {
		name string
		url  string
	}{
		{name: "empty", url: ""},
		{name: "wrong scheme", url: "http://svp:" + secret + "@127.0.0.1:6379/10"},
		{name: "db not a number", url: "redis://svp:" + secret + "@127.0.0.1:6379/ten"},
		{name: "unknown option", url: "redis://svp:" + secret + "@127.0.0.1:6379/10?bogus=1"},
		{name: "unparsable", url: "redis://svp:" + secret + "@[::1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, err := New(tt.url)
			if err == nil {
				_ = c.Close()
				t.Fatal("New() error = nil, want an error")
			}
			if !errors.Is(err, ErrInvalidURL) {
				t.Errorf("New() error = %v, want ErrInvalidURL", err)
			}
			if strings.Contains(err.Error(), secret) {
				t.Errorf("error %q leaks the password", err)
			}
		})
	}
}

// TestDownFailsFast checks a command to a Redis that refuses connections fails at once instead
// of retrying with backoff.
func TestDownFailsFast(t *testing.T) {
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	c, err := New("redis://" + addr + "/15")
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	start := time.Now()
	if err := c.Ping(t.Context()).Err(); err == nil {
		t.Fatal("Ping() error = nil, want a connection error")
	}
	if d := time.Since(start); d > 2*DialTimeout {
		t.Errorf("Ping() took %v, want under %v", d, 2*DialTimeout)
	}
}
