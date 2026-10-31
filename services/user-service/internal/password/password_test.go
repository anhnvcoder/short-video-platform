package password

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/anhnvcoder/svp-backend/internal/secret"
)

func TestHashThenVerify(t *testing.T) {
	h := NewHasher()
	ctx := context.Background()
	pw := secret.New("correct horse battery staple")

	encoded, err := h.Hash(ctx, pw)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(encoded, "$argon2id$v=19$m=19456,t=2,p=1$") {
		t.Errorf("hash = %q, want argon2id v19 with m=19456,t=2,p=1", encoded)
	}
	if strings.Contains(encoded, "=$") || strings.HasSuffix(encoded, "=") {
		t.Errorf("hash %q has base64 padding", encoded)
	}

	if ok, err := h.Verify(ctx, pw, encoded); err != nil || !ok {
		t.Errorf("Verify(right password) = (%v, %v), want (true, nil)", ok, err)
	}
	if ok, err := h.Verify(ctx, secret.New("correct horse battery stapl"), encoded); err != nil || ok {
		t.Errorf("Verify(wrong password) = (%v, %v), want (false, nil)", ok, err)
	}
	if NeedsRehash(encoded) {
		t.Error("NeedsRehash(fresh hash) = true")
	}
}

func TestHashUsesRandomSalt(t *testing.T) {
	h := NewHasher()
	pw := secret.New("same password")
	a, err := h.Hash(context.Background(), pw)
	if err != nil {
		t.Fatal(err)
	}
	b, err := h.Hash(context.Background(), pw)
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Error("two hashes of the same password are equal")
	}
	_, salt, _, err := decode(a)
	if err != nil || len(salt) != 16 {
		t.Errorf("salt length = %d (err %v), want 16", len(salt), err)
	}
}

func TestVerifyAcceptsOtherValidParameters(t *testing.T) {
	// A hash made with another OWASP configuration still verifies, and asks for a rehash.
	salt := []byte("0123456789abcdef")
	p := params{memoryKiB: 12 * 1024, passes: 3, lanes: 1}
	pw := secret.New("old parameters")
	encoded := encode(p, salt, p.key(pw, salt, keyLen))

	ok, err := NewHasher().Verify(context.Background(), pw, encoded)
	if err != nil || !ok {
		t.Fatalf("Verify() = (%v, %v), want (true, nil)", ok, err)
	}
	if !NeedsRehash(encoded) {
		t.Error("NeedsRehash(hash with old parameters) = false")
	}
}

func TestVerifyRejectsInvalidHashes(t *testing.T) {
	h := NewHasher()
	valid, err := h.Hash(context.Background(), secret.New("password1"))
	if err != nil {
		t.Fatal(err)
	}
	f := strings.Split(valid, "$")
	salt, key := f[4], f[5]
	with := func(alg, version, ps, s, k string) string {
		return strings.Join([]string{"", alg, version, ps, s, k}, "$")
	}
	tests := map[string]string{
		"empty":               "",
		"garbage":             "not a hash",
		"bcrypt":              "$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy",
		"argon2i":             with("argon2i", "v=19", "m=19456,t=2,p=1", salt, key),
		"argon2d":             with("argon2d", "v=19", "m=19456,t=2,p=1", salt, key),
		"old version":         with("argon2id", "v=16", "m=19456,t=2,p=1", salt, key),
		"version with junk":   with("argon2id", "v=19x", "m=19456,t=2,p=1", salt, key),
		"missing field":       strings.Join(f[:5], "$"),
		"extra field":         valid + "$x",
		"params out of order": with("argon2id", "v=19", "t=2,m=19456,p=1", salt, key),
		"params with junk":    with("argon2id", "v=19", "m=19456,t=2,p=1,x=1", salt, key),
		"negative memory":     with("argon2id", "v=19", "m=-1,t=2,p=1", salt, key),
		"huge memory":         with("argon2id", "v=19", "m=4194304,t=2,p=1", salt, key),
		"memory overflow":     with("argon2id", "v=19", "m=99999999999,t=2,p=1", salt, key),
		"memory below lanes":  with("argon2id", "v=19", "m=8,t=2,p=4", salt, key),
		"zero passes":         with("argon2id", "v=19", "m=19456,t=0,p=1", salt, key),
		"huge passes":         with("argon2id", "v=19", "m=19456,t=1000,p=1", salt, key),
		"zero lanes":          with("argon2id", "v=19", "m=19456,t=2,p=0", salt, key),
		"huge lanes":          with("argon2id", "v=19", "m=19456,t=2,p=255", salt, key),
		"lanes overflow":      with("argon2id", "v=19", "m=19456,t=2,p=256", salt, key),
		"padded salt":         with("argon2id", "v=19", "m=19456,t=2,p=1", salt+"==", key),
		"bad salt":            with("argon2id", "v=19", "m=19456,t=2,p=1", "!!!", key),
		"short salt":          with("argon2id", "v=19", "m=19456,t=2,p=1", "YWJj", key),
		"bad key":             with("argon2id", "v=19", "m=19456,t=2,p=1", salt, "!!!"),
		"short key":           with("argon2id", "v=19", "m=19456,t=2,p=1", salt, "YWJj"),
		"huge key":            with("argon2id", "v=19", "m=19456,t=2,p=1", salt, strings.Repeat("A", 1000)),
	}
	for name, encoded := range tests {
		t.Run(name, func(t *testing.T) {
			ok, err := h.Verify(context.Background(), secret.New("password1"), encoded)
			if ok || !errors.Is(err, ErrInvalidHash) {
				t.Errorf("Verify(%q) = (%v, %v), want (false, ErrInvalidHash)", encoded, ok, err)
			}
			if !NeedsRehash(encoded) {
				t.Errorf("NeedsRehash(%q) = false, want true", encoded)
			}
		})
	}
}

func TestVerifyDummy(t *testing.T) {
	h := NewHasher()
	if NeedsRehash(h.dummy) {
		t.Errorf("dummy hash %q does not use the current parameters, so it would not cost the same as a real one", h.dummy)
	}
	if err := h.VerifyDummy(context.Background(), secret.New("any password")); err != nil {
		t.Errorf("VerifyDummy() = %v", err)
	}
	if ok, err := h.Verify(context.Background(), secret.New(""), h.dummy); err != nil || ok {
		t.Errorf("Verify(empty, dummy) = (%v, %v), want (false, nil)", ok, err)
	}
}

// fill takes every slot of h and returns a function that frees them.
func fill(h *Hasher) func() {
	for range MaxConcurrent {
		h.slots <- struct{}{}
	}
	return func() {
		for range MaxConcurrent {
			<-h.slots
		}
	}
}

func TestBusyWhenAllSlotsStayTaken(t *testing.T) {
	h := NewHasher()
	h.wait = 20 * time.Millisecond
	defer fill(h)()
	pw := secret.New("password1")

	if _, err := h.Hash(context.Background(), pw); !errors.Is(err, ErrBusy) {
		t.Errorf("Hash() = %v, want ErrBusy", err)
	}
	if _, err := h.Verify(context.Background(), pw, h.dummy); !errors.Is(err, ErrBusy) {
		t.Errorf("Verify() = %v, want ErrBusy", err)
	}
	if err := h.VerifyDummy(context.Background(), pw); !errors.Is(err, ErrBusy) {
		t.Errorf("VerifyDummy() = %v, want ErrBusy", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	h.wait = time.Hour
	if _, err := h.Hash(ctx, pw); !errors.Is(err, ErrBusy) || !errors.Is(err, context.Canceled) {
		t.Errorf("Hash(canceled ctx) = %v, want ErrBusy wrapping context.Canceled", err)
	}
}

// The MaxConcurrent comment states the worst case over every hash Verify accepts.
func TestWorstCaseBoundMatchesComment(t *testing.T) {
	if mib := MaxConcurrent * maxMemoryKiB / 1024; mib > 256 {
		t.Errorf("MaxConcurrent hashes at maxMemoryKiB hold %d MiB, the comment says at most 256", mib)
	}
	if threads := MaxConcurrent * maxLanes; threads > 16 {
		t.Errorf("MaxConcurrent hashes at maxLanes run %d threads, the comment says at most 16", threads)
	}
}

func TestDefaultWaitIsAbout200ms(t *testing.T) {
	h := NewHasher()
	defer fill(h)()
	start := time.Now()
	_, err := h.Hash(context.Background(), secret.New("password1"))
	if elapsed := time.Since(start); !errors.Is(err, ErrBusy) || elapsed < 200*time.Millisecond || elapsed > 2*time.Second {
		t.Errorf("Hash() = %v after %v, want ErrBusy after about 200ms", err, elapsed)
	}
}

func TestWaitsForAFreeSlot(t *testing.T) {
	h := NewHasher()
	free := fill(h)
	go func() {
		time.Sleep(20 * time.Millisecond)
		free()
	}()
	if _, err := h.Hash(context.Background(), secret.New("password1")); err != nil {
		t.Errorf("Hash() = %v, want success once a slot frees up", err)
	}
}

func TestConcurrentHashesQueueForSlots(t *testing.T) {
	h := NewHasher()
	h.wait = time.Minute
	errs := make(chan error, 3*MaxConcurrent)
	for i := range 3 * MaxConcurrent {
		go func() {
			_, err := h.Hash(context.Background(), secret.New(fmt.Sprintf("password-%d", i)))
			errs <- err
		}()
	}
	for range 3 * MaxConcurrent {
		if err := <-errs; err != nil {
			t.Errorf("Hash() = %v", err)
		}
	}
}

func TestCheckLength(t *testing.T) {
	tests := []struct {
		name string
		pw   string
		ok   bool
	}{
		{"empty", "", false},
		{"7 characters", "1234567", false},
		{"8 characters", "12345678", true},
		{"128 characters", strings.Repeat("a", 128), true},
		{"129 characters", strings.Repeat("a", 129), false},
		{"8 multi-byte characters", "mậtkhẩuu", true},
		{"128 multi-byte characters over 128 bytes", strings.Repeat("ế", 128), true},
		{"129 multi-byte characters", strings.Repeat("ế", 129), false},
		{"invalid UTF-8", "abcdefg\xff", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := CheckLength(secret.New(tt.pw))
			if tt.ok && err != nil {
				t.Errorf("CheckLength() = %v, want nil", err)
			}
			if !tt.ok && !errors.Is(err, ErrLength) {
				t.Errorf("CheckLength() = %v, want ErrLength", err)
			}
		})
	}
}

func BenchmarkHash(b *testing.B) {
	h := NewHasher()
	pw := secret.New("correct horse battery staple")
	for b.Loop() {
		if _, err := h.Hash(context.Background(), pw); err != nil {
			b.Fatal(err)
		}
	}
}
