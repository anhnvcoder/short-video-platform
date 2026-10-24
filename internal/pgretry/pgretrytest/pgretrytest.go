// Package pgretrytest gives the tests of the startup retries (internal/pgpool,
// internal/dbmigrate, internal/pgretry) the unreachable databases they need: a refused port, a
// server that never answers, a proxy that cuts connections before it forwards them, and a capture
// of slog's default logger. It does not import internal/pgtest, which imports internal/dbmigrate.
package pgretrytest

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"
)

// ClosedPort returns the address of a port the test opened then closed: connections to it are
// refused.
func ClosedPort(t *testing.T) string {
	t.Helper()
	ln := listen(t)
	addr := ln.Addr().String()
	_ = ln.Close()
	return addr
}

// Blackhole returns the address of a listener that accepts connections and never answers, like
// a host whose Postgres hangs.
func Blackhole(t *testing.T) string {
	t.Helper()
	ln := listen(t)
	done := make(chan struct{})
	var conns []net.Conn
	go func() {
		defer close(done)
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			conns = append(conns, c)
		}
	}()
	t.Cleanup(func() {
		_ = ln.Close()
		<-done
		for _, c := range conns {
			_ = c.Close()
		}
	})
	return ln.Addr().String()
}

// DelayedProxy returns the address of a listener that closes every connection it accepts during
// the first delay, like a Postgres whose network path is not open yet, then forwards connections
// to target. The listener stays open from the start, so no other process can take its port, and
// the first attempt fails for sure.
func DelayedProxy(t *testing.T, target string, delay time.Duration) string {
	t.Helper()
	ln := listen(t)
	readyAt := time.Now().Add(delay)
	var (
		mu     sync.Mutex
		conns  []net.Conn
		closed bool
		wg     sync.WaitGroup
	)
	wg.Go(func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			if time.Now().Before(readyAt) {
				_ = c.Close()
				continue
			}
			var d net.Dialer
			up, err := d.DialContext(context.Background(), "tcp", target)
			if err != nil {
				_ = c.Close()
				continue
			}
			mu.Lock()
			if closed {
				mu.Unlock()
				_ = c.Close()
				_ = up.Close()
				return
			}
			conns = append(conns, c, up)
			mu.Unlock()
			wg.Go(func() { _, _ = io.Copy(up, c); _ = up.Close() })
			wg.Go(func() { _, _ = io.Copy(c, up); _ = c.Close() })
		}
	})
	t.Cleanup(func() {
		mu.Lock()
		closed = true
		_ = ln.Close()
		for _, c := range conns {
			_ = c.Close()
		}
		mu.Unlock()
		wg.Wait()
	})
	return ln.Addr().String()
}

func listen(t *testing.T) net.Listener {
	t.Helper()
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return ln
}

// LockedBuffer collects log output; pgx and goose may log from other goroutines.
type LockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *LockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *LockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// CaptureDefaultLog points slog's default logger at a JSON buffer for the rest of the test, so
// the test must not run in parallel.
func CaptureDefaultLog(t *testing.T) *LockedBuffer {
	t.Helper()
	buf := &LockedBuffer{}
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return buf
}
