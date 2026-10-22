package migrations_test

import (
	"io/fs"
	"strings"
	"testing"
	"testing/fstest"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/services/user-service/migrations"
)

// upTo returns the migrations up to and including version, named as goose expects.
func upTo(t *testing.T, version string) fs.FS {
	t.Helper()
	files, err := fs.Glob(migrations.FS, "*.sql")
	if err != nil {
		t.Fatal(err)
	}
	out := fstest.MapFS{}
	for _, f := range files {
		if f[:len(version)] > version {
			continue
		}
		data, err := fs.ReadFile(migrations.FS, f)
		if err != nil {
			t.Fatal(err)
		}
		out[f] = &fstest.MapFile{Data: data}
	}
	return out
}

// insertOld inserts a user the way the release before the profile migration does, naming
// neither handle nor display_name.
func insertOld(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) error {
	t.Helper()
	_, err := pool.Exec(t.Context(), "INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
		id, "user-"+id.String()+"@example.io")
	return err
}

func profile(t *testing.T, pool *pgxpool.Pool, id uuid.UUID) (handle, displayName string) {
	t.Helper()
	if err := pool.QueryRow(t.Context(), "SELECT handle, display_name FROM users WHERE id = $1", id).
		Scan(&handle, &displayName); err != nil {
		t.Fatal(err)
	}
	return handle, displayName
}

func generated(id uuid.UUID) string {
	s := id.String()
	return "u_" + s[len(s)-12:]
}

func TestProfileMigrationBackfillsExistingUsers(t *testing.T) {
	pool := pgtest.New(t, "svp_user_migrations_test", upTo(t, "00004"))
	ctx := t.Context()
	existing := []uuid.UUID{uuid.NewV7(), uuid.NewV7(), uuid.NewV7()}
	for _, id := range existing {
		if err := insertOld(t, pool, id); err != nil {
			t.Fatal(err)
		}
	}

	if err := dbmigrate.Up(ctx, pool.Config().ConnString(), migrations.FS); err != nil {
		t.Fatalf("migrate to the latest version: %v", err)
	}
	seen := map[string]bool{}
	for _, id := range existing {
		handle, name := profile(t, pool, id)
		if handle != generated(id) || name != handle {
			t.Errorf("user %s: handle %q, display name %q; want both %q", id, handle, name, generated(id))
		}
		if seen[handle] {
			t.Errorf("handle %q repeats", handle)
		}
		seen[handle] = true
	}

	// The previous release, still serving during a rollout, inserts without the new columns.
	old := uuid.NewV7()
	if err := insertOld(t, pool, old); err != nil {
		t.Fatalf("old-style insert after the migration: %v", err)
	}
	if handle, name := profile(t, pool, old); handle != generated(old) || name != handle {
		t.Errorf("old-style insert got handle %q, display name %q; want both %q", handle, name, generated(old))
	}
	// Values the current release sends are kept as given.
	picked := uuid.NewV7()
	if _, err := pool.Exec(ctx,
		"INSERT INTO users (id, email, password_hash, handle, display_name) VALUES ($1, 'picked@example.io', 'hash', 'picked', 'Picked Name')",
		picked); err != nil {
		t.Fatal(err)
	}
	if handle, name := profile(t, pool, picked); handle != "picked" || name != "Picked Name" {
		t.Errorf("explicit insert got handle %q, display name %q", handle, name)
	}

	// Down removes both columns and the trigger, and the release before works again.
	db := stdlib.OpenDBFromPool(pool)
	t.Cleanup(func() { _ = db.Close() })
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS,
		goose.WithDisableGlobalRegistry(true), goose.WithTableName("goose.goose_db_version"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.DownTo(ctx, 4); err != nil {
		t.Fatalf("migrate down to version 4: %v", err)
	}
	var columns int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns
		WHERE table_name = 'users' AND column_name IN ('handle', 'display_name')`).Scan(&columns); err != nil {
		t.Fatal(err)
	}
	if columns != 0 {
		t.Errorf("%d profile columns left after Down", columns)
	}
	if err := insertOld(t, pool, uuid.NewV7()); err != nil {
		t.Errorf("insert after Down: %v", err)
	}
	if _, err := provider.Up(ctx); err != nil {
		t.Fatalf("migrate up again after Down: %v", err)
	}
}

// Two existing users whose ids end in the same 12 hex digits get the same handle: the migration
// fails as a whole and leaves the table as it was.
func TestProfileMigrationFailsWholeOnDuplicateHandle(t *testing.T) {
	pool := pgtest.New(t, "svp_user_migrations_dup_test", upTo(t, "00004"))
	first := uuid.NewV7()
	s := uuid.NewV7().String()
	second := uuid.MustParse(s[:len(s)-12] + first.String()[24:])
	for _, id := range []uuid.UUID{first, second} {
		if err := insertOld(t, pool, id); err != nil {
			t.Fatal(err)
		}
	}

	err := dbmigrate.Up(t.Context(), pool.Config().ConnString(), migrations.FS)
	if err == nil || !strings.Contains(err.Error(), "users_handle_key") {
		t.Fatalf("migrate = %v, want a users_handle_key violation", err)
	}
	var columns int
	if err := pool.QueryRow(t.Context(), `SELECT count(*) FROM information_schema.columns
		WHERE table_name = 'users' AND column_name IN ('handle', 'display_name')`).Scan(&columns); err != nil {
		t.Fatal(err)
	}
	if columns != 0 {
		t.Errorf("%d profile columns exist after the failed migration, want none", columns)
	}
}
