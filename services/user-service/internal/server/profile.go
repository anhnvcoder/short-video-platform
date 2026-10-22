package server

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
	"uuid"

	"github.com/jackc/pgx/v5"
	"google.golang.org/grpc/codes"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/store"
)

// MaxProfileIDs is the most user ids one GetProfiles call accepts: a page of the feed holds at
// most that many authors.
const MaxProfileIDs = 50

// MaxDisplayNameRunes is the longest display name, in Unicode code points once trimmed.
const MaxDisplayNameRunes = 50

var (
	// handlePattern is the form of every stored handle, picked or generated; the database checks
	// the same pattern (users_handle_check).
	handlePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{2,29}$`)
	// generatedHandlePattern is the form the service generates. A picked handle may not have it,
	// so a picked handle never collides with a generated one.
	generatedHandlePattern = regexp.MustCompile(`^u_[0-9a-f]{12}$`)
)

// normalizeHandle trims surrounding white space and lowers ASCII A-Z only. Unicode lower-casing
// would fold distinct input together (strings.ToLower maps the Kelvin sign U+212A to "k"), so any
// other character is kept and makes the handle invalid.
func normalizeHandle(s string) string {
	b := []byte(strings.TrimSpace(s))
	for i, c := range b {
		if 'A' <= c && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}

// validPickedHandle reports whether a normalized handle may be picked by a user.
func validPickedHandle(h string) bool {
	return handlePattern.MatchString(h) && !generatedHandlePattern.MatchString(h)
}

// generatedHandle is the handle of a user who picked none: "u_" and the last 12 hex digits of the
// id. Those are 48 random bits of the UUIDv7, not its timestamp, so users created in the same
// millisecond still differ. Migration 00005 gives existing users the same form.
func generatedHandle(id uuid.UUID) string {
	s := id.String()
	return "u_" + s[len(s)-12:]
}

// normalizeDisplayName checks a display name and returns it trimmed. empty reports a name that is
// empty once trimmed, which Register replaces by the handle and UpdateDisplayName rejects; ok is
// false for a name breaking the rules (invalid UTF-8, over MaxDisplayNameRunes, a forbidden
// character, or nothing visible).
func normalizeDisplayName(s string) (name string, empty, ok bool) {
	if !utf8.ValidString(s) {
		return "", false, false
	}
	name = strings.TrimSpace(s)
	if name == "" {
		return "", true, true
	}
	if utf8.RuneCountInString(name) > MaxDisplayNameRunes {
		return "", false, false
	}
	visible := false
	for _, r := range name {
		switch {
		case isEmojiJoiner(r):
		case forbiddenInDisplayName(r):
			return "", false, false
		case !unicode.IsSpace(r):
			visible = true
		}
	}
	return name, false, visible
}

// forbiddenInDisplayName reports characters a display name may not hold:
//   - control characters (Cc: U+0000-U+001F, U+007F-U+009F), which break lines in the UI and fake
//     lines in plain-text output;
//   - the line and paragraph separators U+2028 and U+2029;
//   - format characters (Cf), among them the bidirectional controls (U+061C, U+200E, U+200F,
//     U+202A-U+202E, U+2066-U+2069): U+202E at the start of a name reverses the @handle and time
//     shown after it, which can fake another user's name. Cf also holds invisible characters such
//     as U+200B, U+2060 and U+FEFF;
//   - other default-ignorable code points, which render as nothing (Hangul fillers U+115F,
//     U+1160, U+3164, U+FFA0, the combining grapheme joiner U+034F), and the blank Braille
//     pattern U+2800, which renders as a blank too. With them a name that looks empty would pass
//     the trim.
func forbiddenInDisplayName(r rune) bool {
	return unicode.Is(unicode.Cc, r) || r == '\u2028' || r == '\u2029' || unicode.Is(unicode.Cf, r) ||
		unicode.Is(unicode.Other_Default_Ignorable_Code_Point, r) || r == '\u2800'
}

// isEmojiJoiner reports the invisible characters emoji need: the zero width joiner U+200D, which
// builds sequences such as a family, and the variation selectors, which pick the emoji form of a
// symbol. They are accepted although U+200D is Cf, but they do not count as visible, so a name of
// joiners alone is still rejected.
func isEmojiJoiner(r rune) bool {
	return r == '\u200d' || unicode.Is(unicode.Variation_Selector, r)
}

// GetProfiles returns the profiles of the given users. It needs no caller: profiles are public.
func (s *Server) GetProfiles(ctx context.Context, req *userv1.GetProfilesRequest) (*userv1.GetProfilesResponse, error) {
	raw := req.GetUserIds()
	if len(raw) > MaxProfileIDs {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonTooManyUserIDs, "at most 50 user_ids")
	}
	if len(raw) == 0 {
		return &userv1.GetProfilesResponse{}, nil
	}
	userIDs := make([]uuid.UUID, len(raw))
	for i, id := range raw {
		u, err := ids.Parse(id)
		if err != nil {
			return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidUserID, "user_ids must be canonical lowercase UUIDs")
		}
		userIDs[i] = u
	}

	rows, err := s.queries.GetProfiles(ctx, userIDs)
	if err != nil {
		return nil, s.internal(ctx, "select profiles", err)
	}
	profiles := make([]*userv1.Profile, len(rows))
	for i, r := range rows {
		profiles[i] = &userv1.Profile{UserId: r.ID.String(), Handle: r.Handle, DisplayName: r.DisplayName}
	}
	return &userv1.GetProfilesResponse{Profiles: profiles}, nil
}

// GetProfileByHandle returns the profile with the handle and whether the caller follows that user.
func (s *Server) GetProfileByHandle(ctx context.Context, req *userv1.GetProfileByHandleRequest) (*userv1.GetProfileByHandleResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	// Input that cannot be a handle has no user either: answering NOT_FOUND without a query tells
	// the client nothing more than the query would.
	handle := normalizeHandle(req.GetHandle())
	if !handlePattern.MatchString(handle) {
		return nil, userNotFound()
	}
	row, err := s.queries.GetProfileByHandle(ctx, store.GetProfileByHandleParams{CallerID: caller, Handle: handle})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, userNotFound()
	}
	if err != nil {
		return nil, s.internal(ctx, "select profile by handle", err)
	}
	return &userv1.GetProfileByHandleResponse{
		Profile:      &userv1.Profile{UserId: row.ID.String(), Handle: row.Handle, DisplayName: row.DisplayName},
		FollowedByMe: row.FollowedByMe,
	}, nil
}

// UpdateDisplayName sets the caller's display name. Setting the same name again returns the same
// profile, so a retry is harmless.
func (s *Server) UpdateDisplayName(ctx context.Context, req *userv1.UpdateDisplayNameRequest) (*userv1.UpdateDisplayNameResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	name, empty, ok := normalizeDisplayName(req.GetDisplayName())
	if empty || !ok {
		return nil, invalidDisplayName()
	}
	row, err := s.queries.UpdateDisplayName(ctx, store.UpdateDisplayNameParams{DisplayName: name, ID: caller})
	if errors.Is(err, pgx.ErrNoRows) {
		// A valid token whose account no longer exists, e.g. after a database reset.
		return nil, userNotFound()
	}
	if err != nil {
		return nil, s.internal(ctx, "update display name", err)
	}
	// The name itself stays out of the log: users may set their real name (JWT-8). The callerid
	// interceptor already put user_id into ctx.
	s.logger.InfoContext(ctx, "display name updated")
	return &userv1.UpdateDisplayNameResponse{
		Profile: &userv1.Profile{UserId: row.ID.String(), Handle: row.Handle, DisplayName: row.DisplayName},
	}, nil
}

func userNotFound() error {
	return grpcerr.New(codes.NotFound, ReasonUserNotFound, "user not found")
}

func invalidDisplayName() error {
	return grpcerr.New(codes.InvalidArgument, ReasonInvalidDisplayName,
		"display_name must be 1 to 50 characters of valid UTF-8 without control, format or invisible characters")
}
