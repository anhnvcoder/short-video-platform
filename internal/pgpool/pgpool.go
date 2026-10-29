// Package pgpool opens the Postgres pool every service uses: traced with otelpgx, pool statistics
// as metrics, and checked at startup within a bounded time, retrying while the database is not
// reachable over the network. One constructor keeps the tracing, the leaving out of query
// parameters and the startup deadline the same in every service.
package pgpool

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"time"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"

	"github.com/anhnvcoder/short-video-platform/internal/pgretry"
)

// ConnectTimeout bounds each new connection, dial and authentication included, when the URL sets
// no connect_timeout.
const ConnectTimeout = 5 * time.Second

// ErrInvalidURL means the URL could not be parsed. It never carries the URL, which holds a
// password.
var ErrInvalidURL = errors.New("pgpool: invalid database URL; want postgres://user:password@host:port/dbname")

// New returns a pool to databaseURL once a connection to it has succeeded, within 30 seconds.
// While the connection fails on the network (refused, timed out, closed during the handshake) it
// retries, logging each failure at WARN; any other failure (authentication, missing database, TLS
// refused, unknown host) is returned at once, as retrying would only hide a configuration error.
// Canceling ctx stops the retries at once.
//
// Query, batch, prepare, connect and acquire calls get spans from the global tracer provider,
// as children of the caller's span only (none without one). Spans carry the SQL text with its
// $n placeholders but never the parameter values, which can hold emails and password hashes, nor
// the error message of a failed call, which can quote them: only its severity and SQLSTATE.
// Pool statistics (pgxpool.*) are reported to the global meter provider, labelled
// db.client.connection.pool.name; otelpgx keeps them registered after Close. Without WithName that
// label is host:port/database, the same for every pool of one process on one database, so a
// process opens one pool per name: a second pool needs a name of its own (WithName), or the two
// report over each other.
//
// Without options the pool has pgx's defaults, pool_max_conns of the URL or max(4, NumCPU)
// connections; WithMaxConns sets the size instead.
func New(ctx context.Context, databaseURL string, opts ...Option) (*pgxpool.Pool, error) {
	return open(ctx, databaseURL, pgretry.Window, opts...)
}

// Option changes the pool New opens.
type Option func(*options)

type options struct {
	maxConns int32
	name     string
}

// WithMaxConns caps the pool at n connections, counting those still being opened: pgxpool takes
// a slot before it dials and gives it back only when the dial fails or the connection is closed,
// even when the Acquire that started the dial was canceled.
func WithMaxConns(n int32) Option {
	return func(o *options) { o.maxConns = n }
}

// WithName names the pool in its statistics, as the db.client.connection.pool.name attribute of
// the OpenTelemetry semantic conventions for database client metrics, so that two pools of one
// process report apart.
func WithName(name string) Option {
	return func(o *options) { o.name = name }
}

// open is New with the startup window as a parameter, so that tests need not wait 30 s. The window
// bounds the startup check with its retries and the pool warm-up (pool_min_conns), whatever
// connect_timeout the URL sets.
func open(ctx context.Context, databaseURL string, window time.Duration, opts ...Option) (*pgxpool.Pool, error) {
	var o options
	for _, opt := range opts {
		opt(&o)
	}
	cfg, err := parseConfig(databaseURL, o)
	if err != nil {
		return nil, err
	}
	// The pool warms up (pool_min_conns) on the context it is created with: bound it too, so that
	// Close after a failed Ping does not wait for connections still dialing. Warm-up cut short
	// here is redone by the pool's periodic health check.
	startCtx, cancel := context.WithTimeout(ctx, window)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(startCtx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pgpool: create pool: %w", err)
	}
	// pgxpool connects lazily; fail at startup instead of on the first request.
	if err := pgretry.Connect(startCtx, pool.Ping); err != nil {
		pool.Close()
		return nil, fmt.Errorf("pgpool: connect to database: %w", err)
	}
	var statsOpts []otelpgx.StatsOption
	if o.name != "" {
		statsOpts = append(statsOpts, otelpgx.WithStatsAttributes(semconv.DBClientConnectionPoolName(o.name)))
	}
	if err := otelpgx.RecordStats(pool, statsOpts...); err != nil {
		pool.Close()
		return nil, fmt.Errorf("pgpool: record pool stats: %w", err)
	}
	return pool, nil
}

// parseConfig parses databaseURL and adds the tracer, the default connect timeout and the size
// in o.
func parseConfig(databaseURL string, o options) (*pgxpool.Config, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		// The parse error quotes the URL, with a best-effort redacted password: drop it.
		return nil, ErrInvalidURL
	}
	// pgx reads both an unset connect_timeout and connect_timeout=0 (no limit) as 0: keep the
	// value the URL sets, 0 included.
	if cfg.ConnConfig.ConnectTimeout == 0 && !setsConnectTimeout(databaseURL) {
		cfg.ConnConfig.ConnectTimeout = ConnectTimeout
	}
	if o.maxConns != 0 {
		cfg.MaxConns = o.maxConns
	}
	// Query parameters stay out of spans: WithIncludeQueryParameters is not set.
	cfg.ConnConfig.Tracer = redactingTracer{otelpgx.NewTracer()}
	return cfg, nil
}

// setsConnectTimeout reports whether databaseURL, in URL form, sets connect_timeout. A
// keyword/value connection string counts as not setting it.
func setsConnectTimeout(databaseURL string) bool {
	u, err := url.Parse(databaseURL)
	return err == nil && u.Query().Has("connect_timeout")
}

// redactingTracer is the otelpgx tracer with the error of each failed call replaced before it
// reaches the span: Postgres messages and pgx encode errors can quote a parameter value
// (invalid input syntax for type uuid: "<value>"). Connect errors carry only the host, port,
// user and database, and stay as they are.
type redactingTracer struct {
	*otelpgx.Tracer
}

func (t redactingTracer) TraceQueryEnd(ctx context.Context, conn *pgx.Conn, data pgx.TraceQueryEndData) {
	data.Err = redact(data.Err)
	t.Tracer.TraceQueryEnd(ctx, conn, data)
}

func (t redactingTracer) TraceBatchQuery(ctx context.Context, conn *pgx.Conn, data pgx.TraceBatchQueryData) {
	data.Err = redact(data.Err)
	t.Tracer.TraceBatchQuery(ctx, conn, data)
}

func (t redactingTracer) TraceBatchEnd(ctx context.Context, conn *pgx.Conn, data pgx.TraceBatchEndData) {
	data.Err = redact(data.Err)
	t.Tracer.TraceBatchEnd(ctx, conn, data)
}

func (t redactingTracer) TraceCopyFromEnd(ctx context.Context, conn *pgx.Conn, data pgx.TraceCopyFromEndData) {
	data.Err = redact(data.Err)
	t.Tracer.TraceCopyFromEnd(ctx, conn, data)
}

func (t redactingTracer) TracePrepareEnd(ctx context.Context, conn *pgx.Conn, data pgx.TracePrepareEndData) {
	data.Err = redact(data.Err)
	t.Tracer.TracePrepareEnd(ctx, conn, data)
}

func (t redactingTracer) TraceAcquireEnd(ctx context.Context, pool *pgxpool.Pool, data pgxpool.TraceAcquireEndData) {
	data.Err = redact(data.Err)
	t.Tracer.TraceAcquireEnd(ctx, pool, data)
}

// errRedacted stands for an error that is neither a Postgres error nor a context error.
var errRedacted = errors.New("pgx error (message redacted)")

// redact returns an error whose text holds no value from the call: the severity and SQLSTATE of
// a Postgres error (still a *pgconn.PgError, so otelpgx sets pgx.sql_state), a context error as
// is, errRedacted for anything else. nil and pgx.ErrNoRows, which otelpgx does not record, stay.
func redact(err error) error {
	var pgErr *pgconn.PgError
	switch {
	case err == nil, errors.Is(err, pgx.ErrNoRows):
		return err
	case errors.As(err, &pgErr):
		return &pgconn.PgError{Severity: pgErr.Severity, Code: pgErr.Code, Message: "message redacted"}
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case errors.Is(err, context.Canceled):
		return context.Canceled
	default:
		return errRedacted
	}
}
