// Package pgretrytest gives the tests of database connections (the startup retries of
// internal/pgpool, internal/dbmigrate and internal/pgretry, and services that must fail fast on a
// slow or lost database) the unreachable or slow databases they need: a refused port, a server
// that never answers, a proxy that cuts connections before it forwards them, a proxy that delays
// every byte and cuts connections on the test's command, and a capture of slog's default logger.
// It does not import internal/pgtest, which imports internal/dbmigrate.
package pgretrytest

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
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

// Proxy forwards connections to a target, each chunk of bytes held back by a delay in each
// direction, and cuts them when the test says so. Every connection it accepts is forwarded: the
// delay, not a refusal, is what makes the database slow.
type Proxy struct {
	addr     string
	delay    atomic.Int64 // time.Duration
	accepted atomic.Int64

	mu       sync.Mutex
	conns    map[*proxyConn]struct{}
	cutAfter func([]byte) bool
	closed   bool
}

// proxyConn is one forwarded connection: the client's side and the target's. closed is closed
// with them.
type proxyConn struct {
	client, up net.Conn
	once       sync.Once
	closed     chan struct{}
}

func (c *proxyConn) close() {
	c.once.Do(func() {
		_ = c.client.Close()
		_ = c.up.Close()
		close(c.closed)
	})
}

// LatencyProxy returns a Proxy to target that delays every chunk by delay each way, so a round
// trip through it takes at least 2*delay. Bytes keep their order and the delay does not limit
// throughput: chunks read meanwhile are on their way too.
func LatencyProxy(t *testing.T, target string, delay time.Duration) *Proxy {
	t.Helper()
	ln := listen(t)
	p := &Proxy{addr: ln.Addr().String(), conns: map[*proxyConn]struct{}{}}
	p.delay.Store(int64(delay))
	var wg sync.WaitGroup
	wg.Go(func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			p.accepted.Add(1)
			var d net.Dialer
			up, err := d.DialContext(context.Background(), "tcp", target)
			if err != nil {
				_ = c.Close()
				continue
			}
			pc := &proxyConn{client: c, up: up, closed: make(chan struct{})}
			p.mu.Lock()
			if p.closed {
				p.mu.Unlock()
				pc.close()
				return
			}
			p.conns[pc] = struct{}{}
			p.mu.Unlock()
			wg.Go(func() { p.forward(pc, c, up, true) })
			wg.Go(func() { p.forward(pc, up, c, false) })
		}
	})
	t.Cleanup(func() {
		p.mu.Lock()
		p.closed = true
		_ = ln.Close()
		for pc := range p.conns {
			pc.close()
		}
		p.mu.Unlock()
		wg.Wait()
	})
	return p
}

// Addr returns the host:port the proxy listens on.
func (p *Proxy) Addr() string { return p.addr }

// SetDelay changes the delay of the chunks read from now on, on every connection.
func (p *Proxy) SetDelay(d time.Duration) { p.delay.Store(int64(d)) }

// Accepted returns how many connections the proxy has accepted.
func (p *Proxy) Accepted() int64 { return p.accepted.Load() }

// CutAll closes every connection open now, both sides; later connections are forwarded as usual.
func (p *Proxy) CutAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for pc := range p.conns {
		pc.close()
		delete(p.conns, pc)
	}
}

// CutAfter makes the proxy close a connection, both sides, right after it has forwarded to the
// target a chunk from the client for which match returns true: the target got the request, the
// client never gets the answer. It applies once, to the first such chunk on any connection.
func (p *Proxy) CutAfter(match func(chunk []byte) bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.cutAfter = match
}

// chunk is bytes read from one side, due on the other side at due.
type chunk struct {
	data []byte
	due  time.Time
}

// forward copies src to dst, each chunk written once its delay has passed, until either side
// fails; then it closes the connection. toTarget says src is the client.
func (p *Proxy) forward(pc *proxyConn, src, dst net.Conn, toTarget bool) {
	defer func() {
		pc.close()
		p.mu.Lock()
		delete(p.conns, pc)
		p.mu.Unlock()
	}()
	chunks := make(chan chunk, 1024)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for c := range chunks {
			timer := time.NewTimer(time.Until(c.due))
			select {
			case <-timer.C:
			case <-pc.closed:
				timer.Stop()
				return
			}
			if _, err := dst.Write(c.data); err != nil {
				pc.close()
				return
			}
			if toTarget && p.takeCut(c.data) {
				pc.close()
				return
			}
		}
	}()
	buf := make([]byte, 32<<10)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			select {
			case chunks <- chunk{data: bytes.Clone(buf[:n]), due: time.Now().Add(time.Duration(p.delay.Load()))}:
			case <-done:
			}
		}
		if err != nil {
			break
		}
	}
	close(chunks)
	<-done
}

// takeCut reports whether data matches the armed CutAfter, disarming it when it does.
func (p *Proxy) takeCut(data []byte) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cutAfter == nil || !p.cutAfter(data) {
		return false
	}
	p.cutAfter = nil
	return true
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
