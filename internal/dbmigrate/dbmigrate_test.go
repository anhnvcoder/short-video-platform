package dbmigrate_test

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3/lock"

	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
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

// lockedBuffer collects log output; pgx and goose may log from other goroutines.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// captureDefaultLog points slog's default logger at a buffer for the rest of the test.
func captureDefaultLog(t *testing.T) *lockedBuffer {
	t.Helper()
	buf := &lockedBuffer{}
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return buf
}

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
	logs := captureDefaultLog(t)

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
