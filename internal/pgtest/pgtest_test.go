package pgtest

import (
	"context"
	"embed"
	"errors"
	"io/fs"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

//go:embed testdata/migrations/*.sql
var embedded embed.FS

func migrations(t *testing.T) fs.FS {
	t.Helper()
	sub, err := fs.Sub(embedded, "testdata/migrations")
	if err != nil {
		t.Fatal(err)
	}
	return sub
}

// requireURL skips tests that talk to Postgres when EnvURL is unset.
func requireURL(t *testing.T) string {
	t.Helper()
	u := os.Getenv(EnvURL)
	if u == "" {
		t.Skip(ErrNoURL.Error())
	}
	return u
}

func databaseExists(t *testing.T, adminURL, name string) bool {
	t.Helper()
	conn, err := pgx.Connect(t.Context(), adminURL)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	var exists bool
	if err := conn.QueryRow(t.Context(), "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", name).Scan(&exists); err != nil {
		t.Fatal(err)
	}
	return exists
}

// With EnvURL unset, a name check that ran after reading the environment (or after connecting)
// would return ErrNoURL instead: getting ErrInvalidName proves nothing was sent.
func TestCreateRejectsInvalidNameBeforeAnything(t *testing.T) {
	t.Setenv(EnvURL, "")
	names := []string{
		"",
		"postgres",
		"svp_user",
		"svp_user_test; DROP DATABASE postgres",
		`svp_user_test"; DROP DATABASE postgres; --`,
		"SVP_USER_TEST",
		"svp_User_test",
		"svp_user-x_test",
		"svp_user_test\n",
		"x_svp_user_test",
	}
	for _, name := range names {
		pool, cleanup, err := Create(t.Context(), name, migrations(t))
		if !errors.Is(err, ErrInvalidName) {
			t.Errorf("Create(%q) error = %v, want ErrInvalidName", name, err)
		}
		if pool != nil || cleanup != nil {
			t.Errorf("Create(%q) returned a pool or cleanup with an error", name)
		}
	}
}

func TestCreateWithoutURL(t *testing.T) {
	t.Setenv(EnvURL, "")
	_, _, err := Create(t.Context(), "svp_pgtest_nourl_test", migrations(t))
	if !errors.Is(err, ErrNoURL) {
		t.Fatalf("Create() error = %v, want ErrNoURL", err)
	}
}

func TestWithDatabase(t *testing.T) {
	got, err := withDatabase("postgres://postgres@127.0.0.1:5432/postgres?sslmode=disable", "svp_x_test")
	if err != nil {
		t.Fatal(err)
	}
	if want := "postgres://postgres@127.0.0.1:5432/svp_x_test?sslmode=disable"; got != want {
		t.Errorf("withDatabase() = %q, want %q", got, want)
	}

	// A dbname or database query parameter would override the path in pgx.
	got, err = withDatabase("postgres://postgres@127.0.0.1:5432/postgres?sslmode=disable&dbname=postgres&database=postgres", "svp_x_test")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := pgx.ParseConfig(got)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Database != "svp_x_test" {
		t.Errorf("withDatabase() = %q connects to database %q, want svp_x_test", got, cfg.Database)
	}

	_, err = withDatabase("host=127.0.0.1 password=hunter2 dbname=postgres", "svp_x_test")
	if err == nil {
		t.Fatal("withDatabase() accepted a key/value DSN")
	}
	if strings.Contains(err.Error(), "hunter2") {
		t.Errorf("error leaks the password: %v", err)
	}
}

func TestNewCreatesMigratedDatabase(t *testing.T) {
	adminURL := requireURL(t)
	const name = "svp_pgtest_self_test"

	t.Run("use", func(t *testing.T) {
		pool := New(t, name, migrations(t))
		if _, err := pool.Exec(t.Context(), "INSERT INTO items (name) VALUES ('a'), ('b')"); err != nil {
			t.Fatalf("insert into migrated table: %v", err)
		}
		var n int
		if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM items").Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 2 {
			t.Errorf("count = %d, want 2", n)
		}
		if !databaseExists(t, adminURL, name) {
			t.Error("database does not exist while the test runs")
		}
	})

	if databaseExists(t, adminURL, name) {
		t.Errorf("database %s still exists after the test ended", name)
	}
}

func TestCreateReplacesLeftoverWithOpenConnection(t *testing.T) {
	adminURL := requireURL(t)
	const name = "svp_pgtest_leftover_test"

	// A previous run that crashed: data in the database and a connection never closed.
	pool, _, err := Create(t.Context(), name, migrations(t))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if _, err := pool.Exec(t.Context(), "INSERT INTO items (name) VALUES ('stale')"); err != nil {
		t.Fatal(err)
	}

	fresh, cleanup, err := Create(t.Context(), name, migrations(t))
	if err != nil {
		t.Fatalf("Create() over a leftover database with an open connection: %v", err)
	}
	var n int
	if err := fresh.QueryRow(t.Context(), "SELECT count(*) FROM items").Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("count = %d in the new database, want 0", n)
	}

	// A hanging connection to the new database must not block the drop either.
	hanging, err := pgx.Connect(t.Context(), fresh.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = hanging.Close(context.Background()) }()

	if err := cleanup(); err != nil {
		t.Fatalf("cleanup() with a hanging connection: %v", err)
	}
	if databaseExists(t, adminURL, name) {
		t.Errorf("database %s still exists after cleanup", name)
	}
}
