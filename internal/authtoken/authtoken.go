// Package authtoken issues and verifies the platform's access tokens: JWTs signed with Ed25519
// (alg EdDSA), selected by kid (docs/threat-model.md §4.1, JWT-1, JWT-2, JWT-3, JWT-10).
//
// user-service holds the private key and issues tokens; the gateway holds only public keys and
// verifies them.
package authtoken

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/secret"
)

const (
	// IssuerName is the iss claim of every token.
	IssuerName = "svp-user"
	// Audience is the aud claim of every token.
	Audience = "svp-api"
	// TTL is how long a token stays valid after it is issued.
	TTL = time.Hour
	// Leeway is the clock skew allowed when checking exp, nbf and iat.
	Leeway = 30 * time.Second
)

// ErrInvalidToken wraps every error Verify returns. Callers answer every failure the same way;
// the wrapped detail is for logs only.
var ErrInvalidToken = errors.New("invalid token")

// Issuer signs tokens with one private key.
type Issuer struct {
	kid string
	key ed25519.PrivateKey
}

// NewIssuer returns an Issuer that signs with key and writes kid into the token header.
func NewIssuer(kid string, key ed25519.PrivateKey) *Issuer {
	return &Issuer{kid: kid, key: key}
}

// Issue returns a token for userID, which must be a canonical UUID, and its expiry time. The
// token carries iss, aud, sub, iat, exp and jti, and no personal data: a JWT is signed, not
// encrypted, so anyone holding it can read the payload.
func (i *Issuer) Issue(userID string) (secret.String, time.Time, error) {
	if _, err := ids.Parse(userID); err != nil {
		return secret.String{}, time.Time{}, fmt.Errorf("authtoken: user id: %w", err)
	}
	now := time.Now().Truncate(time.Second)
	exp := now.Add(TTL)
	claims := jwt.RegisteredClaims{
		Issuer:    IssuerName,
		Subject:   userID,
		Audience:  jwt.ClaimStrings{Audience},
		ExpiresAt: jwt.NewNumericDate(exp),
		IssuedAt:  jwt.NewNumericDate(now),
		ID:        ids.New(),
	}
	t := jwt.NewWithClaims(jwt.SigningMethodEdDSA, claims)
	t.Header["kid"] = i.kid
	signed, err := t.SignedString(i.key)
	if err != nil {
		return secret.String{}, time.Time{}, fmt.Errorf("authtoken: sign: %w", err)
	}
	return secret.New(signed), exp, nil
}

// Verifier checks tokens against a fixed set of public keys indexed by kid. Holding the old and
// the new key at once lets keys rotate without logging anyone out (threat model SEC-4).
type Verifier struct {
	keys   map[string]ed25519.PublicKey
	parser *jwt.Parser
}

// NewVerifier returns a Verifier for keys (kid → public key).
func NewVerifier(keys map[string]ed25519.PublicKey) *Verifier {
	return &Verifier{
		keys: keys,
		parser: jwt.NewParser(
			// The algorithm is fixed here and never taken from the token: alg none and
			// HS256-keyed-with-the-public-key tokens fail before any key is looked up (JWT-1).
			jwt.WithValidMethods([]string{jwt.SigningMethodEdDSA.Alg()}),
			jwt.WithIssuer(IssuerName),
			jwt.WithAudience(Audience),
			jwt.WithExpirationRequired(),
			jwt.WithIssuedAt(),
			jwt.WithLeeway(Leeway),
		),
	}
}

// Verify returns the user id in token. Every failure wraps ErrInvalidToken. Header fields that
// point to other keys (jku, x5u, jwk) are never read: the key comes only from the configured set.
func (v *Verifier) Verify(token string) (string, error) {
	var claims jwt.RegisteredClaims
	if _, err := v.parser.ParseWithClaims(token, &claims, v.keyFor); err != nil {
		return "", fmt.Errorf("%w: %w", ErrInvalidToken, err)
	}
	if _, err := ids.Parse(claims.Subject); err != nil {
		return "", fmt.Errorf("%w: sub: %w", ErrInvalidToken, err)
	}
	return claims.Subject, nil
}

func (v *Verifier) keyFor(t *jwt.Token) (any, error) {
	kid, _ := t.Header["kid"].(string)
	if kid == "" {
		return nil, errors.New("missing kid")
	}
	key, ok := v.keys[kid]
	if !ok {
		return nil, fmt.Errorf("unknown kid %q", kid)
	}
	return key, nil
}

// GenerateKey returns a new Ed25519 private key.
func GenerateKey() (ed25519.PrivateKey, error) {
	_, key, err := ed25519.GenerateKey(nil)
	if err != nil {
		return nil, fmt.Errorf("authtoken: generate key: %w", err)
	}
	return key, nil
}

// ParseSigningKey checks kid and decodes base64Seed (standard base64 of a 32-byte Ed25519 seed,
// the JWT_SIGNING_KEY format) into a private key.
func ParseSigningKey(kid, base64Seed string) (ed25519.PrivateKey, error) {
	if err := checkKID(kid); err != nil {
		return nil, err
	}
	seed, err := decodeKey(base64Seed, ed25519.SeedSize)
	if err != nil {
		return nil, fmt.Errorf("authtoken: signing key: %w", err)
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// ParseVerifyKeys decodes the JWT_VERIFY_KEYS format: comma-separated "kid:base64" entries,
// each the standard base64 of a 32-byte Ed25519 public key. Empty input, an empty entry and a
// repeated kid are errors.
func ParseVerifyKeys(s string) (map[string]ed25519.PublicKey, error) {
	if strings.TrimSpace(s) == "" {
		return nil, errors.New("authtoken: verify keys: empty")
	}
	keys := make(map[string]ed25519.PublicKey)
	for entry := range strings.SplitSeq(s, ",") {
		kid, encoded, ok := strings.Cut(strings.TrimSpace(entry), ":")
		if !ok {
			return nil, fmt.Errorf("authtoken: verify keys: entry %q is not kid:base64", entry)
		}
		if err := checkKID(kid); err != nil {
			return nil, err
		}
		if _, dup := keys[kid]; dup {
			return nil, fmt.Errorf("authtoken: verify keys: duplicate kid %q", kid)
		}
		raw, err := decodeKey(encoded, ed25519.PublicKeySize)
		if err != nil {
			return nil, fmt.Errorf("authtoken: verify key %q: %w", kid, err)
		}
		keys[kid] = ed25519.PublicKey(raw)
	}
	return keys, nil
}

func decodeKey(s string, size int) ([]byte, error) {
	raw, err := base64.StdEncoding.Strict().DecodeString(s)
	if err != nil {
		return nil, errors.New("not standard base64")
	}
	if len(raw) != size {
		return nil, fmt.Errorf("got %d bytes, want %d", len(raw), size)
	}
	return raw, nil
}

const kidChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"

// checkKID accepts 1 to 64 characters from [A-Za-z0-9._-], so a kid never contains the ':' and
// ',' separators of JWT_VERIFY_KEYS.
func checkKID(kid string) error {
	if kid == "" || len(kid) > 64 {
		return fmt.Errorf("authtoken: kid must be 1 to 64 characters, got %d", len(kid))
	}
	if strings.IndexFunc(kid, func(r rune) bool { return !strings.ContainsRune(kidChars, r) }) >= 0 {
		return fmt.Errorf("authtoken: kid %q has a character outside [A-Za-z0-9._-]", kid)
	}
	return nil
}
