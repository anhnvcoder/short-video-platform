package ids

import (
	"errors"
	"testing"
)

func TestNewIsCanonicalV7(t *testing.T) {
	s := New()
	u, err := Parse(s)
	if err != nil {
		t.Fatalf("Parse(New()) = %v", err)
	}
	if v := u[6] >> 4; v != 7 {
		t.Errorf("version = %d, want 7", v)
	}
	if s == New() {
		t.Error("two calls to New() returned the same id")
	}
}

func TestParseRejectsNonCanonicalForms(t *testing.T) {
	const canonical = "01928c6e-7b3a-7cde-8f01-23456789abcd"
	if _, err := Parse(canonical); err != nil {
		t.Fatalf("Parse(%q) = %v, want nil", canonical, err)
	}
	for _, s := range []string{
		"",
		"01928C6E-7B3A-7CDE-8F01-23456789ABCD",
		"{01928c6e-7b3a-7cde-8f01-23456789abcd}",
		"urn:uuid:01928c6e-7b3a-7cde-8f01-23456789abcd",
		"01928c6e7b3a7cde8f0123456789abcd",
		" 01928c6e-7b3a-7cde-8f01-23456789abcd",
		"01928c6e-7b3a-7cde-8f01-23456789abc",
		"not-a-uuid",
	} {
		if _, err := Parse(s); !errors.Is(err, ErrInvalid) {
			t.Errorf("Parse(%q) error = %v, want ErrInvalid", s, err)
		}
	}
}
