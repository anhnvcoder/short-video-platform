package store

import (
	"bytes"
	"errors"
	"testing"
	"time"
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

	now := time.Now()
	token := func(user uuid.UUID, hash []byte) CreateRefreshTokenParams {
		id := uuid.NewV7()
		return CreateRefreshTokenParams{ID: id, FamilyID: id, UserID: user, TokenHash: hash,
			CreatedAt: now, ExpiresAt: now.Add(time.Hour), FamilyExpiresAt: now.Add(2 * time.Hour)}
	}
	hash := bytes.Repeat([]byte{1}, 32)
	if err := q.CreateRefreshToken(ctx, token(alice, hash)); err != nil {
		t.Fatalf("CreateRefreshToken: %v", err)
	}
	pastFamily := token(alice, bytes.Repeat([]byte{2}, 32))
	pastFamily.ExpiresAt = pastFamily.FamilyExpiresAt.Add(time.Second)

	createFollow := func(arg CreateFollowParams) error {
		_, err := q.CreateFollow(ctx, arg)
		return err
	}
	cases := []struct {
		name       string
		err        error
		code       string
		constraint string
	}{
		{"duplicate email", q.CreateUser(ctx, CreateUserParams{ID: uuid.NewV7(), Email: "alice@example.io", PasswordHash: "x"}),
			"23505", "users_email_key"},
		{"self follow", createFollow(CreateFollowParams{FollowerID: alice, FolloweeID: alice}),
			"23514", "follows_no_self_follow"},
		{"unknown followee", createFollow(CreateFollowParams{FollowerID: alice, FolloweeID: uuid.NewV7()}),
			"23503", "follows_followee_id_fkey"},
		{"unknown follower and followee", createFollow(CreateFollowParams{FollowerID: uuid.NewV7(), FolloweeID: uuid.NewV7()}),
			"23503", "follows_follower_id_fkey"},
		{"duplicate refresh token hash", q.CreateRefreshToken(ctx, token(bob, hash)),
			"23505", "refresh_tokens_token_hash_key"},
		{"refresh token hash not 32 bytes", q.CreateRefreshToken(ctx, token(alice, []byte("short"))),
			"23514", "refresh_tokens_token_hash_length"},
		{"refresh token outliving its family", q.CreateRefreshToken(ctx, pastFamily),
			"23514", "refresh_tokens_expires_within_family"},
		{"refresh token of unknown user", q.CreateRefreshToken(ctx, token(uuid.NewV7(), bytes.Repeat([]byte{3}, 32))),
			"23503", "refresh_tokens_user_id_fkey"},
	}
	for _, c := range cases {
		pgErr, ok := errors.AsType[*pgconn.PgError](c.err)
		if !ok || pgErr.Code != c.code || pgErr.ConstraintName != c.constraint {
			t.Errorf("%s: err = %v, want SQLSTATE %s on %s", c.name, c.err, c.code, c.constraint)
		}
	}

	// The server writes an event only when a row changed, so the counts must be exact.
	edge := CreateFollowParams{FollowerID: alice, FolloweeID: bob}
	for i, want := range []int64{1, 0} {
		if n, err := q.CreateFollow(ctx, edge); err != nil || n != want {
			t.Fatalf("CreateFollow call %d = %d, %v, want %d rows", i+1, n, err, want)
		}
	}
	for i, want := range []int64{1, 0} {
		n, err := q.DeleteFollow(ctx, DeleteFollowParams{FollowerID: alice, FolloweeID: bob})
		if err != nil || n != want {
			t.Fatalf("DeleteFollow call %d = %d, %v, want %d rows", i+1, n, err, want)
		}
	}
}
