package migrations_test

import (
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/services/video-service/migrations"
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

// uploadingIndexes returns how many of the partial indexes of 00003 exist.
func uploadingIndexes(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	err := pool.QueryRow(t.Context(),
		`SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'videos'
		   AND indexname IN ('videos_uploading_author_idx', 'videos_uploading_created_idx')`,
	).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// hasProcessingAt reports whether videos has the processing_at column of 00004.
func hasProcessingAt(t *testing.T, pool *pgxpool.Pool) bool {
	t.Helper()
	var ok bool
	err := pool.QueryRow(t.Context(),
		`SELECT EXISTS (SELECT 1 FROM information_schema.columns
		   WHERE table_schema = 'public' AND table_name = 'videos' AND column_name = 'processing_at')`,
	).Scan(&ok)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// hasAuthorIndex reports whether the index of 00005 exists.
func hasAuthorIndex(t *testing.T, pool *pgxpool.Pool) bool {
	t.Helper()
	var ok bool
	err := pool.QueryRow(t.Context(), "SELECT to_regclass('public.videos_author_created_idx') IS NOT NULL").Scan(&ok)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// Every migration goes down and up again cleanly after pgtest applied them.
func TestMigrationsDownAndUp(t *testing.T) {
	pool := pgtest.New(t, "svp_video_migrations_test", migrations.FS)
	if videos, outbox := tables(t, pool); !videos || !outbox {
		t.Fatalf("after up: videos %v, outbox %v, want both", videos, outbox)
	}
	if n := uploadingIndexes(t, pool); n != 2 {
		t.Fatalf("after up: %d UPLOADING indexes, want 2", n)
	}
	if !hasProcessingAt(t, pool) {
		t.Fatal("after up: videos has no processing_at")
	}
	if !hasAuthorIndex(t, pool) {
		t.Fatal("after up: no videos_author_created_idx")
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
		t.Fatalf("down 00005: %v", err)
	}
	if hasAuthorIndex(t, pool) {
		t.Fatal("after down 00005: videos_author_created_idx still exists")
	}
	if !hasProcessingAt(t, pool) {
		t.Fatal("after down 00005: videos has no processing_at")
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00004: %v", err)
	}
	if hasProcessingAt(t, pool) {
		t.Fatal("after down 00004: videos still has processing_at")
	}
	if n := uploadingIndexes(t, pool); n != 2 {
		t.Fatalf("after down 00004: %d UPLOADING indexes, want 2", n)
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00003: %v", err)
	}
	if videos, outbox := tables(t, pool); !videos || !outbox {
		t.Fatalf("after down 00003: videos %v, outbox %v, want both", videos, outbox)
	}
	if n := uploadingIndexes(t, pool); n != 0 {
		t.Fatalf("after down 00003: %d UPLOADING indexes, want 0", n)
	}
	if _, err := provider.Down(t.Context()); err != nil {
		t.Fatalf("down 00002: %v", err)
	}
	if videos, outbox := tables(t, pool); !videos || outbox {
		t.Fatalf("after down 00002: videos %v, outbox %v, want only videos", videos, outbox)
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
	if n := uploadingIndexes(t, pool); n != 2 {
		t.Fatalf("after up again: %d UPLOADING indexes, want 2", n)
	}
	if !hasProcessingAt(t, pool) {
		t.Fatal("after up again: videos has no processing_at")
	}
	if !hasAuthorIndex(t, pool) {
		t.Fatal("after up again: no videos_author_created_idx")
	}
}
