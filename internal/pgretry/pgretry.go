// Package pgretry retries the first connection to Postgres at startup while the database is not
// reachable over the network, for a bounded time. internal/pgpool (service pools) and
// internal/dbmigrate (migrate Jobs) both use it, so that the errors retried, the waits and the
// log lines stay the same in both (docs/adr/0020-reliability-stage6.md, section 11). It imports
// neither of them, nor internal/pgtest, which imports internal/dbmigrate.
package pgretry

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// Window bounds the first connection with its retries. A new pod can be refused by a Postgres
// that is up for its first seconds (on k3d, until the network policy covers the pod's address):
// retrying for a while connects it instead of restarting it. 30 s stays under the 60 s startup
// probe of the gRPC services, so the kubelet does not kill a pod that is still retrying.
const Window = 30 * time.Second

// Waits between two connection attempts: the first one, doubled after each failure up to the
// last one.
const (
	firstRetryWait = 250 * time.Millisecond
	maxRetryWait   = 2 * time.Second
)

// Connect calls connect until it succeeds, fails with an error Retryable does not accept, or ctx
// ends; the caller bounds ctx with Window. Each retried failure is logged at WARN with its
// attempt number, and a success after retries at INFO with the number of attempts and the time
// they took. Canceling ctx (SIGTERM) stops the retries at once, and errors.Is then finds
// ctx.Err() in the error returned.
func Connect(ctx context.Context, connect func(context.Context) error) error {
	start := time.Now()
	wait := firstRetryWait
	for attempt := 1; ; attempt++ {
		err := connect(ctx)
		if err == nil {
			if attempt > 1 {
				slog.InfoContext(ctx, "database connected after retries",
					slog.Int("attempts", attempt),
					slog.Int64("elapsed_ms", time.Since(start).Milliseconds()),
				)
			}
			return nil
		}
		if ctx.Err() != nil {
			return stopped(ctx, err)
		}
		if !Retryable(err) {
			return err
		}
		// The error names host, port, user and database, never the password.
		slog.WarnContext(ctx, "database not reachable, retrying",
			slog.Int("attempt", attempt),
			slog.Any("error", err),
		)
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return stopped(ctx, err)
		case <-timer.C:
		}
		wait = min(2*wait, maxRetryWait)
	}
}

// stopped returns the last connection error together with the reason the retries stopped, the
// window running out or the caller canceling (SIGTERM), so that errors.Is finds the latter.
func stopped(ctx context.Context, err error) error {
	if errors.Is(err, ctx.Err()) {
		return err
	}
	return fmt.Errorf("%w; last attempt: %w", ctx.Err(), err)
}

// Retryable reports whether err is a connection attempt that failed on the network: refused,
// timed out (connect timeout), or cut while connecting or during the handshake. An answer from
// the server (wrong password, missing database), a TLS failure, an unknown host or a failure
// after connecting is not: retrying would only hide a configuration error.
func Retryable(err error) bool {
	if _, ok := errors.AsType[*pgconn.ConnectError](err); !ok {
		return false
	}
	if _, ok := errors.AsType[*pgconn.PgError](err); ok {
		return false
	}
	if dnsErr, ok := errors.AsType[*net.DNSError](err); ok {
		return dnsErr.IsTimeout
	}
	if pgconn.Timeout(err) {
		return true
	}
	// TLS alerts come as *net.OpError too, with Op "remote error" or "local error".
	if opErr, ok := errors.AsType[*net.OpError](err); ok {
		return opErr.Op == "dial" || opErr.Op == "read" || opErr.Op == "write"
	}
	return errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF)
}
