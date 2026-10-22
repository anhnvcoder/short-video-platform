package server

import (
	"slices"
	"strings"
	"sync"
	"testing"
	"uuid"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/password"
)

func TestPickedHandleRules(t *testing.T) {
	valid := map[string]string{
		"Alice":                          "alice",
		" \tbob \n":                      "bob",
		"abc":                            "abc",
		"u_bob":                          "u_bob",
		"u_0123456789abc":                "u_0123456789abc", // 13 hex digits: not the generated form
		"a_1":                            "a_1",
		strings.Repeat("x", 30):          strings.Repeat("x", 30),
		"Z" + strings.Repeat("9", 29):    "z" + strings.Repeat("9", 29),
		"u_0123456789aB_":                "u_0123456789ab_",
		"\u00a0carol\u3000":              "carol", // TrimSpace trims Unicode white space too
		"MiXeD_Case_1":                   "mixed_case_1",
		"\u2003dave":                     "dave",
		strings.ToUpper("u_0123456789g"): "u_0123456789g",
	}
	for in, want := range valid {
		got := normalizeHandle(in)
		if got != want || !validPickedHandle(got) {
			t.Errorf("normalizeHandle(%q) = %q (valid %v), want %q valid", in, got, validPickedHandle(got), want)
		}
	}
	invalid := []string{
		"_bob",
		"1bob",
		"ab",
		strings.Repeat("x", 31),
		"bób",
		"bo b",
		"bob-x",
		"bob.x",
		"u_0123456789ab",
		"U_0123456789AB",
		"\u212aelvin", // Kelvin sign: must not fold to "kelvin"
		"bob\x00",
		"bob\n\n" + "x",
	}
	for _, in := range invalid {
		if got := normalizeHandle(in); validPickedHandle(got) {
			t.Errorf("normalizeHandle(%q) = %q accepted, want rejected", in, got)
		}
	}
	if got := normalizeHandle("   "); got != "" {
		t.Errorf("normalizeHandle of white space = %q, want empty (none picked)", got)
	}
}

func TestGeneratedHandle(t *testing.T) {
	id, err := ids.Parse("01928c6e-7b3a-7cde-8f01-23456789abcd")
	if err != nil {
		t.Fatal(err)
	}
	h := generatedHandle(id)
	if h != "u_23456789abcd" {
		t.Fatalf("generatedHandle = %q, want u_23456789abcd", h)
	}
	if !handlePattern.MatchString(h) || validPickedHandle(h) {
		t.Errorf("%q must match the stored form and not be pickable", h)
	}
}

func TestDisplayNameRules(t *testing.T) {
	// 50 runes of NFC Vietnamese with diacritics: "Phương" is 6 runes, 8 bytes per rune at most.
	vi50 := strings.Repeat("Phương", 8) + "ễ" + "ộ"
	if n := len([]rune(vi50)); n != 50 {
		t.Fatalf("vi50 has %d runes", n)
	}
	valid := map[string]string{
		"Alice":                 "Alice",
		"  Nguyễn Văn A \t":     "Nguyễn Văn A",
		vi50:                    vi50,
		" " + vi50 + " ":        vi50,
		"a b":                   "a b",
		"👨\u200d👩\u200d👧":       "👨\u200d👩\u200d👧",    // emoji ZWJ sequence
		"\u2764\ufe0f":          "\u2764\ufe0f",       // heart with emoji variation selector
		"<script>x</script>":    "<script>x</script>", // stored as text, escaped where shown
		"\u00a0x":               "x",
		"x\u0085":               "x", // U+0085 is white space too, so trailing it is trimmed
		"日本語の名前":                "日本語の名前",
		strings.Repeat("😀", 50): strings.Repeat("😀", 50),
	}
	for in, want := range valid {
		got, empty, ok := normalizeDisplayName(in)
		if got != want || empty || !ok {
			t.Errorf("normalizeDisplayName(%q) = %q, %v, %v; want %q, false, true", in, got, empty, ok, want)
		}
	}
	for _, in := range []string{"", "   ", "\t\n", "\u3000"} {
		if _, empty, ok := normalizeDisplayName(in); !empty || !ok {
			t.Errorf("normalizeDisplayName(%q) = empty %v, ok %v; want empty", in, empty, ok)
		}
	}
	invalid := []string{
		vi50 + "a",              // 51 runes
		strings.Repeat("😀", 51), // 51 runes
		"a\nb",
		"a\tb",
		"a\rb",
		"a\x00b",
		"a\x7fb",
		"a\u0085b",
		"a\u009fb",
		"a\u2028b",
		"a\u2029b",
		"\u202eevil",
		"a\u202ab",
		"a\u061cb",
		"a\u200eb",
		"a\u200fb",
		"a\u2066b",
		"a\u2069b",
		"\xff",
		"ab\xc3",
		"\u200b",
		"a\u200bb",
		"\u2060",
		"\ufeffa",
		"\u3164",
		"a\u115fb",
		"\uffa0",
		"a\u034fb",
		"\u2800",
		"a\u00adb", // soft hyphen, Cf
		"\u200d",   // a joiner alone is invisible
		"\ufe0f\u200d",
	}
	for _, in := range invalid {
		if got, empty, ok := normalizeDisplayName(in); ok {
			t.Errorf("normalizeDisplayName(%q) = %q, empty %v accepted, want rejected", in, got, empty)
		}
	}
}

func (e *env) profiles(t *testing.T, userIDs ...string) map[string]*userv1.Profile {
	t.Helper()
	resp, err := e.client.GetProfiles(t.Context(), &userv1.GetProfilesRequest{UserIds: userIDs})
	if err != nil {
		t.Fatalf("GetProfiles: %v", err)
	}
	out := map[string]*userv1.Profile{}
	for _, p := range resp.GetProfiles() {
		if _, dup := out[p.GetUserId()]; dup {
			t.Errorf("GetProfiles answered %s twice", p.GetUserId())
		}
		out[p.GetUserId()] = p
	}
	return out
}

func (e *env) profile(t *testing.T, userID string) *userv1.Profile {
	t.Helper()
	p := e.profiles(t, userID)[userID]
	if p == nil {
		t.Fatalf("no profile for %s", userID)
	}
	return p
}

// newHandle returns a picked handle no other test uses.
func newHandle() string {
	return "h_" + strings.ReplaceAll(ids.New(), "-", "")[:20]
}

func TestRegisterWithProfile(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	h := newHandle()
	resp, err := e.client.Register(t.Context(), &userv1.RegisterRequest{
		Email: newEmail(), Password: testPassword, Handle: "  " + strings.ToUpper(h) + " ", DisplayName: "  Nguyễn Văn A ",
	})
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	p := e.profile(t, resp.GetUserId())
	if p.GetHandle() != h || p.GetDisplayName() != "Nguyễn Văn A" {
		t.Errorf("profile = %v, want handle %q and the trimmed display name", p, h)
	}

	// A picked handle without a display name: the name is the handle.
	h2 := newHandle()
	resp, err = e.client.Register(t.Context(), &userv1.RegisterRequest{
		Email: newEmail(), Password: testPassword, Handle: h2, DisplayName: " \t ",
	})
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if p := e.profile(t, resp.GetUserId()); p.GetHandle() != h2 || p.GetDisplayName() != h2 {
		t.Errorf("profile = %v, want handle and display name %q", p, h2)
	}
}

func TestRegisterGeneratesHandle(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	for _, handle := range []string{"", "   "} {
		id := e.register(t, newEmail())
		if handle != "" {
			resp, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, Handle: handle})
			if err != nil {
				t.Fatalf("Register: %v", err)
			}
			id = resp.GetUserId()
		}
		p := e.profile(t, id)
		want := "u_" + id[len(id)-12:]
		if p.GetHandle() != want || p.GetDisplayName() != want {
			t.Errorf("profile = %v, want handle and display name %q", p, want)
		}
	}
	resp, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, DisplayName: "Bob"})
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if p := e.profile(t, resp.GetUserId()); !generatedHandlePattern.MatchString(p.GetHandle()) || p.GetDisplayName() != "Bob" {
		t.Errorf("profile = %v, want a generated handle and display name Bob", p)
	}
}

func TestRegisterRejectsBadProfile(t *testing.T) {
	// busyHasher fails every hash: getting a validation error proves the check ran before hashing.
	e := newEnv(t, busyHasher{})
	for _, bad := range []string{"_bob", "ab", "bób", "u_0123456789ab", "U_0123456789AB", strings.Repeat("x", 31)} {
		_, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, Handle: bad})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidHandle)
	}
	for _, bad := range []string{"a\nb", "\u202eevil", "\u200b", strings.Repeat("ộ", 51)} {
		_, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, DisplayName: bad})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidDisplayName)
	}
	// gRPC refuses to marshal a proto3 string that is not UTF-8, so invalid UTF-8 can only reach
	// the handler from another transport; it is called directly to check that layer.
	_, err := e.server.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, DisplayName: "\xff"})
	wantError(t, err, codes.InvalidArgument, ReasonInvalidDisplayName)

	// Checked in the order email, password, handle, display name.
	_, err = e.client.Register(t.Context(), &userv1.RegisterRequest{Email: "bad", Password: "short", Handle: "_", DisplayName: "\n"})
	wantError(t, err, codes.InvalidArgument, ReasonInvalidEmail)
	_, err = e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: "short", Handle: "_", DisplayName: "\n"})
	wantError(t, err, codes.InvalidArgument, ReasonInvalidPassword)
	_, err = e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, Handle: "_", DisplayName: "\n"})
	wantError(t, err, codes.InvalidArgument, ReasonInvalidHandle)
}

func TestRegisterHandleTaken(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	h := newHandle()
	if _, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, Handle: h}); err != nil {
		t.Fatalf("Register: %v", err)
	}
	_, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, Handle: strings.ToUpper(h)})
	wantError(t, err, codes.AlreadyExists, ReasonHandleAlreadyTaken)
}

func TestRegisterSameHandleConcurrently(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	h := newHandle()
	handles := []string{h, strings.ToUpper(h)}
	errs := make([]error, len(handles))
	var wg sync.WaitGroup
	for i, handle := range handles {
		wg.Go(func() {
			_, errs[i] = e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, Handle: handle})
		})
	}
	wg.Wait()

	var ok, taken int
	for _, err := range errs {
		switch {
		case err == nil:
			ok++
		case status.Code(err) == codes.AlreadyExists && grpcerr.Reason(err) == ReasonHandleAlreadyTaken:
			taken++
		default:
			t.Errorf("unexpected error: %v", err)
		}
	}
	if ok != 1 || taken != 1 {
		t.Fatalf("got %d successes and %d HANDLE_ALREADY_TAKEN, want 1 and 1", ok, taken)
	}
}

// idSequence returns a newID that hands out ids in order, then fails the test.
func idSequence(t *testing.T, seq ...uuid.UUID) func() uuid.UUID {
	var mu sync.Mutex
	return func() uuid.UUID {
		mu.Lock()
		defer mu.Unlock()
		if len(seq) == 0 {
			t.Error("newID called more often than expected")
			return uuid.NewV7()
		}
		id := seq[0]
		seq = seq[1:]
		return id
	}
}

// withSuffix returns a fresh UUIDv7 whose last 12 hex digits are those of other, so both get the
// same generated handle.
func withSuffix(t *testing.T, other uuid.UUID) uuid.UUID {
	t.Helper()
	s := uuid.NewV7().String()
	o := other.String()
	id, err := ids.Parse(s[:len(s)-12] + o[len(o)-12:])
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestRegisterRetriesGeneratedHandleCollision(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	taken, err := ids.Parse(e.register(t, newEmail()))
	if err != nil {
		t.Fatal(err)
	}
	fresh := uuid.NewV7()
	e.server.newID = idSequence(t, withSuffix(t, taken), withSuffix(t, taken), fresh)

	resp, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword})
	if err != nil {
		t.Fatalf("Register after two collisions: %v", err)
	}
	if resp.GetUserId() != fresh.String() {
		t.Errorf("user_id = %s, want the third id %s", resp.GetUserId(), fresh)
	}
	if p := e.profile(t, fresh.String()); p.GetHandle() != generatedHandle(fresh) {
		t.Errorf("handle = %q, want %q", p.GetHandle(), generatedHandle(fresh))
	}
}

func TestRegisterGivesUpAfterThreeCollisions(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	taken, err := ids.Parse(e.register(t, newEmail()))
	if err != nil {
		t.Fatal(err)
	}
	e.server.newID = idSequence(t, withSuffix(t, taken), withSuffix(t, taken), withSuffix(t, taken))

	email := newEmail()
	_, err = e.client.Register(t.Context(), &userv1.RegisterRequest{Email: email, Password: testPassword})
	if st := status.Convert(err); st.Code() != codes.Internal || st.Message() != "internal error" {
		t.Fatalf("err = %v, want INTERNAL \"internal error\"", err)
	}
	e.server.newID = uuid.NewV7
	e.register(t, email) // nothing of the failed call was stored
}

func TestGetProfiles(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	bob := e.register(t, newEmail())

	got := e.profiles(t, bob, alice, bob, ids.New())
	if len(got) != 2 || got[alice] == nil || got[bob] == nil {
		t.Fatalf("profiles = %v, want alice and bob once each", got)
	}
	if got[alice].GetHandle() != generatedHandle(uuid.MustParse(alice)) {
		t.Errorf("alice = %v", got[alice])
	}
	if got := e.profiles(t); len(got) != 0 {
		t.Errorf("empty request returned %v", got)
	}

	full := make([]string, MaxProfileIDs)
	for i := range full {
		full[i] = ids.New()
	}
	full[0] = alice
	if got := e.profiles(t, full...); len(got) != 1 {
		t.Errorf("%d ids: got %d profiles, want 1", MaxProfileIDs, len(got))
	}
	_, err := e.client.GetProfiles(t.Context(), &userv1.GetProfilesRequest{UserIds: append(full, alice)})
	wantError(t, err, codes.InvalidArgument, ReasonTooManyUserIDs)
	for _, bad := range []string{"", "not-a-uuid", strings.ToUpper(alice), "{" + alice + "}"} {
		_, err := e.client.GetProfiles(t.Context(), &userv1.GetProfilesRequest{UserIds: []string{alice, bad}})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidUserID)
	}
}

func TestGetProfilesNeedsNoCaller(t *testing.T) {
	if !slices.Contains(PublicMethods, userv1.UserService_GetProfiles_FullMethodName) {
		t.Fatal("GetProfiles is not in PublicMethods")
	}
	// t.Context() carries no x-user-id, and a malformed one is ignored on a public RPC.
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	if p := e.profile(t, alice); p.GetUserId() != alice {
		t.Errorf("profile = %v", p)
	}
	if _, err := e.client.GetProfiles(asCaller(t.Context(), "garbage"), &userv1.GetProfilesRequest{UserIds: []string{alice}}); err != nil {
		t.Errorf("GetProfiles with a malformed x-user-id: %v", err)
	}
}

func TestGetProfileByHandle(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	h := newHandle()
	resp, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: newEmail(), Password: testPassword, Handle: h, DisplayName: "Alice"})
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	alice := resp.GetUserId()
	bob := e.register(t, newEmail())

	byHandle := func(caller, handle string) *userv1.GetProfileByHandleResponse {
		t.Helper()
		resp, err := e.client.GetProfileByHandle(asCaller(t.Context(), caller), &userv1.GetProfileByHandleRequest{Handle: handle})
		if err != nil {
			t.Fatalf("GetProfileByHandle(%q): %v", handle, err)
		}
		return resp
	}
	got := byHandle(bob, " "+strings.ToUpper(h)+"\t")
	if p := got.GetProfile(); p.GetUserId() != alice || p.GetHandle() != h || p.GetDisplayName() != "Alice" || got.GetFollowedByMe() {
		t.Errorf("bob reads alice = %v, want alice, not followed", got)
	}
	if _, err := e.client.Follow(asCaller(t.Context(), bob), &userv1.FollowRequest{FolloweeId: alice}); err != nil {
		t.Fatalf("Follow: %v", err)
	}
	if !byHandle(bob, h).GetFollowedByMe() {
		t.Error("followed_by_me = false after bob followed alice")
	}
	if byHandle(alice, h).GetFollowedByMe() {
		t.Error("followed_by_me = true for the caller's own profile")
	}
	// A generated handle is found too.
	if p := byHandle(alice, generatedHandle(uuid.MustParse(bob))).GetProfile(); p.GetUserId() != bob {
		t.Errorf("by generated handle = %v, want bob", p)
	}

	for _, missing := range []string{newHandle(), "", "_x", "ab", "bób", strings.Repeat("x", 31), "\u212a" + h[1:]} {
		_, err := e.client.GetProfileByHandle(asCaller(t.Context(), bob), &userv1.GetProfileByHandleRequest{Handle: missing})
		wantError(t, err, codes.NotFound, ReasonUserNotFound)
	}
	_, err = e.client.GetProfileByHandle(t.Context(), &userv1.GetProfileByHandleRequest{Handle: h})
	wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
}

func TestUpdateDisplayName(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	alice := e.register(t, newEmail())
	ctx := asCaller(t.Context(), alice)

	for range 2 {
		resp, err := e.client.UpdateDisplayName(ctx, &userv1.UpdateDisplayNameRequest{DisplayName: "  Trần Thị Bình "})
		if err != nil {
			t.Fatalf("UpdateDisplayName: %v", err)
		}
		p := resp.GetProfile()
		if p.GetUserId() != alice || p.GetDisplayName() != "Trần Thị Bình" || p.GetHandle() != generatedHandle(uuid.MustParse(alice)) {
			t.Errorf("profile = %v", p)
		}
	}
	if p := e.profile(t, alice); p.GetDisplayName() != "Trần Thị Bình" {
		t.Errorf("stored display name = %q", p.GetDisplayName())
	}

	// Invalid UTF-8 cannot be sent over gRPC; normalizeDisplayName's test covers it.
	for _, bad := range []string{"", "   ", "a\nb", "\u202eevil", "\u3164", strings.Repeat("ộ", 51)} {
		_, err := e.client.UpdateDisplayName(ctx, &userv1.UpdateDisplayNameRequest{DisplayName: bad})
		wantError(t, err, codes.InvalidArgument, ReasonInvalidDisplayName)
	}
	if p := e.profile(t, alice); p.GetDisplayName() != "Trần Thị Bình" {
		t.Errorf("display name changed by a rejected call to %q", p.GetDisplayName())
	}

	_, err := e.client.UpdateDisplayName(asCaller(t.Context(), ids.New()), &userv1.UpdateDisplayNameRequest{DisplayName: "Ghost"})
	wantError(t, err, codes.NotFound, ReasonUserNotFound)
	_, err = e.client.UpdateDisplayName(t.Context(), &userv1.UpdateDisplayNameRequest{DisplayName: "Nobody"})
	wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
}

func TestProfileLogsHoldNoDisplayName(t *testing.T) {
	e := newEnv(t, password.NewHasher())
	name := "Secret Name " + ids.New()
	email := newEmail()
	resp, err := e.client.Register(t.Context(), &userv1.RegisterRequest{Email: email, Password: testPassword, Handle: newHandle(), DisplayName: name})
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	id := resp.GetUserId()
	renamed := "Other Name " + ids.New()
	if _, err := e.client.UpdateDisplayName(asCaller(t.Context(), id), &userv1.UpdateDisplayNameRequest{DisplayName: renamed}); err != nil {
		t.Fatalf("UpdateDisplayName: %v", err)
	}
	logs := e.logs.String()
	for _, leak := range []string{name, renamed, email} {
		if strings.Contains(logs, leak) {
			t.Errorf("log contains %q:\n%s", leak, logs)
		}
	}
	if !strings.Contains(logs, `"msg":"display name updated"`) || !strings.Contains(logs, `"user_id":"`+id+`"`) {
		t.Errorf("update not logged with user_id %s:\n%s", id, logs)
	}
}

// Input that cannot be a handle is answered without the database: a closed pool would fail.
func TestGetProfileByHandleMalformedSkipsDatabase(t *testing.T) {
	e := newEnv(t, password.NewHasher(), closedPool(t))
	ctx := asCaller(t.Context(), ids.New())
	for _, bad := range []string{"", "_x", "bób"} {
		_, err := e.client.GetProfileByHandle(ctx, &userv1.GetProfileByHandleRequest{Handle: bad})
		wantError(t, err, codes.NotFound, ReasonUserNotFound)
	}
	// An empty list does not read the database either.
	if _, err := e.client.GetProfiles(t.Context(), &userv1.GetProfilesRequest{}); err != nil {
		t.Errorf("GetProfiles with no ids: %v", err)
	}
	_, err := e.client.GetProfileByHandle(ctx, &userv1.GetProfileByHandleRequest{Handle: "valid_handle"})
	if status.Code(err) != codes.Internal {
		t.Errorf("valid handle on a closed pool: %v, want INTERNAL (the database is read)", err)
	}
}
