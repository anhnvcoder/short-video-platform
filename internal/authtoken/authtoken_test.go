package authtoken

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"maps"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/anhnvcoder/svp-backend/internal/ids"
)

const testKID = "k1"

func newKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	key, err := GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func pub(key ed25519.PrivateKey) ed25519.PublicKey {
	return key.Public().(ed25519.PublicKey)
}

// validClaims returns the claims Issue would write, as a map the tests can change.
func validClaims(sub string) jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss": IssuerName,
		"aud": []string{Audience},
		"sub": sub,
		"iat": now.Unix(),
		"exp": now.Add(TTL).Unix(),
		"jti": ids.New(),
	}
}

// sign builds a token with method, claims and extra header fields, signed with key.
func sign(t testing.TB, method jwt.SigningMethod, key any, kid string, claims jwt.MapClaims, header map[string]any) string {
	t.Helper()
	tok := jwt.NewWithClaims(method, claims)
	if kid != "" {
		tok.Header["kid"] = kid
	}
	maps.Copy(tok.Header, header)
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestIssueThenVerify(t *testing.T) {
	key := newKey(t)
	userID := ids.New()
	before := time.Now().Truncate(time.Second)

	tok, exp, err := NewIssuer(testKID, key).Issue(userID)
	if err != nil {
		t.Fatal(err)
	}
	if exp.Before(before.Add(TTL)) || exp.After(time.Now().Add(TTL)) {
		t.Errorf("expires_at = %v, want about now + %v", exp, TTL)
	}

	got, err := NewVerifier(map[string]ed25519.PublicKey{testKID: pub(key)}).Verify(tok.Reveal())
	if err != nil {
		t.Fatalf("Verify() = %v", err)
	}
	if got != userID {
		t.Errorf("Verify() = %q, want %q", got, userID)
	}
}

func TestIssuedTokenContents(t *testing.T) {
	key := newKey(t)
	userID := ids.New()
	tok, exp, err := NewIssuer(testKID, key).Issue(userID)
	if err != nil {
		t.Fatal(err)
	}

	claims := jwt.MapClaims{}
	parsed, _, err := jwt.NewParser().ParseUnverified(tok.Reveal(), claims)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Header["alg"] != "EdDSA" || parsed.Header["kid"] != testKID {
		t.Errorf("header = %v, want alg EdDSA and kid %q", parsed.Header, testKID)
	}
	wantKeys := []string{"aud", "exp", "iat", "iss", "jti", "sub"}
	if len(claims) != len(wantKeys) {
		t.Errorf("claims = %v, want exactly %v", claims, wantKeys)
	}
	for _, k := range wantKeys {
		if _, ok := claims[k]; !ok {
			t.Errorf("claim %q missing", k)
		}
	}
	iat, _ := claims.GetIssuedAt()
	gotExp, _ := claims.GetExpirationTime()
	if gotExp.Sub(iat.Time) != TTL || !gotExp.Equal(exp) {
		t.Errorf("exp - iat = %v (exp %v, returned %v), want %v", gotExp.Sub(iat.Time), gotExp, exp, TTL)
	}
	if iss, _ := claims.GetIssuer(); iss != IssuerName {
		t.Errorf("iss = %q, want %q", iss, IssuerName)
	}
	if aud, _ := claims.GetAudience(); len(aud) != 1 || aud[0] != Audience {
		t.Errorf("aud = %v, want [%s]", aud, Audience)
	}
	if _, err := ids.Parse(claims["jti"].(string)); err != nil {
		t.Errorf("jti %v is not a UUID: %v", claims["jti"], err)
	}
}

func TestIssueRejectsNonUUIDSubject(t *testing.T) {
	if _, _, err := NewIssuer(testKID, newKey(t)).Issue("alice@example.com"); err == nil {
		t.Error("Issue() with a non-UUID user id succeeded")
	}
}

func TestVerifyRejectsForgedTokens(t *testing.T) {
	key := newKey(t)
	attacker := newKey(t)
	pubKey := pub(key)
	v := NewVerifier(map[string]ed25519.PublicKey{testKID: pubKey})
	userID := ids.New()
	now := time.Now()

	with := func(change func(jwt.MapClaims)) jwt.MapClaims {
		c := validClaims(userID)
		change(c)
		return c
	}
	jwkHeader := map[string]any{"jwk": map[string]any{
		"kty": "OKP", "crv": "Ed25519", "x": base64.RawURLEncoding.EncodeToString(pub(attacker)),
	}}

	valid := sign(t, jwt.SigningMethodEdDSA, key, testKID, validClaims(userID), nil)
	parts := strings.Split(valid, ".")
	sig := []byte(parts[2])
	if sig[len(sig)/2] == 'A' {
		sig[len(sig)/2] = 'B'
	} else {
		sig[len(sig)/2] = 'A'
	}
	tamperedSig := parts[0] + "." + parts[1] + "." + string(sig)
	otherSub := sign(t, jwt.SigningMethodEdDSA, key, testKID, validClaims(ids.New()), nil)
	tamperedPayload := parts[0] + "." + strings.Split(otherSub, ".")[1] + "." + parts[2]

	tests := []struct {
		name  string
		token string
	}{
		{"alg none", sign(t, jwt.SigningMethodNone, jwt.UnsafeAllowNoneSignatureType, testKID, validClaims(userID), nil)},
		{"HS256 keyed with the public key", sign(t, jwt.SigningMethodHS256, []byte(pubKey), testKID, validClaims(userID), nil)},
		{"tampered signature", tamperedSig},
		{"tampered payload", tamperedPayload},
		{"signed by another key", sign(t, jwt.SigningMethodEdDSA, attacker, testKID, validClaims(userID), nil)},
		{"expired beyond leeway", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) {
			c["iat"] = now.Add(-2 * TTL).Unix()
			c["exp"] = now.Add(-Leeway - 30*time.Second).Unix()
		}), nil)},
		{"nbf far in the future", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) {
			c["nbf"] = now.Add(24 * time.Hour).Unix()
		}), nil)},
		{"iat far in the future", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) {
			c["iat"] = now.Add(24 * time.Hour).Unix()
			c["exp"] = now.Add(25 * time.Hour).Unix()
		}), nil)},
		{"wrong aud", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) { c["aud"] = []string{"other-api"} }), nil)},
		{"missing aud", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) { delete(c, "aud") }), nil)},
		{"wrong iss", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) { c["iss"] = "other-issuer" }), nil)},
		{"missing iss", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) { delete(c, "iss") }), nil)},
		{"missing exp", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) { delete(c, "exp") }), nil)},
		{"missing kid", sign(t, jwt.SigningMethodEdDSA, key, "", validClaims(userID), nil)},
		{"unknown kid", sign(t, jwt.SigningMethodEdDSA, key, "k2", validClaims(userID), nil)},
		{"jku pointing at another key", sign(t, jwt.SigningMethodEdDSA, attacker, testKID, validClaims(userID),
			map[string]any{"jku": "https://attacker.example/jwks.json", "x5u": "https://attacker.example/cert.pem"})},
		{"embedded jwk of another key", sign(t, jwt.SigningMethodEdDSA, attacker, testKID, validClaims(userID), jwkHeader)},
		{"sub upper case", sign(t, jwt.SigningMethodEdDSA, key, testKID, validClaims(strings.ToUpper(userID)), nil)},
		{"sub not a UUID", sign(t, jwt.SigningMethodEdDSA, key, testKID, validClaims("admin"), nil)},
		{"sub missing", sign(t, jwt.SigningMethodEdDSA, key, testKID, with(func(c jwt.MapClaims) { delete(c, "sub") }), nil)},
		{"empty", ""},
		{"garbage", "not.a.token"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := v.Verify(tt.token)
			if !errors.Is(err, ErrInvalidToken) {
				t.Errorf("Verify() = (%q, %v), want ErrInvalidToken", got, err)
			}
			if got != "" {
				t.Errorf("Verify() returned user id %q with an error", got)
			}
		})
	}
}

func TestVerifyAllowsClockSkewWithinLeeway(t *testing.T) {
	key := newKey(t)
	v := NewVerifier(map[string]ed25519.PublicKey{testKID: pub(key)})
	userID := ids.New()
	now := time.Now()
	c := validClaims(userID)
	c["iat"] = now.Add(-TTL).Unix()
	c["exp"] = now.Add(-Leeway / 3).Unix()
	if _, err := v.Verify(sign(t, jwt.SigningMethodEdDSA, key, testKID, c, nil)); err != nil {
		t.Errorf("token expired %v ago rejected: %v", Leeway/3, err)
	}
	c = validClaims(userID)
	c["iat"] = now.Add(Leeway / 3).Unix()
	if _, err := v.Verify(sign(t, jwt.SigningMethodEdDSA, key, testKID, c, nil)); err != nil {
		t.Errorf("token issued %v in the future rejected: %v", Leeway/3, err)
	}
}

func TestVerifyKeyRotation(t *testing.T) {
	oldPriv, newPriv := newKey(t), newKey(t)
	oldTok, _, err := NewIssuer("old", oldPriv).Issue(ids.New())
	if err != nil {
		t.Fatal(err)
	}
	newTok, _, err := NewIssuer("new", newPriv).Issue(ids.New())
	if err != nil {
		t.Fatal(err)
	}

	both := NewVerifier(map[string]ed25519.PublicKey{"old": pub(oldPriv), "new": pub(newPriv)})
	for name, tok := range map[string]string{"old": oldTok.Reveal(), "new": newTok.Reveal()} {
		if _, err := both.Verify(tok); err != nil {
			t.Errorf("token of kid %q rejected while both keys are configured: %v", name, err)
		}
	}

	newOnly := NewVerifier(map[string]ed25519.PublicKey{"new": pub(newPriv)})
	if _, err := newOnly.Verify(newTok.Reveal()); err != nil {
		t.Errorf("new token rejected after the old key was removed: %v", err)
	}
	if _, err := newOnly.Verify(oldTok.Reveal()); !errors.Is(err, ErrInvalidToken) {
		t.Errorf("old token after the old key was removed: err = %v, want ErrInvalidToken", err)
	}
}

func TestParseSigningKey(t *testing.T) {
	key := newKey(t)
	seed := base64.StdEncoding.EncodeToString(key.Seed())

	got, err := ParseSigningKey("2026-10-11.ab", seed)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(key) {
		t.Error("ParseSigningKey() returned a different key")
	}

	for _, tt := range []struct{ name, kid, seed string }{
		{"empty kid", "", seed},
		{"kid with separator", "a:b", seed},
		{"kid with comma", "a,b", seed},
		{"empty seed", "k", ""},
		{"bad base64", "k", "not base64!"},
		// An all-0xff seed encodes to "////…" in standard base64 and "____…" in the URL alphabet.
		{"url base64", "k", base64.URLEncoding.EncodeToString(bytes.Repeat([]byte{0xff}, ed25519.SeedSize))},
		{"short seed", "k", base64.StdEncoding.EncodeToString(key.Seed()[:31])},
		{"full private key instead of seed", "k", base64.StdEncoding.EncodeToString(key)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := ParseSigningKey(tt.kid, tt.seed); err == nil {
				t.Error("ParseSigningKey() succeeded, want error")
			}
		})
	}
}

func TestParseVerifyKeys(t *testing.T) {
	k1, k2 := pub(newKey(t)), pub(newKey(t))
	b1, b2 := base64.StdEncoding.EncodeToString(k1), base64.StdEncoding.EncodeToString(k2)

	keys, err := ParseVerifyKeys("k1:" + b1 + ", k2:" + b2)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 || !keys["k1"].Equal(k1) || !keys["k2"].Equal(k2) {
		t.Errorf("ParseVerifyKeys() = %v, want k1 and k2", keys)
	}

	for _, tt := range []struct{ name, in string }{
		{"empty", ""},
		{"blank", "  "},
		{"missing colon", "k1" + b1},
		{"empty kid", ":" + b1},
		{"bad base64", "k1:%%%"},
		{"short key", "k1:" + base64.StdEncoding.EncodeToString(k1[:16])},
		{"long key", "k1:" + base64.StdEncoding.EncodeToString(append(k1, 0))},
		{"duplicate kid", "k1:" + b1 + ",k1:" + b2},
		{"trailing comma", "k1:" + b1 + ","},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got, err := ParseVerifyKeys(tt.in); err == nil {
				t.Errorf("ParseVerifyKeys(%q) = %v, want error", tt.in, got)
			}
		})
	}
}
