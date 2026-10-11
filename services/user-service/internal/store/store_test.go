package store

import (
	"errors"
	"testing"
	"uuid"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/services/user-service/migrations"
)

// The server maps these constraint names to gRPC errors, so the schema must keep them.
func TestSchemaConstraints(t *testing.T) {
	q := New(pgtest.New(t, "svp_user_store_test", migrations.FS))
	ctx := t.Context()

	alice, bob := uuid.NewV7(), uuid.NewV7()
	for _, u := range []CreateUserParams{
		{ID: alice, Email: "alice@example.io", PasswordHash: "hash-a"},
		{ID: bob, Email: "bob@example.io", PasswordHash: "hash-b"},
	} {
		if err := q.CreateUser(ctx, u); err != nil {
			t.Fatalf("CreateUser: %v", err)
		}
	}
	got, err := q.GetUserByEmail(ctx, "alice@example.io")
	if err != nil {
		t.Fatalf("GetUserByEmail: %v", err)
	}
	if got.ID != alice || got.PasswordHash != "hash-a" {
		t.Fatalf("GetUserByEmail = %+v, want id %s and hash-a", got, alice)
	}

	cases := []struct {
		name       string
		err        error
		code       string
		constraint string
	}{
		{"duplicate email", q.CreateUser(ctx, CreateUserParams{ID: uuid.NewV7(), Email: "alice@example.io", PasswordHash: "x"}),
			"23505", "users_email_key"},
		{"self follow", q.CreateFollow(ctx, CreateFollowParams{FollowerID: alice, FolloweeID: alice}),
			"23514", "follows_no_self_follow"},
		{"unknown followee", q.CreateFollow(ctx, CreateFollowParams{FollowerID: alice, FolloweeID: uuid.NewV7()}),
			"23503", "follows_followee_id_fkey"},
		{"unknown follower and followee", q.CreateFollow(ctx, CreateFollowParams{FollowerID: uuid.NewV7(), FolloweeID: uuid.NewV7()}),
			"23503", "follows_follower_id_fkey"},
	}
	for _, c := range cases {
		pgErr, ok := errors.AsType[*pgconn.PgError](c.err)
		if !ok || pgErr.Code != c.code || pgErr.ConstraintName != c.constraint {
			t.Errorf("%s: err = %v, want SQLSTATE %s on %s", c.name, c.err, c.code, c.constraint)
		}
	}

	for range 2 {
		if err := q.CreateFollow(ctx, CreateFollowParams{FollowerID: alice, FolloweeID: bob}); err != nil {
			t.Fatalf("CreateFollow: %v", err)
		}
	}
}
