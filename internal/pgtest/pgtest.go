// Package pgtest gives integration tests a fresh, migrated Postgres database of their own on the
// local server named by SVP_TEST_POSTGRES_URL, and drops it afterwards.
//
// It drops databases, so it refuses every name outside the svp_<name>_test pattern before it
// connects anywhere.
package pgtest

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"regexp"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/anhnvcoder/svp-backend/internal/dbmigrate"
)

// EnvURL names the variable holding a superuser DSN (URL form) to the local Postgres; `make
// test` sets it.
const EnvURL = "SVP_TEST_POSTGRES_URL"

var (
	// ErrNoURL means EnvURL is unset: integration tests skip.
	ErrNoURL = errors.New(EnvURL + " is not set; integration tests need a local Postgres (make test sets it)")
	// ErrInvalidName means the database name does not match svp_<name>_test.
	ErrInvalidName = errors.New("test database name must match ^svp_[a-z0-9_]+_test$")
)

var validName = regexp.MustCompile(`^svp_[a-z0-9_]+_test$`)

// cleanupTimeout bounds dropping the database after the test, when the test's context is gone.
const cleanupTimeout = 30 * time.Second

// New creates the database name (dropping a leftover one first), applies the migrations in
// migrations, and returns a pool to it. The pool is closed and the database dropped when t
// ends. Without EnvURL the test is skipped.
func New(t testing.TB, name string, migrations fs.FS) *pgxpool.Pool {
	t.Helper()
	pool, cleanup, err := Create(t.Context(), name, migrations)
	if errors.Is(err, ErrNoURL) {
		t.Skip(err.Error())
	}
	if err != nil {
		t.Fatalf("pgtest: %v", err)
	}
	t.Cleanup(func() {
		if err := cleanup(); err != nil {
			t.Errorf("pgtest: %v", err)
		}
	})
	return pool
}

// Create is New for callers without a testing.TB, such as TestMain: it returns ErrNoURL
// (wrapped) when EnvURL is unset, and a cleanup that closes the pool and drops the database.
func Create(ctx context.Context, name string, migrations fs.FS) (pool *pgxpool.Pool, cleanup func() error, err error) {
	if !validName.MatchString(name) {
		return nil, nil, fmt.Errorf("%w: got %q", ErrInvalidName, name)
	}
	adminURL := os.Getenv(EnvURL)
	if adminURL == "" {
		return nil, nil, ErrNoURL
	}
	dbURL, err := withDatabase(adminURL, name)
	if err != nil {
		return nil, nil, err
	}

	if err := exec(ctx, adminURL, "DROP DATABASE IF EXISTS "+quote(name)+" WITH (FORCE)"); err != nil {
		return nil, nil, fmt.Errorf("drop leftover database %s: %w", name, err)
	}
	if err := exec(ctx, adminURL, "CREATE DATABASE "+quote(name)); err != nil {
		return nil, nil, fmt.Errorf("create database %s: %w", name, err)
	}
	drop := func() error {
		dropCtx, cancel := context.WithTimeout(context.Background(), cleanupTimeout)
		defer cancel()
		if err := exec(dropCtx, adminURL, "DROP DATABASE IF EXISTS "+quote(name)+" WITH (FORCE)"); err != nil {
			return fmt.Errorf("drop database %s: %w", name, err)
		}
		return nil
	}

	if err := dbmigrate.Up(ctx, dbURL, migrations); err != nil {
		return nil, nil, errors.Join(fmt.Errorf("migrate database %s: %w", name, err), drop())
	}
	pool, err = pgxpool.New(ctx, dbURL)
	if err != nil {
		return nil, nil, errors.Join(fmt.Errorf("open pool to %s: %w", name, err), drop())
	}
	cleanup = func() error {
		pool.Close()
		return drop()
	}
	return pool, cleanup, nil
}

// withDatabase returns the URL-form DSN adminURL pointing at database name instead. pgx lets a
// dbname or database query parameter override the path, so both are removed.
func withDatabase(adminURL, name string) (string, error) {
	u, err := url.Parse(adminURL)
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		// The DSN holds a password: never echo it or the parse error, which quotes it.
		return "", fmt.Errorf("%s must be a postgres:// URL", EnvURL)
	}
	u.Path = "/" + name
	u.RawPath = ""
	q := u.Query()
	q.Del("dbname")
	q.Del("database")
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// quote returns name as a safely quoted SQL identifier.
func quote(name string) string {
	return pgx.Identifier{name}.Sanitize()
}

// exec runs one statement on a fresh connection to the maintenance database at adminURL.
func exec(ctx context.Context, adminURL, sql string) error {
	conn, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		return fmt.Errorf("connect to admin database: %w", err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	_, err = conn.Exec(ctx, sql)
	return err
}
