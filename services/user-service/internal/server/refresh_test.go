package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	userv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/user/v1"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/secret"
	"github.com/anhnvcoder/svp-backend/services/user-service/internal/password"
)

// fakeClock is a clock the test moves by hand; the server reads it from its own goroutines.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{t: time.Now().Truncate(time.Second)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// storedToken is the refresh_tokens row of a token, read by hash.
type storedToken struct {
	ID, FamilyID, UserID       string
	ExpiresAt, FamilyExpiresAt time.Time
	Used, Revoked              bool
}

func tokenHash(t *testing.T, token string) []byte {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		t.Fatalf("token %q is not base64url: %v", token, err)
	}
	sum := sha256.Sum256(raw)
	return sum[:]
}

func readToken(t *testing.T, token string) storedToken {
	t.Helper()
	var r storedToken
	err := testPool.QueryRow(t.Context(), `
		SELECT id::text, family_id::text, user_id::text, expires_at, family_expires_at,
		       used_at IS NOT NULL, revoked_at IS NOT NULL
		FROM refresh_tokens WHERE token_hash = $1`, tokenHash(t, token)).
		Scan(&r.ID, &r.FamilyID, &r.UserID, &r.ExpiresAt, &r.FamilyExpiresAt, &r.Used, &r.Revoked)
	if err != nil {
		t.Fatalf("read refresh token row: %v", err)
	}
	return r
}

// liveTokens counts the tokens of family that are not revoked.
func liveTokens(t *testing.T, family string) int {
	t.Helper()
	var n int
	err := testPool.QueryRow(t.Context(),
		"SELECT count(*) FROM refresh_tokens WHERE family_id = $1 AND revoked_at IS NULL", family).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func (e *env) login(t *testing.T, email string) *userv1.LoginResponse {
	t.Helper()
	resp, err := e.client.Login(t.Context(), &userv1.LoginRequest{Email: email, Password: testPassword})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	return resp
}

func (e *env) refresh(t *testing.T, token string) *userv1.RefreshResponse {
	t.Helper()
	resp, err := e.client.Refresh(t.Context(), &userv1.RefreshRequest{RefreshToken: token})
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	return resp
}

func (e *env) logout(t *testing.T, token string) {
	t.Helper()
	if _, err := e.client.Logout(t.Context(), &userv1.LogoutRequest{RefreshToken: token}); err != nil {
		t.Fatalf("Logout: %v", err)
	}
}

// wantInvalidRefresh fails unless err is the one error every refused refresh shares.
func wantInvalidRefresh(t *testing.T, err error) {
	t.Helper()
	wantError(t, err, codes.Unauthenticated, ReasonInvalidRefreshToken)
	if msg := status.Convert(err).Message(); msg != "invalid refresh token" {
		t.Fatalf("message = %q, want %q", msg, "invalid refresh token")
	}
}

func (e *env) wantRefreshRefused(t *testing.T, token string) {
	t.Helper()
	_, err := e.client.Refresh(t.Context(), &userv1.RefreshRequest{RefreshToken: token})
	wantInvalidRefresh(t, err)
}

func hashRefreshTokenString(v string) ([]byte, bool) {
	return hashRefreshToken(secret.New(v))
}

func TestHashRefreshToken(t *testing.T) {
	tok := newRefreshToken()
	v := tok.value.Reveal()
	if len(v) != refreshTokenLen {
		t.Fatalf("token length = %d, want %d", len(v), refreshTokenLen)
	}
	if got, ok := hashRefreshTokenString(v); !ok || !bytes.Equal(got, tok.hash) {
		t.Fatalf("hashRefreshToken(new token) = %x, %v; want %x, true", got, ok, tok.hash)
	}
	if bytes.Equal(newRefreshToken().hash, tok.hash) {
		t.Fatal("two new tokens have the same hash")
	}
	// The last character holds 4 data bits and 2 padding bits; 'B' sets a padding bit.
	nonCanonical := v[:refreshTokenLen-1] + "B"
	if v[refreshTokenLen-1] == 'B' {
		nonCanonical = v[:refreshTokenLen-1] + "C"
	}
	for _, bad := range []string{
		"",
		"short",
		strings.Repeat("A", refreshTokenLen-1),
		strings.Repeat("A", refreshTokenLen+1),
		strings.Repeat("A", 1<<20),
		strings.Repeat("A", refreshTokenLen-1) + "=",
		"+" + v[1:],
		"/" + v[1:],
		" " + v[1:],
		nonCanonical,
	} {
		if _, ok := hashRefreshTokenString(bad); ok {
			t.Errorf("hashRefreshToken(%.50q) accepted", bad)
		}
	}
}

func TestLoginIssuesRefreshToken(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	clock := newFakeClock()
	e.server.now = clock.Now
	email := newEmail()
	id := e.register(t, email)

	resp := e.login(t, email)
	token := resp.GetRefreshToken()
	if len(token) != refreshTokenLen {
		t.Fatalf("refresh_token %q has %d characters, want %d", token, len(token), refreshTokenLen)
	}
	if got, want := resp.GetRefreshExpiresAt().AsTime(), clock.Now().Add(RefreshTTL); !got.Equal(want) {
		t.Errorf("refresh_expires_at = %v, want %v", got, want)
	}
	row := readToken(t, token)
	if row.ID != row.FamilyID || row.UserID != id || row.Used || row.Revoked {
		t.Errorf("row = %+v, want a fresh token opening its own family for %s", row, id)
	}
	if !row.FamilyExpiresAt.Equal(clock.Now().Add(RefreshFamilyTTL)) || !row.ExpiresAt.Equal(resp.GetRefreshExpiresAt().AsTime()) {
		t.Errorf("row expiries %v / %v, want %v / %v", row.ExpiresAt, row.FamilyExpiresAt,
			resp.GetRefreshExpiresAt().AsTime(), clock.Now().Add(RefreshFamilyTTL))
	}

	// The database keeps the SHA-256 of the token and nothing from which the token can be read.
	raw, _ := base64.RawURLEncoding.DecodeString(token)
	var rowText string
	var hash []byte
	err := testPool.QueryRow(t.Context(), "SELECT r::text, r.token_hash FROM refresh_tokens r WHERE user_id = $1", id).
		Scan(&rowText, &hash)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(hash, tokenHash(t, token)) {
		t.Errorf("token_hash = %x, want SHA-256 of the token", hash)
	}
	for _, leak := range []string{token, hex.EncodeToString(raw)} {
		if strings.Contains(rowText, leak) {
			t.Errorf("stored row %s holds the token (%s)", rowText, leak)
		}
	}

	// A second login is a second family: it does not end the first session.
	other := e.login(t, email).GetRefreshToken()
	if readToken(t, other).FamilyID == row.FamilyID {
		t.Error("second login reused the first login's family")
	}
	e.refresh(t, token)
}

func TestRefreshRotates(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	clock := newFakeClock()
	e.server.now = clock.Now
	email := newEmail()
	id := e.register(t, email)
	t0 := e.login(t, email).GetRefreshToken()
	family := readToken(t, t0).FamilyID

	clock.Advance(time.Hour)
	before := time.Now()
	resp := e.refresh(t, t0)
	sub, err := e.verifier.Verify(resp.GetAccessToken())
	if err != nil || sub != id {
		t.Fatalf("access token subject = %q, %v; want %q", sub, err, id)
	}
	if exp := resp.GetExpiresAt().AsTime(); exp.Before(before.Add(time.Hour - 2*time.Second)) {
		t.Errorf("access expires_at = %v, want about an hour from now", exp)
	}
	t1 := resp.GetRefreshToken()
	if t1 == t0 || len(t1) != refreshTokenLen {
		t.Fatalf("new refresh token %q, want a different %d-character token", t1, refreshTokenLen)
	}
	if got, want := resp.GetRefreshExpiresAt().AsTime(), clock.Now().Add(RefreshTTL); !got.Equal(want) {
		t.Errorf("refresh_expires_at = %v, want %v (14 days from the rotation)", got, want)
	}
	if old := readToken(t, t0); !old.Used || old.Revoked {
		t.Errorf("presented token row = %+v, want used and not revoked", old)
	}
	if row := readToken(t, t1); row.FamilyID != family || row.Used || row.Revoked {
		t.Errorf("new token row = %+v, want a live token of family %s", row, family)
	}

	// The new token works in turn.
	t2 := e.refresh(t, t1).GetRefreshToken()
	if readToken(t, t2).FamilyID != family {
		t.Error("second rotation left the family")
	}
	if !strings.Contains(e.logs.String(), `"msg":"refresh token rotated"`) {
		t.Errorf("rotation not logged:\n%s", e.logs.String())
	}
}

func TestRefreshReuseRevokesFamily(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	id := e.register(t, email)
	t0 := e.login(t, email).GetRefreshToken()
	other := e.login(t, email).GetRefreshToken()
	t1 := e.refresh(t, t0).GetRefreshToken()
	family := readToken(t, t0).FamilyID

	e.wantRefreshRefused(t, t0)
	// Reuse revokes the whole family, the newest token included.
	e.wantRefreshRefused(t, t1)
	if n := liveTokens(t, family); n != 0 {
		t.Errorf("%d tokens of the family still live after reuse, want 0", n)
	}
	// Another login's family is not touched.
	e.refresh(t, other)

	logs := e.logs.String()
	var reuse string
	for line := range strings.Lines(logs) {
		if strings.Contains(line, `"msg":"refresh token reused"`) {
			reuse = line
		}
	}
	for _, want := range []string{`"level":"WARN"`, `"user_id":"` + id + `"`, `"family_id":"` + family + `"`,
		`"token_id":"` + readToken(t, t0).ID + `"`} {
		if !strings.Contains(reuse, want) {
			t.Errorf("reuse log line %q lacks %s", reuse, want)
		}
	}
	if n := strings.Count(logs, `"msg":"refresh token reused"`); n != 1 {
		t.Errorf("reuse logged %d times, want once: presenting a token of a revoked family is not reuse", n)
	}
}

func TestRefreshExpiry(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	clock := newFakeClock()
	e.server.now = clock.Now
	email := newEmail()
	e.register(t, email)
	login := clock.Now()

	// A token expires 14 days after it is issued, and refusing it changes nothing.
	idle := e.login(t, email).GetRefreshToken()
	// Each rotation slides the expiry, up to 30 days after the login.
	t0 := e.login(t, email).GetRefreshToken()
	clock.Advance(13 * 24 * time.Hour)
	resp := e.refresh(t, t0)
	if got, want := resp.GetRefreshExpiresAt().AsTime(), login.Add(27*24*time.Hour); !got.Equal(want) {
		t.Errorf("first rotation expires at %v, want %v", got, want)
	}
	clock.Advance(24 * time.Hour)
	e.wantRefreshRefused(t, idle)
	if row := readToken(t, idle); row.Used || row.Revoked {
		t.Errorf("expired token row = %+v, want neither used nor revoked", row)
	}

	clock.Advance(12 * 24 * time.Hour)
	resp = e.refresh(t, resp.GetRefreshToken())
	if got, want := resp.GetRefreshExpiresAt().AsTime(), login.Add(RefreshFamilyTTL); !got.Equal(want) {
		t.Errorf("rotation near the ceiling expires at %v, want the family's %v", got, want)
	}
	last := resp.GetRefreshToken()
	clock.Advance(4*24*time.Hour - time.Second)
	last = e.refresh(t, last).GetRefreshToken()
	clock.Advance(time.Second)
	e.wantRefreshRefused(t, last)
}

func TestRefreshInvalidTokens(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	unknown := newRefreshToken().value.Reveal()
	for _, bad := range []string{"", "x", strings.Repeat("A", 1<<16), "+" + unknown[1:], unknown + "A", unknown} {
		e.wantRefreshRefused(t, bad)
		e.logout(t, bad)
	}
}

// Malformed tokens are refused before any query: a server whose database fails every query still
// answers INVALID_REFRESH_TOKEN, and Logout still succeeds.
func TestMalformedRefreshTokenSkipsDatabase(t *testing.T) {
	e := newEnv(t, password.NewHasher(), closedPool(t))
	for _, bad := range []string{"", strings.Repeat("A", 1<<16), "+" + newRefreshToken().value.Reveal()[1:]} {
		e.wantRefreshRefused(t, bad)
		e.logout(t, bad)
	}
	if strings.Contains(e.logs.String(), "internal error") {
		t.Errorf("a malformed token reached the database:\n%s", e.logs.String())
	}
}

func TestRefreshOfDeletedUser(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	id := e.register(t, email)
	token := e.login(t, email).GetRefreshToken()
	if _, err := testPool.Exec(t.Context(), "DELETE FROM users WHERE id = $1", id); err != nil {
		t.Fatal(err)
	}
	e.wantRefreshRefused(t, token)
	e.logout(t, token)
}

func TestLogout(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	e.register(t, email)
	t0 := e.login(t, email).GetRefreshToken()
	t1 := e.refresh(t, t0).GetRefreshToken()
	family := readToken(t, t0).FamilyID

	e.logout(t, t1)
	if n := liveTokens(t, family); n != 0 {
		t.Errorf("%d tokens of the family still live after logout, want 0", n)
	}
	e.wantRefreshRefused(t, t1)
	// A used token of a revoked family is refused without counting as reuse.
	e.wantRefreshRefused(t, t0)
	// Logging out again, with any token of the family or an unknown one, still succeeds.
	e.logout(t, t1)
	e.logout(t, t0)
	e.logout(t, newRefreshToken().value.Reveal())

	logs := e.logs.String()
	if n := strings.Count(logs, `"msg":"refresh token family revoked"`); n != 1 {
		t.Errorf("revocation logged %d times, want once:\n%s", n, logs)
	}
	if strings.Contains(logs, `"msg":"refresh token reused"`) {
		t.Errorf("token of a revoked family logged as reuse:\n%s", logs)
	}
}

// N concurrent refreshes with one token: exactly one rotates it, and the others find it used, so
// they revoke the family and the token the winner got is refused too. This is intended (no grace
// window) and is why the web BFF sends one refresh at a time per session.
func TestConcurrentRefreshWithOneToken(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	e.register(t, email)
	t0 := e.login(t, email).GetRefreshToken()
	family := readToken(t, t0).FamilyID

	const n = 8
	resps := make([]*userv1.RefreshResponse, n)
	errs := make([]error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Go(func() {
			resps[i], errs[i] = e.client.Refresh(t.Context(), &userv1.RefreshRequest{RefreshToken: t0})
		})
	}
	wg.Wait()

	var winner string
	for i, err := range errs {
		switch {
		case err == nil:
			if winner != "" {
				t.Fatal("more than one concurrent refresh succeeded")
			}
			winner = resps[i].GetRefreshToken()
		case status.Code(err) == codes.Unauthenticated && grpcerr.Reason(err) == ReasonInvalidRefreshToken:
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if winner == "" {
		t.Fatal("no concurrent refresh succeeded")
	}
	e.wantRefreshRefused(t, winner)
	if live := liveTokens(t, family); live != 0 {
		t.Errorf("%d tokens of the family still live, want 0", live)
	}
}

// A rotation of the newest token racing a logout, or the reuse of an ancestor token, never leaves
// a live descendant behind: the family lock orders them, and whichever runs second revokes or is
// refused.
func TestRefreshRacesWithRevocation(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	email := newEmail()
	e.register(t, email)

	races := map[string]func(t0, t1 string) error{
		"logout": func(_, t1 string) error {
			_, err := e.client.Logout(t.Context(), &userv1.LogoutRequest{RefreshToken: t1})
			return err
		},
		"reuse of ancestor": func(t0, _ string) error {
			_, err := e.client.Refresh(t.Context(), &userv1.RefreshRequest{RefreshToken: t0})
			if status.Code(err) == codes.Unauthenticated && grpcerr.Reason(err) == ReasonInvalidRefreshToken {
				return nil
			}
			return err
		},
	}
	for name, revoke := range races {
		t.Run(name, func(t *testing.T) {
			for range 15 {
				t0 := e.login(t, email).GetRefreshToken()
				t1 := e.refresh(t, t0).GetRefreshToken()
				family := readToken(t, t0).FamilyID

				var resp *userv1.RefreshResponse
				var refreshErr, revokeErr error
				var wg sync.WaitGroup
				wg.Go(func() { resp, refreshErr = e.client.Refresh(t.Context(), &userv1.RefreshRequest{RefreshToken: t1}) })
				wg.Go(func() { revokeErr = revoke(t0, t1) })
				wg.Wait()

				if revokeErr != nil {
					t.Fatalf("revoking side: %v", revokeErr)
				}
				if refreshErr == nil {
					e.wantRefreshRefused(t, resp.GetRefreshToken())
				} else {
					wantInvalidRefresh(t, refreshErr)
				}
				if live := liveTokens(t, family); live != 0 {
					t.Fatalf("%d tokens of the family still live after the race, want 0", live)
				}
			}
		})
	}
}

// closedPool returns a pool that fails every query.
func closedPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	if testPool == nil {
		t.Skip(skipReason)
	}
	closed, err := pgxpool.NewWithConfig(t.Context(), testPool.Config())
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	return closed
}
