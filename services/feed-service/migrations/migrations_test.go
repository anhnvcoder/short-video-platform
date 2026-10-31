package migrations_test

import (
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/services/feed-service/migrations"
)

// tables reports whether follows, videos and timeline all exist, and whether any of them does.
func tables(t *testing.T, pool *pgxpool.Pool) (all, some bool) {
	t.Helper()
	var n int
	err := pool.QueryRow(t.Context(),
		"SELECT (to_regclass('public.follows') IS NOT NULL)::int + (to_regclass('public.videos') IS NOT NULL)::int"+
			" + (to_regclass('public.timeline') IS NOT NULL)::int",
	).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n == 3, n > 0
}

// Every migration goes down and up again cleanly after pgtest applied them.
func TestMigrationsDownAndUp(t *testing.T) {
	pool := pgtest.New(t, "svp_feed_migrations_test", migrations.FS)
	if all, _ := tables(t, pool); !all {
		t.Fatal("after up: want follows, videos and timeline")
	}

	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	// The version table internal/dbmigrate uses.
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS,
		goose.WithDisableGlobalRegistry(true),
		goose.WithTableName("goose.goose_db_version"),
		goose.WithLogger(goose.NopLogger()))
	if err != nil {
		t.Fatal(err)
	}

	if _, err := provider.DownTo(t.Context(), 0); err != nil {
		t.Fatalf("down to 0: %v", err)
	}
	if _, some := tables(t, pool); some {
		t.Fatal("after down to 0: want no table left")
	}
	if _, err := provider.Up(t.Context()); err != nil {
		t.Fatalf("up again: %v", err)
	}
	if all, _ := tables(t, pool); !all {
		t.Fatal("after up again: want follows, videos and timeline")
	}
}
