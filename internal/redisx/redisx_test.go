package redisx

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
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

// TestOptionsFresh checks Options returns options not yet read by a client: "no retries" is
// still -1, which a client built from them keeps as one attempt.
func TestOptionsFresh(t *testing.T) {
	o, err := Options("redis://127.0.0.1:6379/10?max_retries=7")
	if err != nil {
		t.Fatalf("Options() error = %v", err)
	}
	if o.MaxRetries != -1 || o.DialerRetries != 1 || !o.ContextTimeoutEnabled || o.ReadTimeout != ReadTimeout {
		t.Errorf("MaxRetries %d, DialerRetries %d, ContextTimeoutEnabled %v, ReadTimeout %v; want -1, 1, true, %v",
			o.MaxRetries, o.DialerRetries, o.ContextTimeoutEnabled, o.ReadTimeout, ReadTimeout)
	}
	if _, err := Options("redis://127.0.0.1:6379/ten"); !errors.Is(err, ErrInvalidURL) {
		t.Errorf("Options() error = %v, want ErrInvalidURL", err)
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

// TestNoMaintenanceNotifications checks a client asks a Redis that speaks RESP3, as the local one
// does, for no maintenance notifications: that Redis rejects CLIENT MAINT_NOTIFICATIONS, and
// go-redis would send it on every new connection.
func TestNoMaintenanceNotifications(t *testing.T) {
	srv := newFakeRedis(t)
	o, err := Options("redis://" + srv.addr + "/15")
	if err != nil {
		t.Fatalf("Options() error = %v", err)
	}
	// The fake answers at once; longer timeouts keep a loaded test run from failing the handshake.
	o.DialTimeout, o.ReadTimeout, o.WriteTimeout, o.PoolTimeout = 5*time.Second, 5*time.Second, 5*time.Second, 5*time.Second
	c := redis.NewClient(o)
	t.Cleanup(func() { _ = c.Close() })
	if err := c.Ping(t.Context()).Err(); err != nil {
		t.Fatalf("Ping() error = %v", err)
	}
	got := srv.received()
	if !strings.Contains(strings.ToUpper(got), "HELLO 3") {
		t.Fatalf("the client sent %q, want a RESP3 handshake (HELLO 3)", got)
	}
	if strings.Contains(strings.ToUpper(got), "MAINT_NOTIFICATIONS") {
		t.Errorf("the client sent %q, want no CLIENT MAINT_NOTIFICATIONS", got)
	}
}

// fakeRedis answers like a local Redis: HELLO 3 with a RESP3 map, an error for CLIENT
// MAINT_NOTIFICATIONS, PONG for PING and OK for anything else. It records every command.
type fakeRedis struct {
	addr string
	mu   sync.Mutex
	cmds []string
}

func newFakeRedis(t *testing.T) *fakeRedis {
	t.Helper()
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	f := &fakeRedis{addr: ln.Addr().String()}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(conn)
		}
	}()
	return f
}

func (f *fakeRedis) serve(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	r := bufio.NewReader(conn)
	for {
		args, err := readCommand(r)
		if err != nil {
			return
		}
		cmd := strings.Join(args, " ")
		f.mu.Lock()
		f.cmds = append(f.cmds, cmd)
		f.mu.Unlock()
		reply := "+OK\r\n"
		switch upper := strings.ToUpper(cmd); {
		case strings.HasPrefix(upper, "HELLO"):
			reply = "%3\r\n+server\r\n+redis\r\n+version\r\n+8.2.0\r\n+proto\r\n:3\r\n"
		case strings.HasPrefix(upper, "CLIENT MAINT_NOTIFICATIONS"):
			reply = "-ERR unknown subcommand 'MAINT_NOTIFICATIONS'\r\n"
		case upper == "PING":
			reply = "+PONG\r\n"
		}
		if _, err := io.WriteString(conn, reply); err != nil {
			return
		}
	}
}

func (f *fakeRedis) received() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.cmds, "\n")
}

// readCommand reads one command, an array of bulk strings, as clients send them.
func readCommand(r *bufio.Reader) ([]string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return nil, err
	}
	n, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(line, "*"), "\r\n"))
	if err != nil || !strings.HasPrefix(line, "*") {
		return nil, fmt.Errorf("not an array: %q", line)
	}
	args := make([]string, n)
	for i := range args {
		header, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		size, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(header, "$"), "\r\n"))
		if err != nil {
			return nil, fmt.Errorf("not a bulk string: %q", header)
		}
		buf := make([]byte, size+2)
		if _, err := io.ReadFull(r, buf); err != nil {
			return nil, err
		}
		args[i] = string(buf[:size])
	}
	return args, nil
}
