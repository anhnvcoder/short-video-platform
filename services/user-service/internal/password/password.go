// Package password hashes and verifies passwords with argon2id (docs/threat-model.md §4.1,
// JWT-5, JWT-7, JWT-9).
//
// Hashes are PHC strings, $argon2id$v=19$m=<KiB>,t=<passes>,p=<lanes>$<salt>$<hash> with
// unpadded standard base64, so the parameters travel with each hash and can be raised later:
// NeedsRehash tells the service to rehash at the next successful login.
package password

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"

	"github.com/anhnvcoder/svp-backend/internal/secret"
)

// Current parameters: the first argon2id configuration in the OWASP Password Storage Cheat
// Sheet (m=19 MiB, t=2, p=1).
const (
	memoryKiB = 19 * 1024
	passes    = 2
	lanes     = 1
	saltLen   = 16
	keyLen    = 32
)

// Upper bounds for parameters read back from a stored hash. A hash string from the database is
// input like any other: m=4194304 would make one Verify allocate 4 GiB. The bounds sit above
// every configuration OWASP lists (the largest is m=46 MiB) and leave room to raise the current
// one.
const (
	maxMemoryKiB = 64 * 1024
	maxPasses    = 10
	maxLanes     = 4
	minSaltLen   = 8
	maxSaltLen   = 64
	minKeyLen    = 16
	maxKeyLen    = 64
)

// MaxConcurrent caps the hashes running at once. The bound it gives is set by the largest
// parameters Verify accepts from a stored hash, not the current ones: up to maxMemoryKiB
// (64 MiB) and maxLanes (4 threads) each, so 4 in flight hold at most 256 MiB and 16 threads.
// That fits a user-service container in a few hundred MiB next to the Go runtime and connection
// pools; at the current parameters it is 76 MiB and 4 threads. A burst of logins then waits or
// fails with ErrBusy instead of growing memory without bound (JWT-9). Raising maxMemoryKiB or
// maxLanes raises this bound too.
const MaxConcurrent = 4

// acquireWait is how long Hash and Verify wait for a free slot before giving up with ErrBusy.
const acquireWait = 200 * time.Millisecond

// Password length bounds, in characters (runes).
const (
	MinLength = 8
	MaxLength = 128
)

var (
	// ErrBusy means every hashing slot stayed taken for the whole wait; the service answers
	// RESOURCE_EXHAUSTED.
	ErrBusy = errors.New("password: too many concurrent hashes")
	// ErrInvalidHash means a stored hash is malformed, not argon2id v19, or has parameters
	// outside the accepted bounds.
	ErrInvalidHash = errors.New("password: invalid hash")
	// ErrLength means a password is not valid UTF-8 or not MinLength to MaxLength characters.
	ErrLength = errors.New("password: must be 8 to 128 characters of valid UTF-8")
)

var b64 = base64.RawStdEncoding.Strict()

// CheckLength returns ErrLength unless pw is valid UTF-8 of MinLength to MaxLength runes. The
// service calls it before Hash.
func CheckLength(pw secret.String) error {
	s := pw.Reveal()
	if !utf8.ValidString(s) {
		return ErrLength
	}
	if n := utf8.RuneCountInString(s); n < MinLength || n > MaxLength {
		return ErrLength
	}
	return nil
}

// Hasher hashes and verifies passwords, running at most MaxConcurrent hashes at once. Create
// one per process with NewHasher.
type Hasher struct {
	slots chan struct{}
	wait  time.Duration
	dummy string
}

// NewHasher returns a Hasher.
func NewHasher() *Hasher {
	return &Hasher{
		slots: make(chan struct{}, MaxConcurrent),
		wait:  acquireWait,
		dummy: encode(params{memoryKiB, passes, lanes}, randomBytes(saltLen), randomBytes(keyLen)),
	}
}

// Hash returns the PHC string of pw with a new random salt and the current parameters.
func (h *Hasher) Hash(ctx context.Context, pw secret.String) (string, error) {
	if err := h.acquire(ctx); err != nil {
		return "", err
	}
	defer h.release()
	p := params{memoryKiB, passes, lanes}
	salt := randomBytes(saltLen)
	return encode(p, salt, p.key(pw, salt, keyLen)), nil
}

// Verify reports whether pw matches encoded. A mismatch is (false, nil); a malformed or
// out-of-bounds hash is ErrInvalidHash.
func (h *Hasher) Verify(ctx context.Context, pw secret.String, encoded string) (bool, error) {
	p, salt, want, err := decode(encoded)
	if err != nil {
		return false, err
	}
	if err := h.acquire(ctx); err != nil {
		return false, err
	}
	defer h.release()
	got := p.key(pw, salt, uint32(len(want))) //nolint:gosec // len(want) <= maxKeyLen, checked by decode
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// VerifyDummy runs the same work as Verify against a hash that matches no password. Login calls
// it when the email is unknown, so that branch takes as long as a wrong password and response
// time does not reveal which emails are registered (JWT-5). It returns only ErrBusy-type errors.
func (h *Hasher) VerifyDummy(ctx context.Context, pw secret.String) error {
	_, err := h.Verify(ctx, pw, h.dummy)
	return err
}

// NeedsRehash reports whether encoded was made with parameters other than the current ones
// (or cannot be read), so the service should store a fresh Hash after a successful login.
func NeedsRehash(encoded string) bool {
	p, salt, key, err := decode(encoded)
	if err != nil {
		return true
	}
	return p != (params{memoryKiB, passes, lanes}) || len(salt) != saltLen || len(key) != keyLen
}

func (h *Hasher) acquire(ctx context.Context) error {
	select {
	case h.slots <- struct{}{}:
		return nil
	default:
	}
	timer := time.NewTimer(h.wait)
	defer timer.Stop()
	select {
	case h.slots <- struct{}{}:
		return nil
	case <-timer.C:
		return ErrBusy
	case <-ctx.Done():
		return fmt.Errorf("%w: %w", ErrBusy, ctx.Err())
	}
}

func (h *Hasher) release() { <-h.slots }

type params struct {
	memoryKiB uint32
	passes    uint32
	lanes     uint8
}

func (p params) key(pw secret.String, salt []byte, n uint32) []byte {
	return argon2.IDKey([]byte(pw.Reveal()), salt, p.passes, p.memoryKiB, p.lanes, n)
}

func encode(p params, salt, key []byte) string {
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, p.memoryKiB, p.passes, p.lanes, b64.EncodeToString(salt), b64.EncodeToString(key))
}

func decode(encoded string) (params, []byte, []byte, error) {
	fields := strings.Split(encoded, "$")
	if len(fields) != 6 || fields[0] != "" || fields[1] != "argon2id" {
		return params{}, nil, nil, ErrInvalidHash
	}
	if fields[2] != fmt.Sprintf("v=%d", argon2.Version) {
		return params{}, nil, nil, ErrInvalidHash
	}
	var p params
	if n, err := fmt.Sscanf(fields[3], "m=%d,t=%d,p=%d", &p.memoryKiB, &p.passes, &p.lanes); err != nil || n != 3 ||
		fields[3] != fmt.Sprintf("m=%d,t=%d,p=%d", p.memoryKiB, p.passes, p.lanes) {
		return params{}, nil, nil, ErrInvalidHash
	}
	// argon2 needs at least 8 KiB of memory per lane.
	if p.passes < 1 || p.passes > maxPasses || p.lanes < 1 || p.lanes > maxLanes ||
		p.memoryKiB < 8*uint32(p.lanes) || p.memoryKiB > maxMemoryKiB {
		return params{}, nil, nil, ErrInvalidHash
	}
	salt, err := b64.DecodeString(fields[4])
	if err != nil || len(salt) < minSaltLen || len(salt) > maxSaltLen {
		return params{}, nil, nil, ErrInvalidHash
	}
	key, err := b64.DecodeString(fields[5])
	if err != nil || len(key) < minKeyLen || len(key) > maxKeyLen {
		return params{}, nil, nil, ErrInvalidHash
	}
	return p, salt, key, nil
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b) // crypto/rand.Read never returns an error (Go 1.24+); it aborts the process instead.
	return b
}
