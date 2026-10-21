package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"log/slog"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"google.golang.org/grpc/codes"
	"google.golang.org/protobuf/types/known/timestamppb"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/secret"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/store"
)

// Refresh token lifetimes (docs/adr/0016-web-client.md, section 2). Each rotation gives the new
// token RefreshTTL from the rotation, so a user who comes back within two weeks stays logged in,
// but never beyond RefreshFamilyTTL after the login: a thief who rotates the token first is never
// caught by reuse detection if the real client does not come back, and the ceiling bounds that.
const (
	RefreshTTL       = 14 * 24 * time.Hour
	RefreshFamilyTTL = 30 * 24 * time.Hour
)

// ReasonInvalidRefreshToken is the one reason of every Refresh failure.
const ReasonInvalidRefreshToken = "INVALID_REFRESH_TOKEN" //nolint:gosec // an error reason, not a credential

const constraintRefreshUserFKey = "refresh_tokens_user_id_fkey"

// A refresh token is refreshTokenBytes random bytes in unpadded base64url, always
// refreshTokenLen characters. It carries no data, so it needs no signature: the database keeps
// its SHA-256 and the token is valid while its row says so.
const (
	refreshTokenBytes = 32
	refreshTokenLen   = 43
)

// refreshToken is a token just made: the value for the client and the hash for the database.
type refreshToken struct {
	value secret.String
	hash  []byte
}

func newRefreshToken() refreshToken {
	raw := make([]byte, refreshTokenBytes)
	// crypto/rand.Read never returns an error; it aborts the program if the system source fails.
	_, _ = rand.Read(raw)
	sum := sha256.Sum256(raw)
	return refreshToken{value: secret.New(base64.RawURLEncoding.EncodeToString(raw)), hash: sum[:]}
}

// hashRefreshToken returns the SHA-256 of the 32 bytes token encodes, or false when token is not
// exactly 43 base64url characters that decode to them. It checks the length first, so an empty or
// oversized value never reaches the decoder or the database. No salt: the token has 256 random
// bits, so its hash cannot be reversed by guessing, and lookups by hash must be deterministic.
func hashRefreshToken(token secret.String) ([]byte, bool) {
	v := token.Reveal()
	if len(v) != refreshTokenLen {
		return nil, false
	}
	// Strict rejects non-zero padding bits in the last character, so each token has one spelling.
	raw, err := base64.RawURLEncoding.Strict().DecodeString(v)
	if err != nil || len(raw) != refreshTokenBytes {
		return nil, false
	}
	sum := sha256.Sum256(raw)
	return sum[:], true
}

// startFamily stores a refresh token that opens a new family for userID, as at a login: its id is
// the family id, it expires RefreshTTL from now, and the family RefreshFamilyTTL from now. Each
// login gets its own family, so logging in on a second device does not end the first session.
func (s *Server) startFamily(ctx context.Context, userID uuid.UUID, now time.Time) (refreshToken, time.Time, error) {
	tok := newRefreshToken()
	id := uuid.NewV7()
	expiresAt := now.Add(RefreshTTL)
	err := s.queries.CreateRefreshToken(ctx, store.CreateRefreshTokenParams{
		ID: id, FamilyID: id, UserID: userID, TokenHash: tok.hash,
		CreatedAt: now, ExpiresAt: expiresAt, FamilyExpiresAt: now.Add(RefreshFamilyTTL),
	})
	return tok, expiresAt, err
}

// Refresh exchanges a refresh token for a new access token and the token that replaces it, in one
// transaction under the family lock. A token already used and presented again revokes its whole
// family, the token just issued from it included: the service cannot tell the real client from a
// thief, so neither keeps the session (RFC 9700, section 4.14.2). This includes N concurrent calls
// with one token: one rotates it and the others see it used and revoke the family. That is
// intended and is why the web BFF sends one refresh at a time per session.
func (s *Server) Refresh(ctx context.Context, req *userv1.RefreshRequest) (*userv1.RefreshResponse, error) {
	hash, ok := hashRefreshToken(secret.New(req.GetRefreshToken()))
	if !ok {
		return nil, s.refreshFailed(ctx, "malformed token")
	}
	now := s.clock()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, s.internal(ctx, "begin refresh", err)
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := s.queries.WithTx(tx)

	owner, err := q.GetRefreshTokenOwner(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, s.refreshFailed(ctx, "unknown token")
	}
	if err != nil {
		return nil, s.internal(ctx, "select refresh token owner", err)
	}
	ctx = logx.With(ctx, slog.String("user_id", owner.UserID.String()), slog.String("family_id", owner.FamilyID.String()))
	if err := q.LockRefreshFamily(ctx, owner.FamilyID); err != nil {
		return nil, s.internal(ctx, "lock refresh family", err)
	}
	// Read again under the lock: this statement sees everything the previous holder committed.
	tok, err := q.GetRefreshToken(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		// The user was deleted in between, and its tokens with it.
		return nil, s.refreshFailed(ctx, "unknown token")
	}
	if err != nil {
		return nil, s.internal(ctx, "select refresh token", err)
	}
	ctx = logx.With(ctx, slog.String("token_id", tok.ID.String()))

	switch {
	case tok.Revoked:
		return nil, s.refreshFailed(ctx, "revoked family")
	case tok.Used:
		// Checked before expiry: an expired token may still have live descendants.
		if _, err := q.RevokeRefreshFamily(ctx, store.RevokeRefreshFamilyParams{Now: now, FamilyID: tok.FamilyID}); err != nil {
			return nil, s.internal(ctx, "revoke refresh family", err)
		}
		if err := tx.Commit(ctx); err != nil {
			return nil, s.internal(ctx, "commit refresh family revocation", err)
		}
		s.logger.WarnContext(ctx, "refresh token reused")
		return nil, invalidRefreshToken()
	case !tok.ExpiresAt.After(now):
		return nil, s.refreshFailed(ctx, "expired token")
	}

	n, err := q.MarkRefreshTokenUsed(ctx, store.MarkRefreshTokenUsedParams{Now: now, ID: tok.ID})
	if err != nil {
		return nil, s.internal(ctx, "mark refresh token used", err)
	}
	if n != 1 {
		return nil, s.refreshFailed(ctx, "token changed under the lock")
	}
	next := newRefreshToken()
	nextID := uuid.NewV7()
	expiresAt := now.Add(RefreshTTL)
	if expiresAt.After(tok.FamilyExpiresAt) {
		expiresAt = tok.FamilyExpiresAt
	}
	err = q.CreateRefreshToken(ctx, store.CreateRefreshTokenParams{
		ID: nextID, FamilyID: tok.FamilyID, UserID: tok.UserID, TokenHash: next.hash,
		CreatedAt: now, ExpiresAt: expiresAt, FamilyExpiresAt: tok.FamilyExpiresAt,
	})
	if pgErr, ok := errors.AsType[*pgconn.PgError](err); ok && pgErr.ConstraintName == constraintRefreshUserFKey {
		return nil, s.refreshFailed(ctx, "user deleted")
	}
	if err != nil {
		return nil, s.internal(ctx, "insert refresh token", err)
	}
	// Signed before the commit: once it commits, the old token is spent, and a signing failure
	// after that would leave the client with neither token.
	access, accessExpiresAt, err := s.issuer.Issue(tok.UserID.String())
	if err != nil {
		return nil, s.internal(ctx, "issue token", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, s.internal(ctx, "commit refresh", err)
	}
	s.logger.InfoContext(ctx, "refresh token rotated", slog.String("new_token_id", nextID.String()))
	return &userv1.RefreshResponse{
		AccessToken:      access.Reveal(),
		ExpiresAt:        timestamppb.New(accessExpiresAt),
		RefreshToken:     next.value.Reveal(),
		RefreshExpiresAt: timestamppb.New(expiresAt),
	}, nil
}

// Logout revokes every token of refresh_token's family under the family lock. A malformed or
// unknown token succeeds too, and so does a second call, so the answer tells nothing about which
// tokens exist. A database error is INTERNAL: the client must know the revocation did not happen.
func (s *Server) Logout(ctx context.Context, req *userv1.LogoutRequest) (*userv1.LogoutResponse, error) {
	hash, ok := hashRefreshToken(secret.New(req.GetRefreshToken()))
	if !ok {
		return &userv1.LogoutResponse{}, nil
	}
	now := s.clock()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, s.internal(ctx, "begin logout", err)
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := s.queries.WithTx(tx)

	owner, err := q.GetRefreshTokenOwner(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return &userv1.LogoutResponse{}, nil
	}
	if err != nil {
		return nil, s.internal(ctx, "select refresh token owner", err)
	}
	ctx = logx.With(ctx, slog.String("user_id", owner.UserID.String()), slog.String("family_id", owner.FamilyID.String()))
	if err := q.LockRefreshFamily(ctx, owner.FamilyID); err != nil {
		return nil, s.internal(ctx, "lock refresh family", err)
	}
	n, err := q.RevokeRefreshFamily(ctx, store.RevokeRefreshFamilyParams{Now: now, FamilyID: owner.FamilyID})
	if err != nil {
		return nil, s.internal(ctx, "revoke refresh family", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, s.internal(ctx, "commit logout", err)
	}
	if n > 0 {
		s.logger.InfoContext(ctx, "refresh token family revoked")
	}
	return &userv1.LogoutResponse{}, nil
}

// clock returns the current time, to the second like access token expiries, from the clock tests
// can replace.
func (s *Server) clock() time.Time {
	return s.now().Truncate(time.Second)
}

// refreshFailed logs why a refresh was refused and returns the one error every refusal shares.
func (s *Server) refreshFailed(ctx context.Context, cause string) error {
	s.logger.InfoContext(ctx, "refresh failed", slog.String("cause", cause))
	return invalidRefreshToken()
}

func invalidRefreshToken() error {
	return grpcerr.New(codes.Unauthenticated, ReasonInvalidRefreshToken, "invalid refresh token")
}
