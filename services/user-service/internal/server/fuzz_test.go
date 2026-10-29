package server

import (
	"net/mail"
	"regexp"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

// The handle contract written out again, apart from profile.go, so the fuzz targets do not check
// a function against itself.
var (
	fuzzHandleForm    = regexp.MustCompile(`^[a-z][a-z0-9_]{2,29}$`)
	fuzzGeneratedForm = regexp.MustCompile(`^u_[0-9a-f]{12}$`)
)

func FuzzHandle(f *testing.F) {
	for _, s := range []string{
		"alice", " Alice ", "ALICE_99", "u_name", "u_0123456789ab", "U_0123456789AB",
		"\u212aate", // Kelvin sign: must not fold to "kate"
		"ab", "abc", strings.Repeat("a", 30), strings.Repeat("a", 31),
		"9lives", "_alice", "al-ice", "alice\x00", "\talice\n", "",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		h := normalizeHandle(s)
		if again := normalizeHandle(h); again != h {
			t.Errorf("normalizeHandle(%q) = %q, normalized again %q", s, h, again)
		}
		if strings.ContainsAny(h, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") {
			t.Errorf("normalizeHandle(%q) = %q keeps an upper-case ASCII letter", s, h)
		}
		want := fuzzHandleForm.MatchString(h) && !fuzzGeneratedForm.MatchString(h)
		if got := validPickedHandle(h); got != want {
			t.Errorf("validPickedHandle(%q) = %v, want %v", h, got, want)
		}
	})
}

func FuzzEmail(f *testing.F) {
	for _, s := range []string{
		"alice@example.com", " Alice@Example.COM ", "Alice <alice@example.com>", "<alice@example.com>",
		"alice", "@example.com", "alice@", `"a b"@example.com`, "alice@[192.0.2.1]", "a@b@c",
		"alice@example.com\n", "\u212a@example.com", strings.Repeat("a", MaxEmailBytes-len("@example.io")) + "@example.io",
		strings.Repeat("a", MaxEmailBytes+1-len("@example.io")) + "@example.io", "",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		e, ok := normalizeEmail(s)
		if !ok {
			if e != "" {
				t.Errorf("normalizeEmail(%q) = (%q, false), want an empty address with false", s, e)
			}
			return
		}
		if again, okAgain := normalizeEmail(e); again != e || !okAgain {
			t.Errorf("normalizeEmail(%q) = %q, normalized again (%q, %v)", s, e, again, okAgain)
		}
		if len(e) > MaxEmailBytes || e != strings.TrimSpace(e) || e != strings.ToLower(e) {
			t.Errorf("normalizeEmail(%q) = %q: over %d bytes, not trimmed or not lower case", s, e, MaxEmailBytes)
		}
		addr, err := mail.ParseAddress(e)
		if err != nil || addr.Name != "" || addr.Address != e {
			t.Errorf("normalizeEmail(%q) = %q, which is not a bare address: %v, %+v", s, e, err, addr)
		}
	})
}

// fuzzJoiner and fuzzForbidden are the display name's character rules written out again from
// the unicode tables, apart from profile.go.
func fuzzJoiner(r rune) bool {
	return r == '\u200d' || unicode.In(r, unicode.Variation_Selector)
}

func fuzzForbidden(r rune) bool {
	return unicode.In(r, unicode.Cc, unicode.Cf, unicode.Other_Default_Ignorable_Code_Point) ||
		r == '\u2028' || r == '\u2029' || r == '\u2800'
}

func FuzzDisplayName(f *testing.F) {
	family := "\U0001F468\u200d\U0001F469\u200d\U0001F467"
	for _, s := range []string{
		"Alice", "  Alice  ", "\u202eAlice", "\u200d", "\u200d\u200d", "\u3164", "\u2800", family, "\u2764\ufe0f",
		strings.Repeat("\u00e9", MaxDisplayNameRunes), strings.Repeat("\u00e9", MaxDisplayNameRunes+1), " " + strings.Repeat("a", 50) + " ",
		"a\u2028b", "a\x00b", "\xff", "", " \t ",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		n, empty, ok := normalizeDisplayName(s)

		// The expected verdict, from the rules alone.
		trimmed := strings.TrimSpace(s)
		wantEmpty := utf8.ValidString(s) && trimmed == ""
		wantOK := wantEmpty
		if utf8.ValidString(s) && trimmed != "" && utf8.RuneCountInString(trimmed) <= MaxDisplayNameRunes {
			allowed, visible := true, false
			for _, r := range trimmed {
				switch {
				case fuzzJoiner(r):
				case fuzzForbidden(r):
					allowed = false
				case !unicode.IsSpace(r):
					visible = true
				}
			}
			wantOK = allowed && visible
		}
		if empty != wantEmpty || ok != wantOK {
			t.Fatalf("normalizeDisplayName(%q) = (%q, empty %v, ok %v), want empty %v, ok %v", s, n, empty, ok, wantEmpty, wantOK)
		}

		switch {
		case !ok:
			// n is not checked: both callers drop it when ok is false.
		case empty:
			if n != "" {
				t.Errorf("normalizeDisplayName(%q) = %q with empty true", s, n)
			}
		default:
			if n != trimmed {
				t.Errorf("normalizeDisplayName(%q) = %q, want the trimmed input %q", s, n, trimmed)
			}
			if again, e, o := normalizeDisplayName(n); again != n || e || !o {
				t.Errorf("normalizeDisplayName(%q) = %q, normalized again (%q, %v, %v)", s, n, again, e, o)
			}
		}
	})
}
