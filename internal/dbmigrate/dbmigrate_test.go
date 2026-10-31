package dbmigrate_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"slices"
	"strings"
	"syscall"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3/lock"

	"github.com/anhnvcoder/svp-backend/internal/dbmigrate"
	"github.com/anhnvcoder/svp-backend/internal/pgretry/pgretrytest"
	"github.com/anhnvcoder/svp-backend/internal/pgtest"
)

const createItems = `-- +goose Up
CREATE TABLE items (id bigint PRIMARY KEY);
-- +goose Down
DROP TABLE items;
`

const addName = `-- +goose Up
ALTER TABLE items ADD COLUMN name text;
-- +goose Down
ALTER TABLE items DROP COLUMN name;
`

const broken = `-- +goose Up
ALTER TABLE items ADD COLUMN size bigint;
ALTER TABLE no_such_table ADD COLUMN x int;
-- +goose Down
SELECT 1;
`

// slowAddName fails when it runs a second time, and sleeps to keep a concurrent run waiting.
const slowAddName = `-- +goose Up
ALTER TABLE items ADD COLUMN name text;
SELECT pg_sleep(0.5);
-- +goose Down
ALTER TABLE items DROP COLUMN name;
`

func file(sql string) *fstest.MapFile { return &fstest.MapFile{Data: []byte(sql)} }

func columns(t *testing.T, pool *pgxpool.Pool) []string {
	t.Helper()
	rows, err := pool.Query(t.Context(), "SELECT column_name FROM information_schema.columns WHERE table_name = 'items' ORDER BY ordinal_position")
	if err != nil {
		t.Fatal(err)
	}
	var cols []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		cols = append(cols, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return cols
}

func TestUpAppliesPendingMigrationsOnly(t *testing.T) {
	pool := pgtest.New(t, "svp_dbmigrate_self_test", fstest.MapFS{"00001_create_items.sql": file(createItems)})
	url := pool.Config().ConnString()
	logs := pgretrytest.CaptureDefaultLog(t)

	fsys := fstest.MapFS{
		"00001_create_items.sql": file(createItems),
		"00002_add_name.sql":     file(addName),
	}
	if err := dbmigrate.Up(t.Context(), url, fsys); err != nil {
		t.Fatalf("Up() = %v", err)
	}
	if got := strings.Count(logs.String(), `"msg":"migration applied"`); got != 1 {
		t.Errorf("logged %d applied migrations, want 1 (only 00002):\n%s", got, logs)
	}
	if !strings.Contains(logs.String(), `"file":"00002_add_name.sql"`) {
		t.Errorf("log does not name 00002_add_name.sql:\n%s", logs)
	}
	if got := strings.Join(columns(t, pool), ","); got != "id,name" {
		t.Errorf("columns = %s, want id,name", got)
	}

	// Running again applies nothing.
	if err := dbmigrate.Up(t.Context(), url, fsys); err != nil {
		t.Fatalf("second Up() = %v", err)
	}
	if got := strings.Count(logs.String(), `"msg":"migration applied"`); got != 1 {
		t.Errorf("second Up() logged new migrations; total %d, want 1", got)
	}
}

func TestUpRollsBackFailedMigration(t *testing.T) {
	pool := pgtest.New(t, "svp_dbmigrate_broken_test", fstest.MapFS{"00001_create_items.sql": file(createItems)})
	url := pool.Config().ConnString()

	err := dbmigrate.Up(t.Context(), url, fstest.MapFS{
		"00001_create_items.sql": file(createItems),
		"00002_add_name.sql":     file(addName),
		"00003_broken.sql":       file(broken),
	})
	if err == nil {
		t.Fatal("Up() = nil with a broken migration, want an error")
	}
	// 00002 stays applied; 00003 ran in a transaction, so its first statement is rolled back.
	if got := strings.Join(columns(t, pool), ","); got != "id,name" {
		t.Errorf("columns = %s, want id,name", got)
	}
}

func TestConcurrentUpRunsEachMigrationOnce(t *testing.T) {
	pool := pgtest.New(t, "svp_dbmigrate_concurrent_test", fstest.MapFS{"00001_create_items.sql": file(createItems)})
	url := pool.Config().ConnString()
	fsys := fstest.MapFS{
		"00001_create_items.sql": file(createItems),
		"00002_add_name.sql":     file(slowAddName),
	}

	errs := make(chan error, 2)
	for range 2 {
		go func() { errs <- dbmigrate.Up(t.Context(), url, fsys) }()
	}
	for range 2 {
		if err := <-errs; err != nil {
			t.Errorf("concurrent Up() = %v", err)
		}
	}

	var n int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM goose.goose_db_version WHERE version_id = 2").Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("version 2 recorded %d times, want 1", n)
	}
	if got := strings.Join(columns(t, pool), ","); got != "id,name" {
		t.Errorf("columns = %s, want id,name", got)
	}
}

func TestVersionTableOutsidePublicSchema(t *testing.T) {
	pool := pgtest.New(t, "svp_dbmigrate_schema_test", fstest.MapFS{"00001_create_items.sql": file(createItems)})
	var inGoose, inPublic bool
	err := pool.QueryRow(t.Context(),
		"SELECT to_regclass('goose.goose_db_version') IS NOT NULL, to_regclass('public.goose_db_version') IS NOT NULL",
	).Scan(&inGoose, &inPublic)
	if err != nil {
		t.Fatal(err)
	}
	if !inGoose || inPublic {
		t.Errorf("version table in schema goose = %v, in public = %v; want true, false", inGoose, inPublic)
	}
}

func TestUpRejectsBadURL(t *testing.T) {
	err := dbmigrate.Up(context.Background(), "postgres://u:hunter2@127.0.0.1:notaport/db", fstest.MapFS{})
	if err == nil {
		t.Fatal("Up() = nil with an unparsable URL")
	}
	if strings.Contains(err.Error(), "hunter2") {
		t.Errorf("error leaks the password: %v", err)
	}
}

func TestCreateVersionSchemaSkipsLockWhenSchemaExists(t *testing.T) {
	pool := pgtest.New(t, "svp_dbmigrate_lockwait_test", fstest.MapFS{"00001_create_items.sql": file(createItems)})

	// Another migrate run holds the advisory lock for as long as its migrations take.
	holder, err := pool.Acquire(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Release()
	if _, err := holder.Exec(t.Context(), "SELECT pg_advisory_lock($1)", lock.DefaultLockID); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = holder.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", lock.DefaultLockID)
	}()

	db := stdlib.OpenDBFromPool(pool)
	defer func() { _ = db.Close() }()
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	if err := dbmigrate.CreateVersionSchema(ctx, db); err != nil {
		t.Fatalf("CreateVersionSchema() with the schema present and the lock held = %v, want nil without waiting", err)
	}
}

// testWindow stands for the 30 s startup window in tests that wait it out.
const testWindow = 1500 * time.Millisecond

// TestUpUnreachableRetriesUntilWindow: a refused connection and a server that never answers are
// retried, each failure logged at WARN without the password, until the window ends.
func TestUpUnreachableRetriesUntilWindow(t *testing.T) {
	const secret = "s3cret-pw"
	tests := []struct {
		name    string
		addr    string
		refused bool
	}{
		{name: "refused", addr: pgretrytest.ClosedPort(t), refused: true},
		// Each attempt is cut at 5 s or at the end of the window, whichever comes first.
		{name: "never answers", addr: pgretrytest.Blackhole(t)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			logs := pgretrytest.CaptureDefaultLog(t)
			start := time.Now()
			err := dbmigrate.UpWithin(t.Context(), "postgres://svp:"+secret+"@"+tt.addr+"/svp_video?sslmode=disable", fstest.MapFS{}, testWindow)
			elapsed := time.Since(start)
			if err == nil {
				t.Fatal("Up() = nil, want a connection error")
			}
			if elapsed < testWindow || elapsed > testWindow+time.Second {
				t.Errorf("Up() took %v, want the %v window (+1s at most)", elapsed, testWindow)
			}
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Errorf("Up() error = %v, want context.DeadlineExceeded", err)
			}
			if tt.refused {
				if !errors.Is(err, syscall.ECONNREFUSED) {
					t.Errorf("Up() error = %v, want the refused connection", err)
				}
				// 250 ms + 500 ms + 1 s of waits fit in 1.5 s with the first three attempts.
				if n := strings.Count(logs.String(), `"msg":"database not reachable, retrying"`); n < 3 {
					t.Errorf("logged %d retries, want at least 3:\n%s", n, logs)
				}
				if !strings.Contains(logs.String(), `"level":"WARN"`) || !strings.Contains(logs.String(), `"attempt":3`) {
					t.Errorf("retries not logged at WARN with their attempt number:\n%s", logs)
				}
			}
			if strings.Contains(logs.String(), secret) || strings.Contains(err.Error(), secret) {
				t.Errorf("log or error leaks the password: %v\n%s", err, logs)
			}
		})
	}
}

func TestUpStopsRetryingOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	time.AfterFunc(400*time.Millisecond, cancel)

	start := time.Now()
	err := dbmigrate.Up(ctx, "postgres://svp:pw@"+pgretrytest.ClosedPort(t)+"/svp_video?sslmode=disable", fstest.MapFS{})
	elapsed := time.Since(start)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("Up() error = %v, want context.Canceled", err)
	}
	if elapsed > time.Second {
		t.Errorf("Up() took %v after a cancel at 400ms, want under 1s", elapsed)
	}
}

// testDatabaseURL returns the URL of a fresh, migrated test database.
func testDatabaseURL(t *testing.T, name string) *url.URL {
	t.Helper()
	pool := pgtest.New(t, name, fstest.MapFS{"00001_create_items.sql": file(createItems)})
	u, err := url.Parse(pool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// TestUpFailsFastOnConfigurationErrors: errors from the server are not retried.
func TestUpFailsFastOnConfigurationErrors(t *testing.T) {
	base := testDatabaseURL(t, "svp_dbmigrate_config_test")
	missingDB := *base
	missingDB.Path = "/svp_dbmigrate_missing_test"
	missingRole := *base
	missingRole.User = url.UserPassword("svp_dbmigrate_no_such_role", "pw")
	wrongPassword := *base
	wrongPassword.User = url.UserPassword(base.User.Username(), "wrong-password")

	tests := []struct {
		name      string
		url       url.URL
		sqlStates []string
	}{
		{name: "missing database", url: missingDB, sqlStates: []string{"3D000"}},
		// A server that trusts the connection reports a missing role as 28000; one that checks passwords
		// (SCRAM, as in CI) answers 28P01 on purpose so a client cannot tell which roles exist. Both are
		// configuration errors that must not be retried.
		{name: "missing role", url: missingRole, sqlStates: []string{"28000", "28P01"}},
		{name: "wrong password", url: wrongPassword, sqlStates: []string{"28P01"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			logs := pgretrytest.CaptureDefaultLog(t)
			start := time.Now()
			err := dbmigrate.Up(t.Context(), tt.url.String(), fstest.MapFS{"00001_create_items.sql": file(createItems)})
			elapsed := time.Since(start)
			if err == nil {
				if tt.name == "wrong password" {
					t.Skip("the local server trusts this connection and does not check passwords")
				}
				t.Fatal("Up() = nil, want a Postgres error")
			}
			if pgErr, ok := errors.AsType[*pgconn.PgError](err); !ok || !slices.Contains(tt.sqlStates, pgErr.Code) {
				t.Errorf("Up() error = %v, want SQLSTATE %s", err, strings.Join(tt.sqlStates, " or "))
			}
			if elapsed > time.Second {
				t.Errorf("Up() took %v, want under 1s", elapsed)
			}
			if strings.Contains(logs.String(), "retrying") {
				t.Errorf("a configuration error was retried:\n%s", logs)
			}
		})
	}
}

// TestUpRetriesUntilDatabaseReachable: a database refused at first and reachable a second later,
// like a new migrate Job on k3d, gets its migrations, and the log says after how many attempts.
func TestUpRetriesUntilDatabaseReachable(t *testing.T) {
	u := testDatabaseURL(t, "svp_dbmigrate_retry_test")
	target := u.Host
	u.Host = pgretrytest.DelayedProxy(t, target, time.Second)
	logs := pgretrytest.CaptureDefaultLog(t)

	fsys := fstest.MapFS{
		"00001_create_items.sql": file(createItems),
		"00002_add_name.sql":     file(addName),
	}
	if err := dbmigrate.Up(t.Context(), u.String(), fsys); err != nil {
		t.Fatalf("Up() = %v", err)
	}
	if !strings.Contains(logs.String(), `"file":"00002_add_name.sql"`) {
		t.Errorf("00002_add_name.sql not applied:\n%s", logs)
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
