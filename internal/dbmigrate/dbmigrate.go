// Package dbmigrate applies a service's SQL migrations with goose, used as a library so the
// service binary carries its migrations (embed) and runs them as its `migrate` subcommand. It
// retries the first connection while the database is not reachable over the network, for a
// bounded time.
package dbmigrate

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"

	"github.com/anhnvcoder/svp-backend/internal/pgretry"
)

// versionSchema holds goose's version table. Up creates it as the migrating role, which then
// owns it. The app role's default privileges cover schema public only (deploy/postgres/
// bootstrap.sql), so the app role gets no right on the migration history and cannot make a later
// migrate skip or re-run a migration.
const (
	versionSchema = "goose"
	versionTable  = versionSchema + ".goose_db_version"
)

// Waiting for another migrate run: retry the advisory lock every second, for up to 5 minutes.
// createVersionSchema uses the same bound as its lock_timeout.
const (
	lockRetrySeconds = 1
	lockRetries      = 300
)

// connectTimeout bounds each connection attempt, so that an attempt that hangs leaves time for
// the next ones; it matches pgpool.ConnectTimeout.
const connectTimeout = 5 * time.Second

// Up applies every pending goose SQL migration in fsys (files such as 00001_create_users.sql at
// its root) to the Postgres database at databaseURL. Each migration runs in its own
// transaction. A Postgres advisory lock serializes concurrent runs on the same database, so a
// migration never runs twice. Applied migrations are logged through slog's default logger.
//
// While the first connection fails on the network (refused, timed out, closed during the
// handshake), Up retries it for up to 30 seconds, logging each failure at WARN; any other failure
// (authentication, missing database, TLS refused, unknown host) is returned at once, as retrying
// would only hide a configuration error. Canceling ctx stops the retries at once.
func Up(ctx context.Context, databaseURL string, fsys fs.FS) error {
	return up(ctx, databaseURL, fsys, pgretry.Window)
}

// up is Up with the startup window as a parameter, so that tests need not wait 30 s.
func up(ctx context.Context, databaseURL string, fsys fs.FS, window time.Duration) error {
	cfg, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return fmt.Errorf("parse database url: %w", err)
	}
	db := stdlib.OpenDB(*cfg)
	defer func() { _ = db.Close() }()

	// The connection made here stays idle in db's pool for the steps below.
	startCtx, cancel := context.WithTimeout(ctx, window)
	err = pgretry.Connect(startCtx, func(ctx context.Context) error {
		ctx, cancel := context.WithTimeout(ctx, connectTimeout)
		defer cancel()
		return db.PingContext(ctx)
	})
	cancel()
	if err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}

	if err := createVersionSchema(ctx, db); err != nil {
		return fmt.Errorf("create schema %s: %w", versionSchema, err)
	}
	locker, err := lock.NewPostgresSessionLocker(lock.WithLockTimeout(lockRetrySeconds, lockRetries))
	if err != nil {
		return fmt.Errorf("create migration lock: %w", err)
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, fsys,
		goose.WithDisableGlobalRegistry(true),
		goose.WithSessionLocker(locker),
		goose.WithTableName(versionTable),
		goose.WithLogger(goose.NopLogger()),
	)
	if err != nil {
		return fmt.Errorf("load migrations: %w", err)
	}

	results, err := provider.Up(ctx)
	if partial, ok := errors.AsType[*goose.PartialError](err); ok {
		results = partial.Applied
	}
	for _, r := range results {
		slog.InfoContext(ctx, "migration applied",
			slog.Int64("version", r.Source.Version),
			slog.String("file", r.Source.Path),
			slog.Duration("duration", r.Duration),
		)
	}
	if err != nil {
		return fmt.Errorf("apply migrations: %w", err)
	}
	slog.InfoContext(ctx, "migrations up to date", slog.Int("applied", len(results)))
	return nil
}

// createVersionSchema creates versionSchema when missing. Concurrent CREATE SCHEMA IF NOT EXISTS
// can fail on a duplicate key, so it runs under the advisory lock migrations use, in a
// transaction that releases it. The schema usually exists already, and then the lock is skipped,
// so a run never waits behind another run here. When it must wait, lock_timeout bounds the wait
// as the session locker's retries do.
func createVersionSchema(ctx context.Context, db *sql.DB) (retErr error) {
	var exists bool
	if err := db.QueryRowContext(ctx,
		"SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1)", versionSchema,
	).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return nil
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() {
		if retErr != nil {
			retErr = errors.Join(retErr, tx.Rollback())
		}
	}()
	timeout := fmt.Sprintf("SET LOCAL lock_timeout = '%ds'", lockRetrySeconds*lockRetries)
	if _, err := tx.ExecContext(ctx, timeout); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "SELECT pg_advisory_xact_lock($1)", lock.DefaultLockID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, "CREATE SCHEMA IF NOT EXISTS "+versionSchema); err != nil {
		return err
	}
	return tx.Commit()
}
