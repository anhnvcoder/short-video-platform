package authtoken

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"

	"github.com/anhnvcoder/svp-backend/internal/ids"
)

// The fuzz keys come from fixed seeds, so the coordinator and every worker process verify with
// the same key. They sign nothing outside this test.
var (
	fuzzKey      = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{7}, ed25519.SeedSize))
	fuzzAttacker = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, ed25519.SeedSize))
)

// signedByFuzzKey reports whether token is three segments whose header names alg EdDSA and kid
// testKID and whose signature over the first two segments verifies with fuzzKey. It checks what
// a passing token must be, without the jwt library: the signature segment is decoded as the
// library does, as unpadded base64url that tolerates nonzero trailing bits.
func signedByFuzzKey(token string) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	var header map[string]any
	if json.Unmarshal(raw, &header) != nil || header["alg"] != "EdDSA" || header["kid"] != testKID {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	return ed25519.Verify(pub(fuzzKey), []byte(parts[0]+"."+parts[1]), sig)
}

func FuzzVerify(f *testing.F) {
	v := NewVerifier(map[string]ed25519.PublicKey{testKID: pub(fuzzKey)})
	userID := ids.New()
	issued, _, err := NewIssuer(testKID, fuzzKey).Issue(userID)
	if err != nil {
		f.Fatal(err)
	}
	with := func(change func(jwt.MapClaims)) jwt.MapClaims {
		c := validClaims(userID)
		change(c)
		return c
	}
	jwkHeader := map[string]any{"jwk": map[string]any{
		"kty": "OKP", "crv": "Ed25519", "x": base64.RawURLEncoding.EncodeToString(pub(fuzzAttacker)),
	}}
	for _, s := range []string{
		issued.Reveal(),
		sign(f, jwt.SigningMethodNone, jwt.UnsafeAllowNoneSignatureType, testKID, validClaims(userID), nil),
		sign(f, jwt.SigningMethodHS256, []byte(pub(fuzzKey)), testKID, validClaims(userID), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzAttacker, testKID, validClaims(userID), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzKey, "k2", validClaims(userID), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzKey, "", validClaims(userID), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzKey, testKID, with(func(c jwt.MapClaims) { delete(c, "exp") }), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzKey, testKID, with(func(c jwt.MapClaims) { c["iss"] = "other-issuer" }), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzKey, testKID, with(func(c jwt.MapClaims) { c["aud"] = []string{"other-api"} }), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzKey, testKID, validClaims("admin"), nil),
		sign(f, jwt.SigningMethodEdDSA, fuzzAttacker, testKID, validClaims(userID),
			map[string]any{"jku": "https://attacker.example/jwks.json", "x5u": "https://attacker.example/cert.pem"}),
		sign(f, jwt.SigningMethodEdDSA, fuzzAttacker, testKID, validClaims(userID), jwkHeader),
		issued.Reveal() + "=", "not.a.token", "a.b.c.d", "",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, token string) {
		got, err := v.Verify(token)
		if err != nil {
			if !errors.Is(err, ErrInvalidToken) || got != "" {
				t.Fatalf("Verify(%q) = (%q, %v), want an empty user id and ErrInvalidToken", token, got, err)
			}
		} else if !signedByFuzzKey(token) {
			t.Fatalf("Verify(%q) accepted a token not signed by the configured key: user id %q", token, got)
		}
		if token == issued.Reveal() && (err != nil || got != userID) {
			t.Fatalf("Verify(issued token) = (%q, %v), want %q", got, err, userID)
		}
	})
}
