package main

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/anhnvcoder/svp-backend/internal/authtoken"
	"github.com/anhnvcoder/svp-backend/internal/ids"
)

func TestOutputParsesAndSignsVerifiableTokens(t *testing.T) {
	var buf bytes.Buffer
	if err := run(&buf, time.Date(2026, 10, 11, 23, 0, 0, 0, time.FixedZone("ICT", 7*3600))); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("got %d lines, want 3:\n%s", len(lines), buf.String())
	}
	env := map[string]string{}
	for i, name := range []string{"JWT_SIGNING_KID", "JWT_SIGNING_KEY", "JWT_VERIFY_KEYS"} {
		k, v, ok := strings.Cut(lines[i], "=")
		if !ok || k != name || v == "" {
			t.Fatalf("line %d = %q, want %s=<value>", i+1, lines[i], name)
		}
		env[k] = v
	}

	kid := env["JWT_SIGNING_KID"]
	if !strings.HasPrefix(kid, "20261011-") || len(kid) != len("20261011-")+8 {
		t.Errorf("kid = %q, want 20261011-<8 hex> (UTC date)", kid)
	}
	key, err := authtoken.ParseSigningKey(kid, env["JWT_SIGNING_KEY"])
	if err != nil {
		t.Fatalf("ParseSigningKey() = %v", err)
	}
	keys, err := authtoken.ParseVerifyKeys(env["JWT_VERIFY_KEYS"])
	if err != nil {
		t.Fatalf("ParseVerifyKeys() = %v", err)
	}
	if _, ok := keys[kid]; !ok || len(keys) != 1 {
		t.Fatalf("verify keys = %v, want only kid %q", keys, kid)
	}

	userID := ids.New()
	tok, _, err := authtoken.NewIssuer(kid, key).Issue(userID)
	if err != nil {
		t.Fatal(err)
	}
	got, err := authtoken.NewVerifier(keys).Verify(tok.Reveal())
	if err != nil || got != userID {
		t.Errorf("Verify() = (%q, %v), want (%q, nil)", got, err, userID)
	}
}

func TestEachRunMakesANewKey(t *testing.T) {
	var a, b bytes.Buffer
	now := time.Now()
	if err := run(&a, now); err != nil {
		t.Fatal(err)
	}
	if err := run(&b, now); err != nil {
		t.Fatal(err)
	}
	if a.String() == b.String() {
		t.Error("two runs printed the same key")
	}
}
