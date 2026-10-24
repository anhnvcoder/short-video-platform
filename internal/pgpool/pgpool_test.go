package pgpool

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"syscall"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace/noop"

	"github.com/anhnvcoder/short-video-platform/internal/pgretry/pgretrytest"
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

// testWindow stands for startupWindow in tests that wait it out.
const testWindow = 1500 * time.Millisecond

// TestNewUnreachableFailsWithinBudget: a server that never answers times attempts out, which are
// retried until the window ends, and New returns then, whatever connect_timeout the URL sets.
func TestNewUnreachableFailsWithinBudget(t *testing.T) {
	const secret = "s3cret-pw"
	tests := []struct {
		name  string
		query string
	}{
		{name: "default connect timeout, longer than the window"},
		{name: "connect_timeout of the URL, shorter than the window", query: "&connect_timeout=1"},
		// The warm-up connection dials on its own; Close must not wait out its 60 s.
		{name: "pool warm-up with a long connect_timeout", query: "&pool_min_conns=1&connect_timeout=60"},
		{name: "connect_timeout=0, no limit", query: "&connect_timeout=0"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			u := "postgres://svp:" + secret + "@" + pgretrytest.Blackhole(t) + "/svp_user?sslmode=disable" + tt.query
			start := time.Now()
			pool, err := open(context.Background(), u, testWindow)
			elapsed := time.Since(start)
			if err == nil {
				pool.Close()
				t.Fatal("open() error = nil, want a connection error")
			}
			if elapsed < testWindow || elapsed > testWindow+time.Second {
				t.Errorf("open() took %v, want the %v window (+1s at most)", elapsed, testWindow)
			}
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Errorf("open() error = %v, want context.DeadlineExceeded", err)
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

// TestNewRefusedRetriesUntilWindow: a refused connection is retried, each failure logged at WARN
// without the password, until the window ends.
func TestNewRefusedRetriesUntilWindow(t *testing.T) {
	const secret = "s3cret-pw"
	logs := pgretrytest.CaptureDefaultLog(t)

	start := time.Now()
	pool, err := open(t.Context(), "postgres://svp:"+secret+"@"+pgretrytest.ClosedPort(t)+"/svp_user?sslmode=disable", testWindow)
	elapsed := time.Since(start)
	if err == nil {
		pool.Close()
		t.Fatal("open() error = nil, want a connection error")
	}
	if elapsed < testWindow || elapsed > testWindow+time.Second {
		t.Errorf("open() took %v, want the %v window (+1s at most)", elapsed, testWindow)
	}
	if !errors.Is(err, syscall.ECONNREFUSED) || !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("open() error = %v, want the refused connection and context.DeadlineExceeded", err)
	}
	// 250 ms + 500 ms + 1 s of waits fit in 1.5 s with the first three attempts.
	if n := strings.Count(logs.String(), `"msg":"database not reachable, retrying"`); n < 3 {
		t.Errorf("logged %d retries, want at least 3:\n%s", n, logs)
	}
	if !strings.Contains(logs.String(), `"level":"WARN"`) || !strings.Contains(logs.String(), `"attempt":3`) {
		t.Errorf("retries not logged at WARN with their attempt number:\n%s", logs)
	}
	if strings.Contains(logs.String(), secret) || strings.Contains(err.Error(), secret) {
		t.Errorf("log or error leaks the password: %v\n%s", err, logs)
	}
}

// TestNewStopsRetryingOnCancel: canceling the context (SIGTERM) during the wait between two
// attempts ends New at once.
func TestNewStopsRetryingOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	time.AfterFunc(400*time.Millisecond, cancel)

	start := time.Now()
	pool, err := New(ctx, "postgres://svp:pw@"+pgretrytest.ClosedPort(t)+"/svp_user?sslmode=disable")
	elapsed := time.Since(start)
	if err == nil {
		pool.Close()
		t.Fatal("New() error = nil, want context.Canceled")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("New() error = %v, want context.Canceled", err)
	}
	if elapsed > time.Second {
		t.Errorf("New() took %v after a cancel at 400ms, want under 1s", elapsed)
	}
}

// testDatabaseURL returns the URL of a fresh test database, skipping without SVP_TEST_POSTGRES_URL.
func testDatabaseURL(t *testing.T, name string) *url.URL {
	t.Helper()
	pool := pgtest.New(t, name, fstest.MapFS{"00001_create_accounts.sql": {Data: []byte(createAccounts)}})
	u, err := url.Parse(pool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// TestNewFailsFastOnConfigurationErrors: errors from the server are not retried.
func TestNewFailsFastOnConfigurationErrors(t *testing.T) {
	base := testDatabaseURL(t, "svp_pgpool_config_test")
	missingDB := *base
	missingDB.Path = "/svp_pgpool_missing_test"
	missingRole := *base
	missingRole.User = url.UserPassword("svp_pgpool_no_such_role", "pw")
	wrongPassword := *base
	wrongPassword.User = url.UserPassword(base.User.Username(), "wrong-password")

	tests := []struct {
		name     string
		url      url.URL
		sqlState string
	}{
		{name: "missing database", url: missingDB, sqlState: "3D000"},
		{name: "missing role", url: missingRole, sqlState: "28000"},
		{name: "wrong password", url: wrongPassword, sqlState: "28P01"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			logs := pgretrytest.CaptureDefaultLog(t)
			start := time.Now()
			pool, err := New(t.Context(), tt.url.String())
			elapsed := time.Since(start)
			if err == nil {
				pool.Close()
				if tt.sqlState == "28P01" {
					t.Skip("the local server trusts this connection and does not check passwords")
				}
				t.Fatal("New() error = nil, want a Postgres error")
			}
			if pgErr, ok := errors.AsType[*pgconn.PgError](err); !ok || pgErr.Code != tt.sqlState {
				t.Errorf("New() error = %v, want SQLSTATE %s", err, tt.sqlState)
			}
			if elapsed > time.Second {
				t.Errorf("New() took %v, want under 1s", elapsed)
			}
			if strings.Contains(logs.String(), "retrying") {
				t.Errorf("a configuration error was retried:\n%s", logs)
			}
		})
	}
}

// TestNewRetriesUntilDatabaseReachable: a database refused at first and reachable a second later,
// like a new pod on k3d, gets a pool, and the log says after how many attempts.
func TestNewRetriesUntilDatabaseReachable(t *testing.T) {
	u := testDatabaseURL(t, "svp_pgpool_retry_test")
	target := u.Host
	u.Host = pgretrytest.DelayedProxy(t, target, time.Second)
	logs := pgretrytest.CaptureDefaultLog(t)

	pool, err := New(t.Context(), u.String())
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	t.Cleanup(pool.Close)
	if err := pool.Ping(t.Context()); err != nil {
		t.Fatalf("Ping() through the proxy = %v", err)
	}

	var connected struct {
		Level     string `json:"level"`
		Attempts  int    `json:"attempts"`
		ElapsedMS int64  `json:"elapsed_ms"`
	}
	for line := range strings.Lines(logs.String()) {
		if strings.Contains(line, `"msg":"database connected after retries"`) {
			if err := json.Unmarshal([]byte(line), &connected); err != nil {
				t.Fatal(err)
			}
		}
	}
	if connected.Level != "INFO" || connected.Attempts < 2 || connected.ElapsedMS < 900 {
		t.Errorf("connected line = %+v, want INFO with at least 2 attempts and about 1000 ms:\n%s", connected, logs)
	}
	if n := strings.Count(logs.String(), `"msg":"database not reachable, retrying"`); n != connected.Attempts-1 {
		t.Errorf("logged %d retries, want %d (attempts - 1)", n, connected.Attempts-1)
	}
	// The test server's password may equal the user name, which the log names: look for the URL's
	// user info instead.
	if strings.Contains(logs.String(), u.User.String()+"@") {
		t.Errorf("log leaks the URL's user info:\n%s", logs)
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
