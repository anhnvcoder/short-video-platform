// Package server implements svp.user.v1.UserService: accounts, login and the follow graph. A
// change to the follow graph writes user.followed or user.unfollowed to the outbox in the same
// transaction (docs/adr/0009-engagement-feed-stage2b.md, section 1).
package server

import (
	"context"
	"errors"
	"log/slog"
	"net/mail"
	"strings"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/outbox"
	"github.com/anhnvcoder/short-video-platform/internal/secret"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/password"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/store"
)

// PublicMethods are the RPCs that need no caller; pass them to callerid.UnaryServerInterceptor.
// The health check is among them: grpcserver serves it next to UserService, and the healthcheck
// subcommand and container probes call it without x-user-id.
var PublicMethods = []string{
	userv1.UserService_Register_FullMethodName,
	userv1.UserService_Login_FullMethodName,
	healthpb.Health_Check_FullMethodName,
}

// MaxEmailBytes is the longest email accepted (the SMTP limit on a forward path, RFC 5321).
const MaxEmailBytes = 254

// TopicUserFollows carries svp.user.v1.FollowEvent, keyed by follower_id.
const TopicUserFollows = "user.follows.v1"

// ErrorInfo reasons returned by the service.
const (
	ReasonInvalidEmail           = "INVALID_EMAIL"
	ReasonInvalidPassword        = "INVALID_PASSWORD"
	ReasonEmailAlreadyRegistered = "EMAIL_ALREADY_REGISTERED"
	ReasonInvalidCredentials     = "INVALID_CREDENTIALS" //nolint:gosec // an error reason, not a credential
	ReasonInvalidFolloweeID      = "INVALID_FOLLOWEE_ID"
	ReasonCannotFollowSelf       = "CANNOT_FOLLOW_SELF"
	ReasonUserNotFound           = "USER_NOT_FOUND"
	ReasonServerBusy             = "SERVER_BUSY"
)

// Constraint names from migrations/, matched when Postgres rejects a write.
const (
	constraintEmailUnique  = "users_email_key"
	constraintFollowerFKey = "follows_follower_id_fkey"
	constraintFolloweeFKey = "follows_followee_id_fkey"
)

// Hasher hashes and verifies passwords; *password.Hasher implements it. Every method returns an
// error wrapping password.ErrBusy when all hashing slots stay taken.
type Hasher interface {
	Hash(ctx context.Context, pw secret.String) (string, error)
	Verify(ctx context.Context, pw secret.String, encoded string) (bool, error)
	VerifyDummy(ctx context.Context, pw secret.String) error
}

// Server serves UserService. Follow and Unfollow expect the caller id that
// callerid.UnaryServerInterceptor puts into the context.
type Server struct {
	userv1.UnimplementedUserServiceServer

	pool    *pgxpool.Pool
	queries *store.Queries
	hasher  Hasher
	issuer  *authtoken.Issuer
	logger  *slog.Logger
}

// New returns a Server reading and writing through pool, hashing with hasher and signing tokens
// with issuer. logger should come from logx so context attributes reach the log.
func New(pool *pgxpool.Pool, hasher Hasher, issuer *authtoken.Issuer, logger *slog.Logger) *Server {
	return &Server{pool: pool, queries: store.New(pool), hasher: hasher, issuer: issuer, logger: logger}
}

// Register creates an account for a new email.
func (s *Server) Register(ctx context.Context, req *userv1.RegisterRequest) (*userv1.RegisterResponse, error) {
	email, ok := normalizeEmail(req.GetEmail())
	if !ok {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidEmail, "email must be a valid address of at most 254 bytes")
	}
	pw := secret.New(req.GetPassword())
	if err := password.CheckLength(pw); err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidPassword, "password must be 8 to 128 characters")
	}
	hash, err := s.hasher.Hash(ctx, pw)
	if err != nil {
		return nil, s.hashError(ctx, "hash password", err)
	}

	userID := uuid.NewV7() // what ids.New returns, kept as a uuid.UUID for the insert
	id := userID.String()
	err = s.queries.CreateUser(ctx, store.CreateUserParams{ID: userID, Email: email, PasswordHash: hash})
	if pgErr, ok := errors.AsType[*pgconn.PgError](err); ok && pgErr.ConstraintName == constraintEmailUnique {
		return nil, grpcerr.New(codes.AlreadyExists, ReasonEmailAlreadyRegistered, "email already registered")
	}
	if err != nil {
		return nil, s.internal(ctx, "insert user", err)
	}
	// The email never reaches the log, only the user id (JWT-8).
	s.logger.InfoContext(logx.With(ctx, slog.String("user_id", id)), "user registered")
	return &userv1.RegisterResponse{UserId: id}, nil
}

// Login returns an access token for a matching email and password. Every way of failing to
// authenticate returns the same error, and an unknown email still runs a hash comparison, so
// neither the answer nor its timing tells whether the email is registered (JWT-5).
func (s *Server) Login(ctx context.Context, req *userv1.LoginRequest) (*userv1.LoginResponse, error) {
	pw := secret.New(req.GetPassword())
	email, ok := normalizeEmail(req.GetEmail())
	// No account can have a malformed email or a password outside the length policy, so these
	// fail without hashing; the bound also keeps huge passwords away from argon2 (JWT-9).
	if !ok || password.CheckLength(pw) != nil {
		s.logger.InfoContext(ctx, "login failed", slog.String("cause", "malformed input"))
		return nil, invalidCredentials()
	}

	user, err := s.queries.GetUserByEmail(ctx, email)
	if errors.Is(err, pgx.ErrNoRows) {
		if err := s.hasher.VerifyDummy(ctx, pw); err != nil {
			return nil, s.hashError(ctx, "verify dummy hash", err)
		}
		s.logger.InfoContext(ctx, "login failed", slog.String("cause", "unknown email"))
		return nil, invalidCredentials()
	}
	if err != nil {
		return nil, s.internal(ctx, "select user by email", err)
	}

	id := user.ID.String()
	ctx = logx.With(ctx, slog.String("user_id", id))
	match, err := s.hasher.Verify(ctx, pw, user.PasswordHash)
	if err != nil {
		return nil, s.hashError(ctx, "verify password", err)
	}
	if !match {
		s.logger.InfoContext(ctx, "login failed", slog.String("cause", "wrong password"))
		return nil, invalidCredentials()
	}

	if password.NeedsRehash(user.PasswordHash) {
		s.rehash(ctx, user.ID, pw)
	}
	token, expiresAt, err := s.issuer.Issue(id)
	if err != nil {
		return nil, s.internal(ctx, "issue token", err)
	}
	s.logger.InfoContext(ctx, "user logged in")
	return &userv1.LoginResponse{AccessToken: token.Reveal(), ExpiresAt: timestamppb.New(expiresAt)}, nil
}

// rehash stores a hash of pw made with the current parameters (JWT-7). A failure is logged and
// the login goes on: the old hash still works and the next login tries again.
func (s *Server) rehash(ctx context.Context, userID uuid.UUID, pw secret.String) {
	hash, err := s.hasher.Hash(ctx, pw)
	if err == nil {
		err = s.queries.UpdatePasswordHash(ctx, store.UpdatePasswordHashParams{ID: userID, PasswordHash: hash})
	}
	if err != nil {
		s.logger.WarnContext(ctx, "rehash password failed", slog.Any("error", err))
		return
	}
	s.logger.InfoContext(ctx, "password rehashed")
}

// Follow makes the caller follow followee_id. Following again succeeds without change and
// without an event.
func (s *Server) Follow(ctx context.Context, req *userv1.FollowRequest) (*userv1.FollowResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	followee, err := parseFolloweeID(req.GetFolloweeId())
	if err != nil {
		return nil, err
	}
	if followee == caller {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonCannotFollowSelf, "cannot follow yourself")
	}

	err = s.changeFollow(ctx, caller, followee, true)
	if pgErr, ok := errors.AsType[*pgconn.PgError](err); ok {
		switch pgErr.ConstraintName {
		case constraintFolloweeFKey:
			return nil, grpcerr.New(codes.NotFound, ReasonUserNotFound, "user not found")
		case constraintFollowerFKey:
			// A valid token whose account no longer exists, e.g. after a database reset.
			return nil, grpcerr.New(codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller, "caller account does not exist")
		}
	}
	if err != nil {
		return nil, s.internal(ctx, "insert follow", err)
	}
	s.logger.InfoContext(ctx, "user followed", slog.String("followee_id", followee.String()))
	return &userv1.FollowResponse{}, nil
}

// Unfollow removes the caller's edge to followee_id. Removing a missing edge succeeds without an
// event.
func (s *Server) Unfollow(ctx context.Context, req *userv1.UnfollowRequest) (*userv1.UnfollowResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	followee, err := parseFolloweeID(req.GetFolloweeId())
	if err != nil {
		return nil, err
	}
	if err := s.changeFollow(ctx, caller, followee, false); err != nil {
		return nil, s.internal(ctx, "delete follow", err)
	}
	s.logger.InfoContext(ctx, "user unfollowed", slog.String("followee_id", followee.String()))
	return &userv1.UnfollowResponse{}, nil
}

// changeFollow inserts (follow true) or deletes the edge follower -> followee and, when a row
// changed, writes the matching FollowEvent to the outbox in the same transaction. The INSERT or
// DELETE locks the edge's row before the outbox insert, as internal/outbox requires for per-key
// order: a second call on the same edge waits for the first to commit, then changes no row and
// writes no event.
func (s *Server) changeFollow(ctx context.Context, follower, followee uuid.UUID, follow bool) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := s.queries.WithTx(tx)

	var n int64
	ev := &userv1.FollowEvent{}
	if follow {
		n, err = q.CreateFollow(ctx, store.CreateFollowParams{FollowerID: follower, FolloweeID: followee})
		ev.Event = &userv1.FollowEvent_UserFollowed{UserFollowed: &userv1.UserFollowed{
			FollowerId: follower.String(), FolloweeId: followee.String(),
		}}
	} else {
		n, err = q.DeleteFollow(ctx, store.DeleteFollowParams{FollowerID: follower, FolloweeID: followee})
		ev.Event = &userv1.FollowEvent_UserUnfollowed{UserUnfollowed: &userv1.UserUnfollowed{
			FollowerId: follower.String(), FolloweeId: followee.String(),
		}}
	}
	if err != nil || n == 0 {
		return err
	}
	ev.Meta = outbox.NewMeta()
	if err := outbox.Write(ctx, tx, TopicUserFollows, follower.String(), ev); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// normalizeEmail trims and lower-cases email and reports whether the result is a bare address
// (no display name, no angle brackets) of at most MaxEmailBytes.
func normalizeEmail(email string) (string, bool) {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" || len(email) > MaxEmailBytes {
		return "", false
	}
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Name != "" || addr.Address != email {
		return "", false
	}
	return email, true
}

// callerID returns the caller put into ctx by the callerid interceptor. The interceptor rejects
// requests without one, so a missing caller here means the server was wired without it.
func callerID(ctx context.Context) (uuid.UUID, error) {
	id, ok := callerid.FromContext(ctx)
	if !ok {
		return uuid.UUID{}, status.Error(codes.Unauthenticated, "missing caller identity")
	}
	u, err := ids.Parse(id)
	if err != nil {
		return uuid.UUID{}, status.Error(codes.Unauthenticated, "missing caller identity")
	}
	return u, nil
}

func parseFolloweeID(s string) (uuid.UUID, error) {
	u, err := ids.Parse(s)
	if err != nil {
		return uuid.UUID{}, grpcerr.New(codes.InvalidArgument, ReasonInvalidFolloweeID, "followee_id must be a canonical lowercase UUID")
	}
	return u, nil
}

func invalidCredentials() error {
	return grpcerr.New(codes.Unauthenticated, ReasonInvalidCredentials, "invalid email or password")
}

// hashError answers RESOURCE_EXHAUSTED when every hashing slot stayed taken (JWT-9), and
// INTERNAL for anything else, such as a stored hash that cannot be read.
func (s *Server) hashError(ctx context.Context, op string, err error) error {
	if errors.Is(err, password.ErrBusy) {
		s.logger.WarnContext(ctx, "password hashing busy", slog.String("op", op))
		return grpcerr.New(codes.ResourceExhausted, ReasonServerBusy, "too many concurrent requests, retry later")
	}
	return s.internal(ctx, op, err)
}

// internal logs err and returns INTERNAL with a generic message: SQL, table and constraint
// names stay in the log.
func (s *Server) internal(ctx context.Context, op string, err error) error {
	s.logger.ErrorContext(ctx, "internal error", slog.String("op", op), slog.Any("error", err))
	return status.Error(codes.Internal, "internal error")
}
