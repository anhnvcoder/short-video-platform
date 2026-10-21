package server

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/argon2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/proto"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/internal/secret"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/password"
	"github.com/anhnvcoder/short-video-platform/services/user-service/migrations"
)

const testPassword = "correct horse battery"

// testPool is the database shared by the integration tests, or nil when they skip. Tests keep
// out of each other's way by using fresh emails and ids.
var (
	testPool   *pgxpool.Pool
	skipReason string
)

func TestMain(m *testing.M) {
	pool, cleanup, err := pgtest.Create(context.Background(), "svp_user_server_test", migrations.FS)
	switch {
	case errors.Is(err, pgtest.ErrNoURL):
		skipReason = err.Error()
	case err != nil:
		fmt.Fprintln(os.Stderr, "pgtest:", err)
		os.Exit(1)
	default:
		testPool = pool
	}
	code := m.Run()
	if cleanup != nil {
		if err := cleanup(); err != nil {
			fmt.Fprintln(os.Stderr, "pgtest:", err)
			code = 1
		}
	}
	os.Exit(code)
}

// lockedBuffer collects log output written from server goroutines.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// spyHasher wraps a real Hasher, counts VerifyDummy calls and can make Hash fail.
type spyHasher struct {
	Hasher
	dummyCalls atomic.Int32
	hashErr    error
}

func (h *spyHasher) Hash(ctx context.Context, pw secret.String) (string, error) {
	if h.hashErr != nil {
		return "", h.hashErr
	}
	return h.Hasher.Hash(ctx, pw)
}

func (h *spyHasher) VerifyDummy(ctx context.Context, pw secret.String) error {
	h.dummyCalls.Add(1)
	return h.Hasher.VerifyDummy(ctx, pw)
}

// busyHasher fails every call as a full semaphore does.
type busyHasher struct{}

func (busyHasher) Hash(context.Context, secret.String) (string, error) { return "", password.ErrBusy }
func (busyHasher) Verify(context.Context, secret.String, string) (bool, error) {
	return false, password.ErrBusy
}
func (busyHasher) VerifyDummy(context.Context, secret.String) error { return password.ErrBusy }

type env struct {
	server   *Server
	client   userv1.UserServiceClient
	health   healthpb.HealthClient
	logs     *lockedBuffer
	verifier *authtoken.Verifier
}

// newEnv serves a Server and the standard health service over bufconn behind the real callerid
// interceptor, as grpcserver does, on testPool unless db is given, and returns clients.
func newEnv(t *testing.T, hasher Hasher, db ...*pgxpool.Pool) *env {
	t.Helper()
	pool := testPool
	if len(db) > 0 {
		pool = db[0]
	}
	if pool == nil {
		t.Skip(skipReason)
	}
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	logs := &lockedBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))

	srv := grpc.NewServer(grpc.ChainUnaryInterceptor(callerid.UnaryServerInterceptor(PublicMethods...)))
	server := New(pool, hasher, authtoken.NewIssuer("test", key), logger)
	userv1.RegisterUserServiceServer(srv, server)
	healthpb.RegisterHealthServer(srv, health.NewServer())
	lis := bufconn.Listen(1 << 20)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return &env{
		server:   server,
		client:   userv1.NewUserServiceClient(conn),
		health:   healthpb.NewHealthClient(conn),
		logs:     logs,
		verifier: authtoken.NewVerifier(map[string]ed25519.PublicKey{"test": key.Public().(ed25519.PublicKey)}),
	}
}

// newEmail returns an email no other test uses.
func newEmail() string {
	return "user-" + ids.New() + "@example.io"
}

func asCaller(ctx context.Context, userID string) context.Context {
	return metadata.AppendToOutgoingContext(ctx, callerid.MetadataKey, userID)
}

func (e *env) register(t *testing.T, email string) string {
	t.Helper()
	resp, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: email, Password: testPassword})
	if err != nil {
		t.Fatalf("Register(%q): %v", email, err)
	}
	return resp.GetUserId()
}

func wantError(t *testing.T, err error, code codes.Code, reason string) {
	t.Helper()
	if got := status.Code(err); got != code {
		t.Fatalf("code = %v, want %v (err = %v)", got, code, err)
	}
	if got := grpcerr.Reason(err); got != reason {
		t.Fatalf("reason = %q, want %q", got, reason)
	}
}

func TestNormalizeEmail(t *testing.T) {
	long := strings.Repeat("a", MaxEmailBytes-len("@example.io")) + "@example.io"
	valid := map[string]string{
		"a@x.io":           "a@x.io",
		"  A@X.io\t":       "a@x.io",
		"First.Last@Ex.IO": "first.last@ex.io",
		long:               long,
	}
	for in, want := range valid {
		if got, ok := normalizeEmail(in); !ok || got != want {
			t.Errorf("normalizeEmail(%q) = %q, %v; want %q, true", in, got, ok, want)
		}
	}
	invalid := []string{
		"",
		"   ",
		"no-at-sign",
		"a@",
		"@x.io",
		"Name <a@x.io>",
		"<a@x.io>",
		"a@x.io, b@x.io",
		"a@x.io (comment)",
		"a\x00@x.io",
		"a" + long,
	}
	for _, in := range invalid {
		if got, ok := normalizeEmail(in); ok {
			t.Errorf("normalizeEmail(%q) = %q, true; want rejected", in, got)
		}
	}
}

func TestRegister(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	id := e.register(t, email)
	if _, err := ids.Parse(id); err != nil {
		t.Fatalf("user_id %q is not a canonical UUID: %v", id, err)
	}

	_, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: strings.ToUpper(email), Password: testPassword})
	wantError(t, err, codes.AlreadyExists, ReasonEmailAlreadyRegistered)

	for _, bad := range []string{"", "not-an-email", "Name <x@example.io>"} {
		_, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: bad, Password: testPassword})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidEmail)
	}
	for _, bad := range []string{"", "short", "1234567", strings.Repeat("p", password.MaxLength+1)} {
		_, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: bad})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidPassword)
	}
}

func TestRegisterSameEmailConcurrently(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	emails := []string{email, strings.ToUpper(email)}
	errs := make([]error, len(emails))
	var wg sync.WaitGroup
	for i, em := range emails {
		wg.Go(func() {
			_, errs[i] = e.client.Register(t.Context(), &userv1.RegisterRequest{Email: em, Password: testPassword})
		})
	}
	wg.Wait()

	var ok, exists int
	for _, err := range errs {
		switch {
		case err == nil:
			ok++
		case status.Code(err) == codes.AlreadyExists && grpcerr.Reason(err) == ReasonEmailAlreadyRegistered:
			exists++
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if ok != 1 || exists != 1 {
		t.Fatalf("got %d successes and %d ALREADY_EXISTS, want 1 and 1", ok, exists)
	}
}

func TestLogin(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	id := e.register(t, email)

	before := time.Now()
	resp, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: " " + strings.ToUpper(email), Password: testPassword})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	sub, err := e.verifier.Verify(resp.GetAccessToken())
	if err != nil {
		t.Fatalf("token does not verify: %v", err)
	}
	if sub != id {
		t.Errorf("token subject = %q, want %q", sub, id)
	}
	exp := resp.GetExpiresAt().AsTime()
	if exp.Before(before.Add(authtoken.TTL-time.Second)) || exp.After(time.Now().Add(authtoken.TTL)) {
		t.Errorf("expires_at = %v, want about %v from now", exp, authtoken.TTL)
	}
}

func TestLoginFailuresAreIndistinguishable(t *testing.T) {
	hasher := &spyHasher{Hasher: password.NewHasher()}
	e := newEnv(t, hasher)
	email := newEmail()
	e.register(t, email)

	cases := []struct {
		name            string
		email, password string
	}{
		{"unknown email", newEmail(), testPassword},
		{"wrong password", email, "wrong password!"},
		{"malformed email", "not-an-email", testPassword},
		{"password too long", email, strings.Repeat("p", password.MaxLength+1)},
	}
	var first *status.Status
	for _, c := range cases {
		_, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: c.email, Password: c.password})
		wantError(t, err, codes.Unauthenticated, ReasonInvalidCredentials)
		st := status.Convert(err)
		if st.Message() != "invalid email or password" {
			t.Errorf("%s: message = %q", c.name, st.Message())
		}
		if first == nil {
			first = st
			continue
		}
		if st.Code() != first.Code() || st.Message() != first.Message() || grpcerr.Reason(err) != grpcerr.Reason(first.Err()) {
			t.Errorf("%s: %v differs from %s: %v", c.name, err, cases[0].name, first.Err())
		}
	}
	if n := hasher.dummyCalls.Load(); n != 1 {
		t.Errorf("VerifyDummy ran %d times, want once (for the unknown email)", n)
	}
}

// oldHash returns a PHC hash of pw with parameters weaker than the current ones.
func oldHash(pw string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	key := argon2.IDKey([]byte(pw), salt, 1, 8*1024, 1, 32)
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=8192,t=1,p=1$%s$%s", argon2.Version, b64.EncodeToString(salt), b64.EncodeToString(key))
}

func storedHash(t *testing.T, id string) string {
	t.Helper()
	var hash string
	if err := testPool.QueryRow(t.Context(), "SELECT password_hash FROM users WHERE id = $1", id).Scan(&hash); err != nil {
		t.Fatal(err)
	}
	return hash
}

func insertUser(t *testing.T, email, hash string) string {
	t.Helper()
	id := ids.New()
	if _, err := testPool.Exec(t.Context(), "INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)", id, email, hash); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestLoginRehashesOldHash(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	old := oldHash(testPassword)
	id := insertUser(t, email, old)

	if _, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: email, Password: testPassword}); err != nil {
		t.Fatalf("Login: %v", err)
	}
	got := storedHash(t, id)
	if got == old || password.NeedsRehash(got) {
		t.Fatalf("stored hash %q was not replaced by one with current parameters", got)
	}
	if _, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: email, Password: testPassword}); err != nil {
		t.Fatalf("Login with the rehashed password: %v", err)
	}
}

func TestLoginSucceedsWhenRehashFails(t *testing.T) {
	e := newEnv(t, &spyHasher{Hasher: password.NewHasher(), hashErr: password.ErrBusy})
	email := newEmail()
	old := oldHash(testPassword)
	id := insertUser(t, email, old)

	if _, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: email, Password: testPassword}); err != nil {
		t.Fatalf("Login: %v", err)
	}
	if got := storedHash(t, id); got != old {
		t.Errorf("stored hash changed to %q although rehashing failed", got)
	}
	if !strings.Contains(e.logs.String(), "rehash password failed") {
		t.Errorf("rehash failure not logged:\n%s", e.logs.String())
	}
}

func TestHashingBusyIsResourceExhausted(t *testing.T) {
	email := newEmail()
	newEnv(t, password.NewHasher()).register(t, email)
	e := newEnv(t, busyHasher{})

	_, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword})
	wantError(t, err, codes.ResourceExhausted, ReasonServerBusy)
	for _, em := range []string{email, newEmail()} {
		_, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: em, Password: testPassword})
		wantError(t, err, codes.ResourceExhausted, ReasonServerBusy)
	}
}

func followCount(t *testing.T, follower, followee string) int {
	t.Helper()
	var n int
	err := testPool.QueryRow(t.Context(),
		"SELECT count(*) FROM follows WHERE follower_id = $1 AND followee_id = $2", follower, followee).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestFollow(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	bob := e.register(t, newEmail())
	ctx := asCaller(t.Context(), alice)

	for range 2 {
		if _, err := e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: bob}); err != nil {
			t.Fatalf("Follow: %v", err)
		}
	}
	if n := followCount(t, alice, bob); n != 1 {
		t.Errorf("follow rows = %d after following twice, want 1", n)
	}

	_, err := e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: alice})
	wantError(t, err, codes.InvalidArgument, ReasonCannotFollowSelf)
	for _, bad := range []string{"", "not-a-uuid", strings.ToUpper(bob), "{" + bob + "}"} {
		_, err := e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: bad})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidFolloweeID)
	}
	_, err = e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: ids.New()})
	wantError(t, err, codes.NotFound, ReasonUserNotFound)
}

func TestFollowByDeletedCallerIsUnauthenticated(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	bob := e.register(t, newEmail())
	// A caller id from a still-valid token whose account is gone (database reset).
	ctx := asCaller(t.Context(), ids.New())

	for _, followee := range []string{bob, ids.New()} {
		_, err := e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: followee})
		wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
	}
}

func TestUnfollow(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	bob := e.register(t, newEmail())
	ctx := asCaller(t.Context(), alice)
	if _, err := e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: bob}); err != nil {
		t.Fatalf("Follow: %v", err)
	}

	for range 2 {
		if _, err := e.client.Unfollow(ctx, &userv1.UnfollowRequest{FolloweeId: bob}); err != nil {
			t.Fatalf("Unfollow: %v", err)
		}
	}
	if n := followCount(t, alice, bob); n != 0 {
		t.Errorf("follow rows = %d after unfollowing, want 0", n)
	}
	for _, bad := range []string{"", "not-a-uuid", strings.ToUpper(bob)} {
		_, err := e.client.Unfollow(ctx, &userv1.UnfollowRequest{FolloweeId: bad})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidFolloweeID)
	}
}

// followEvents returns the decoded outbox events keyed by follower, oldest id first, and fails
// unless every one is on TopicUserFollows.
func followEvents(t *testing.T, follower string) []*userv1.FollowEvent {
	t.Helper()
	rows, err := testPool.Query(t.Context(),
		"SELECT topic, payload FROM outbox WHERE record_key = $1 ORDER BY id", follower)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (*userv1.FollowEvent, error) {
		var topic string
		var payload []byte
		if err := r.Scan(&topic, &payload); err != nil {
			return nil, err
		}
		if topic != TopicUserFollows {
			t.Errorf("outbox topic = %q, want %q", topic, TopicUserFollows)
		}
		ev := &userv1.FollowEvent{}
		return ev, proto.Unmarshal(payload, ev)
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// wantNoEvents fails unless the outbox holds no event keyed by follower.
func wantNoEvents(t *testing.T, follower string) {
	t.Helper()
	if evs := followEvents(t, follower); len(evs) != 0 {
		t.Errorf("got %d outbox events for %s, want none: %v", len(evs), follower, evs)
	}
}

// Only a call that changes the edge writes an event, in the order of the changes.
func TestFollowEventsFollowEdgeChanges(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	bob := e.register(t, newEmail())
	ctx := asCaller(t.Context(), alice)

	steps := []struct {
		follow bool
		events int
	}{
		{follow: true, events: 1},
		{follow: true, events: 1},
		{follow: false, events: 2},
		{follow: false, events: 2},
		{follow: true, events: 3},
	}
	for i, st := range steps {
		var err error
		if st.follow {
			_, err = e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: bob})
		} else {
			_, err = e.client.Unfollow(ctx, &userv1.UnfollowRequest{FolloweeId: bob})
		}
		if err != nil {
			t.Fatalf("step %d: %v", i+1, err)
		}
		if n := len(followEvents(t, alice)); n != st.events {
			t.Fatalf("step %d: %d outbox events, want %d", i+1, n, st.events)
		}
	}

	seen := map[string]bool{}
	for i, ev := range followEvents(t, alice) {
		meta := ev.GetMeta()
		id, err := ids.Parse(meta.GetEventId())
		if err != nil || id[6]>>4 != 7 {
			t.Errorf("event %d: event_id %q is not a UUIDv7", i, meta.GetEventId())
		}
		if seen[meta.GetEventId()] {
			t.Errorf("event %d: event_id %s repeats", i, meta.GetEventId())
		}
		seen[meta.GetEventId()] = true
		if meta.GetOccurredAt() == nil {
			t.Errorf("event %d: no occurred_at", i)
		}
		var follower, followee string
		if i == 1 {
			u := ev.GetUserUnfollowed()
			if u == nil {
				t.Fatalf("event %d = %v, want user_unfollowed", i, ev)
			}
			follower, followee = u.GetFollowerId(), u.GetFolloweeId()
		} else {
			f := ev.GetUserFollowed()
			if f == nil {
				t.Fatalf("event %d = %v, want user_followed", i, ev)
			}
			follower, followee = f.GetFollowerId(), f.GetFolloweeId()
		}
		if follower != alice || followee != bob {
			t.Errorf("event %d: follower %s, followee %s, want %s, %s", i, follower, followee, alice, bob)
		}
	}
}

func TestUnfollowMissingEdgeWritesNoEvent(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	bob := e.register(t, newEmail())

	if _, err := e.client.Unfollow(asCaller(t.Context(), alice), &userv1.UnfollowRequest{FolloweeId: bob}); err != nil {
		t.Fatalf("Unfollow: %v", err)
	}
	wantNoEvents(t, alice)
}

func TestRejectedFollowWritesNoEvent(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	bob := e.register(t, newEmail())

	_, err := e.client.Follow(asCaller(t.Context(), alice), &userv1.FollowRequest{FolloweeId: ids.New()})
	wantError(t, err, codes.NotFound, ReasonUserNotFound)
	_, err = e.client.Follow(asCaller(t.Context(), alice), &userv1.FollowRequest{FolloweeId: alice})
	wantError(t, err, codes.InvalidArgument, ReasonCannotFollowSelf)
	wantNoEvents(t, alice)

	ghost := ids.New()
	_, err = e.client.Follow(asCaller(t.Context(), ghost), &userv1.FollowRequest{FolloweeId: bob})
	wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
	wantNoEvents(t, ghost)
}

// A failed outbox insert rolls the follow or unfollow back.
func TestFollowOutboxFailureRollsBack(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	bob := e.register(t, newEmail())
	carol := e.register(t, newEmail())
	ctx := asCaller(t.Context(), alice)
	if _, err := e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: carol}); err != nil {
		t.Fatalf("Follow: %v", err)
	}

	// Refuse outbox rows keyed by alice only; alice is a server-generated UUID.
	_, err := testPool.Exec(t.Context(), `
		CREATE FUNCTION refuse_test_outbox() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN
			IF NEW.record_key = '`+alice+`' THEN
				RAISE EXCEPTION 'outbox insert refused by test';
			END IF;
			RETURN NEW;
		END $$;
		CREATE TRIGGER refuse_test_outbox BEFORE INSERT ON outbox
			FOR EACH ROW EXECUTE FUNCTION refuse_test_outbox();`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, err := testPool.Exec(context.Background(),
			"DROP TRIGGER refuse_test_outbox ON outbox; DROP FUNCTION refuse_test_outbox()")
		if err != nil {
			t.Error(err)
		}
	})

	_, followErr := e.client.Follow(ctx, &userv1.FollowRequest{FolloweeId: bob})
	_, unfollowErr := e.client.Unfollow(ctx, &userv1.UnfollowRequest{FolloweeId: carol})
	for _, err := range []error{followErr, unfollowErr} {
		if status.Code(err) != codes.Internal || status.Convert(err).Message() != "internal error" {
			t.Errorf("error = %v, want INTERNAL with message %q", err, "internal error")
		}
	}
	if n := followCount(t, alice, bob); n != 0 {
		t.Errorf("follow rows alice -> bob = %d, want 0", n)
	}
	if n := followCount(t, alice, carol); n != 1 {
		t.Errorf("follow rows alice -> carol = %d, want 1", n)
	}
	if evs := followEvents(t, alice); len(evs) != 1 {
		t.Errorf("got %d outbox events for alice, want only the first follow's", len(evs))
	}
}

func TestFollowRequiresCaller(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	bob := e.register(t, newEmail())

	_, err := e.client.Follow(t.Context(), &userv1.FollowRequest{FolloweeId: bob})
	wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
	_, err = e.client.Unfollow(t.Context(), &userv1.UnfollowRequest{FolloweeId: bob})
	wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
}

func TestHealthCheckNeedsNoCaller(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	resp, err := e.health.Check(t.Context(), &healthpb.HealthCheckRequest{})
	if err != nil {
		t.Fatalf("health check without x-user-id: %v", err)
	}
	if resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
		t.Errorf("status = %v, want SERVING", resp.GetStatus())
	}
}

func TestLogsHoldNoSecrets(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := "Log.Check-" + ids.New() + "@Example.io"
	id := e.register(t, email)
	resp, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: email, Password: testPassword})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	_, err = e.client.Login(t.Context(), &userv1.LoginRequest{Email: email, Password: "wrong password!"})
	wantError(t, err, codes.Unauthenticated, ReasonInvalidCredentials)
	// Every refresh path that logs: rotation, reuse, a revoked family, logout, a malformed token.
	t0 := resp.GetRefreshToken()
	rotated := e.refresh(t, t0)
	e.wantRefreshRefused(t, t0)
	e.wantRefreshRefused(t, rotated.GetRefreshToken())
	second := e.login(t, email).GetRefreshToken()
	e.logout(t, second)
	e.wantRefreshRefused(t, second)
	e.wantRefreshRefused(t, "malformed-"+t0)

	logs := e.logs.String()
	for _, leak := range []string{email, strings.ToLower(email), testPassword, "wrong password!", resp.GetAccessToken(),
		t0, rotated.GetAccessToken(), rotated.GetRefreshToken(), second} {
		if strings.Contains(logs, leak) {
			t.Errorf("log contains %q:\n%s", leak, logs)
		}
	}
	if !strings.Contains(logs, `"user_id":"`+id+`"`) {
		t.Errorf("log does not carry user_id %s:\n%s", id, logs)
	}
}

func TestDatabaseErrorIsGeneric(t *testing.T) {
	if testPool == nil {
		t.Skip(skipReason)
	}
	// A pool that is already closed fails every query.
	closed, err := pgxpool.NewWithConfig(t.Context(), testPool.Config())
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	e := newEnv(t, password.NewHasher(), closed)

	_, regErr := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword})
	_, loginErr := e.client.Login(t.Context(), &userv1.LoginRequest{Email: newEmail(), Password: testPassword})
	_, followErr := e.client.Follow(asCaller(t.Context(), ids.New()), &userv1.FollowRequest{FolloweeId: ids.New()})
	token := newRefreshToken().value.Reveal()
	_, refreshErr := e.client.Refresh(t.Context(), &userv1.RefreshRequest{RefreshToken: token})
	_, logoutErr := e.client.Logout(t.Context(), &userv1.LogoutRequest{RefreshToken: token})
	for _, err := range []error{regErr, loginErr, followErr, refreshErr, logoutErr} {
		st := status.Convert(err)
		if st.Code() != codes.Internal || st.Message() != "internal error" || len(st.Details()) != 0 {
			t.Errorf("got %v with details %v, want INTERNAL \"internal error\" without details", err, st.Details())
		}
	}
	if !strings.Contains(e.logs.String(), "closed pool") {
		t.Errorf("database error detail missing from log:\n%s", e.logs.String())
	}
}
