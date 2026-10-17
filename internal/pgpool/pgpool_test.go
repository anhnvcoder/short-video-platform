package pgpool

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace/noop"

	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
)

func TestParseConfigConnectTimeout(t *testing.T) {
	tests := []struct {
		name string
		url  string
		want time.Duration
	}{
		{name: "unset", url: "postgres://svp@127.0.0.1:5432/svp_user", want: ConnectTimeout},
		{name: "zero, no limit", url: "postgres://svp@127.0.0.1:5432/svp_user?connect_timeout=0", want: 0},
		{name: "keyword/value unset", url: "host=127.0.0.1 port=5432 user=svp dbname=svp_user", want: ConnectTimeout},
		{name: "set by the URL", url: "postgres://svp@127.0.0.1:5432/svp_user?connect_timeout=2", want: 2 * time.Second},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, err := parseConfig(tt.url)
			if err != nil {
				t.Fatalf("parseConfig() error = %v", err)
			}
			if got := cfg.ConnConfig.ConnectTimeout; got != tt.want {
				t.Errorf("ConnectTimeout = %v, want %v", got, tt.want)
			}
			if tr, ok := cfg.ConnConfig.Tracer.(redactingTracer); !ok || tr.Tracer == nil {
				t.Errorf("Tracer = %T, want redactingTracer around *otelpgx.Tracer", cfg.ConnConfig.Tracer)
			}
		})
	}
}

func TestNewInvalidURLHidesIt(t *testing.T) {
	const secret = "s3cret-pw"
	for _, u := range []string{
		"postgres://svp:" + secret + "@127.0.0.1:5432/svp_user?connect_timeout=soon",
		"postgres://svp:" + secret + "@[::1",
		"postgres://svp:" + secret + "@127.0.0.1:5432/svp_user?sslmode=bogus",
	} {
		t.Run(u, func(t *testing.T) {
			pool, err := New(t.Context(), u)
			if err == nil {
				pool.Close()
				t.Fatal("New() error = nil, want ErrInvalidURL")
			}
			if !errors.Is(err, ErrInvalidURL) {
				t.Errorf("New() error = %v, want ErrInvalidURL", err)
			}
			if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "127.0.0.1") {
				t.Errorf("error %q leaks the URL", err)
			}
		})
	}
}

// blackhole returns the address of a listener that accepts connections and never answers, like
// a host whose Postgres hangs.
func blackhole(t *testing.T) string {
	t.Helper()
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
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

func TestNewUnreachableFailsWithinBudget(t *testing.T) {
	const secret = "s3cret-pw"
	tests := []struct {
		name  string
		query string
		max   time.Duration
	}{
		{name: "default connect timeout", max: ConnectTimeout + time.Second},
		{name: "connect_timeout of the URL", query: "&connect_timeout=1", max: 2 * time.Second},
		// The warm-up connection dials on its own; Close must not wait out its 60 s.
		{name: "pool warm-up with a long connect_timeout", query: "&pool_min_conns=1&connect_timeout=60", max: startupTimeout + time.Second},
		{name: "connect_timeout=0, no limit", query: "&connect_timeout=0", max: startupTimeout + time.Second},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			u := "postgres://svp:" + secret + "@" + blackhole(t) + "/svp_user?sslmode=disable" + tt.query
			start := time.Now()
			pool, err := New(context.Background(), u)
			elapsed := time.Since(start)
			if err == nil {
				pool.Close()
				t.Fatal("New() error = nil, want a connection error")
			}
			if elapsed > tt.max {
				t.Errorf("New() took %v, want at most %v", elapsed, tt.max)
			}
			if strings.Contains(err.Error(), secret) {
				t.Errorf("error %q leaks the password", err)
			}
		})
	}
}

func TestRedact(t *testing.T) {
	const secret = "probe-secret@example.com"
	pgErr := &pgconn.PgError{
		Severity: "ERROR",
		Code:     "22P02",
		Message:  `invalid input syntax for type uuid: "` + secret + `"`,
		Detail:   secret,
	}
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "postgres error", err: fmt.Errorf("query: %w", pgErr), want: "ERROR: message redacted (SQLSTATE 22P02)"},
		{name: "encode error", err: fmt.Errorf("failed to encode args[0]: %q", secret), want: errRedacted.Error()},
		{name: "deadline", err: fmt.Errorf("%s: %w", secret, context.DeadlineExceeded), want: context.DeadlineExceeded.Error()},
		{name: "canceled", err: fmt.Errorf("%s: %w", secret, context.Canceled), want: context.Canceled.Error()},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := redact(tt.err)
			if got.Error() != tt.want {
				t.Errorf("redact().Error() = %q, want %q", got, tt.want)
			}
		})
	}
	var gotPg *pgconn.PgError
	if !errors.As(redact(pgErr), &gotPg) || gotPg.Code != "22P02" || gotPg.Detail != "" {
		t.Errorf("redact(PgError) = %#v, want a PgError with SQLSTATE 22P02 and no detail", gotPg)
	}
	if got := redact(nil); got != nil {
		t.Errorf("redact(nil) = %v, want nil", got)
	}
	// otelpgx skips recording sql.ErrNoRows, which pgx.ErrNoRows wraps.
	if got := redact(pgx.ErrNoRows); !errors.Is(got, sql.ErrNoRows) {
		t.Errorf("redact(pgx.ErrNoRows) = %v, want sql.ErrNoRows kept", got)
	}
}

func TestNewRefusedFailsFast(t *testing.T) {
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	start := time.Now()
	pool, err := New(t.Context(), "postgres://svp:pw@"+addr+"/svp_user?sslmode=disable")
	if err == nil {
		pool.Close()
		t.Fatal("New() error = nil, want a connection error")
	}
	if d := time.Since(start); d > time.Second {
		t.Errorf("New() took %v, want under 1s", d)
	}
}

const createAccounts = `-- +goose Up
CREATE TABLE accounts (
    email         text PRIMARY KEY,
    password_hash text NOT NULL
);

-- +goose Down
DROP TABLE accounts;
`

// TestSpansOmitQueryParameters runs against the local Postgres: queries whose parameters are an
// email and a password hash, some of them failing on a unique violation whose detail quotes the
// email, on a Postgres message that quotes it, or on a pgx encode error, leave spans with the SQL
// text but neither value.
func TestSpansOmitQueryParameters(t *testing.T) {
	const (
		email = "probe-secret@example.com"
		hash  = "$argon2id$v=19$m=65536,t=3,p=4$cHJvYmUtc2FsdA$cHJvYmUtaGFzaA"
	)
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr))
	otel.SetTracerProvider(tp)
	t.Cleanup(func() {
		otel.SetTracerProvider(noop.NewTracerProvider())
		_ = tp.Shutdown(context.Background())
	})

	migrated := pgtest.New(t, "svp_pgpool_spans_test", fstest.MapFS{"00001_create_accounts.sql": {Data: []byte(createAccounts)}})
	pool, err := New(t.Context(), migrated.Config().ConnString())
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	t.Cleanup(pool.Close)

	ctx, parent := tp.Tracer("test").Start(t.Context(), "request")
	const insert = "INSERT INTO accounts (email, password_hash) VALUES ($1, $2)"
	if _, err := pool.Exec(ctx, insert, email, hash); err != nil {
		t.Fatalf("INSERT: %v", err)
	}
	_, err = pool.Exec(ctx, insert, email, hash)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" || !strings.Contains(pgErr.Detail, email) {
		t.Fatalf("second INSERT error = %v, want a unique violation whose detail quotes the email", err)
	}
	var got string
	if err := pool.QueryRow(ctx, "SELECT password_hash FROM accounts WHERE email = $1", email).Scan(&got); err != nil {
		t.Fatalf("SELECT: %v", err)
	}
	batch := &pgx.Batch{}
	batch.Queue("SELECT count(*) FROM accounts WHERE email = $1", email)
	if err := pool.SendBatch(ctx, batch).Close(); err != nil {
		t.Fatalf("batch: %v", err)
	}
	// Postgres quotes the value: invalid input syntax for type uuid: "probe-secret@example.com".
	const castUUID = "SELECT $1::text::uuid"
	if _, err := pool.Exec(ctx, castUUID, email); !errors.As(err, &pgErr) || !strings.Contains(pgErr.Message, email) {
		t.Fatalf("%s error = %v, want a Postgres error whose message quotes the email", castUUID, err)
	}
	failing := &pgx.Batch{}
	failing.Queue(castUUID, email)
	if err := pool.SendBatch(ctx, failing).Close(); !errors.As(err, &pgErr) {
		t.Fatalf("failing batch error = %v, want a Postgres error", err)
	}
	// pgx fails before sending: the encode error can quote the value too.
	if _, err := pool.Exec(ctx, "SELECT $1::int", []string{email}); err == nil || errors.As(err, &pgErr) || !strings.Contains(err.Error(), email) {
		t.Fatalf("SELECT $1::int error = %v, want a pgx encode error that quotes the email", err)
	}
	parent.End()

	var sawInsert, sawFailure, sawCastFailure bool
	for _, s := range sr.Ended() {
		if s.Name() == "request" {
			continue
		}
		if s.SpanContext().TraceID() != parent.SpanContext().TraceID() {
			t.Errorf("span %q is in trace %s, want the request trace %s", s.Name(), s.SpanContext().TraceID(), parent.SpanContext().TraceID())
		}
		dump, err := json.Marshal(struct {
			Name   string
			Attrs  any
			Events any
			Status any
		}{s.Name(), s.Attributes(), s.Events(), s.Status()})
		if err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{email, hash, "probe-secret"} {
			if strings.Contains(string(dump), secret) {
				t.Errorf("span %s holds a query parameter: %s", s.Name(), dump)
			}
		}
		if strings.Contains(string(dump), `VALUES ($1, $2)`) {
			sawInsert = true
			if strings.Contains(string(dump), "23505") {
				sawFailure = true
			}
		}
		if strings.Contains(string(dump), castUUID) && strings.Contains(string(dump), "22P02") {
			sawCastFailure = true
		}
	}
	if !sawInsert || !sawFailure || !sawCastFailure {
		t.Errorf("saw INSERT span %v, failed INSERT span with SQLSTATE 23505 %v, failed cast span with SQLSTATE 22P02 %v; want all",
			sawInsert, sawFailure, sawCastFailure)
	}
}
