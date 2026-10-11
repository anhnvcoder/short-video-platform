package migrations_test

import (
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/services/video-service/migrations"
)

// tables returns which of videos and outbox exist.
func tables(t *testing.T, pool *pgxpool.Pool) (videos, outbox bool) {
	t.Helper()
	err := pool.QueryRow(t.Context(),
		"SELECT to_regclass('public.videos') IS NOT NULL, to_regclass('public.outbox') IS NOT NULL",
	).Scan(&videos, &outbox)
	if err != nil {
		t.Fatal(err)
	}
	return videos, outbox
}

// Every migration goes down and up again cleanly after pgtest applied them.
func TestMigrationsDownAndUp(t *testing.T) {
	pool := pgtest.New(t, "svp_video_migrations_test", migrations.FS)
	if videos, outbox := tables(t, pool); !videos || !outbox {
		t.Fatalf("after up: videos %v, outbox %v, want both", videos, outbox)
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

	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00002: %v", err)
	}
	if videos, outbox := tables(t, pool); !videos || outbox {
		t.Fatalf("after one down: videos %v, outbox %v, want only videos", videos, outbox)
	}
	if _, err := provider.DownTo(t.Context(), 0); err != nil {
		t.Fatalf("down to 0: %v", err)
	}
	if videos, outbox := tables(t, pool); videos || outbox {
		t.Fatalf("after down to 0: videos %v, outbox %v, want neither", videos, outbox)
	}
	if _, err := provider.Up(t.Context()); err != nil {
		t.Fatalf("up again: %v", err)
	}
	if videos, outbox := tables(t, pool); !videos || !outbox {
		t.Fatalf("after up again: videos %v, outbox %v, want both", videos, outbox)
	}
}
