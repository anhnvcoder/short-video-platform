package pagetoken

import (
	"errors"
	"strings"
	"testing"
	"time"
	"uuid"

	"google.golang.org/protobuf/encoding/protowire"
)

// The accepted time range written out again, apart from pagetoken.go.
var (
	fuzzFirst = time.Date(1, time.January, 1, 0, 0, 0, 0, time.UTC)
	fuzzLast  = time.Date(9999, time.December, 31, 23, 59, 59, 999999000, time.UTC)
)

func FuzzDecode(f *testing.F) {
	c := sample()
	both := appendVideoID(appendTime(nil, c.Time.UnixMicro()), c.VideoID[:])
	for _, s := range []string{
		Encode(c),
		Encode(Cursor{Time: fuzzFirst, VideoID: uuid.Max()}),
		Encode(Cursor{Time: fuzzLast, VideoID: uuid.Nil()}),
		encodeRaw(appendTime(appendVideoID(nil, c.VideoID[:]), c.Time.UnixMicro())), // fields in the other order
		encodeRaw(protowire.AppendVarint(protowire.AppendTag(both, 7, protowire.VarintType), 42)),
		encodeRaw(appendVideoID(appendTime(nil, 1<<63-1), c.VideoID[:])),
		encodeRaw(appendVideoID(appendTime(nil, -1<<63), c.VideoID[:])),
		encodeRaw(append(appendVideoID(nil, c.VideoID[:]), byte(fieldTime<<3), 0x80)),
		Encode(c) + "=", strings.Repeat("A", MaxLen+1), "%%%", "AAAAA", "",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, token string) {
		got, err := Decode(token)
		if err != nil {
			if !errors.Is(err, ErrInvalid) {
				t.Fatalf("Decode(%q) = %v, want ErrInvalid", token, err)
			}
			return
		}
		if len(token) > MaxLen {
			t.Fatalf("Decode accepted a token of %d characters, over %d", len(token), MaxLen)
		}
		if got.Time.Location() != time.UTC || got.Time.Before(fuzzFirst) || got.Time.After(fuzzLast) {
			t.Fatalf("Decode(%q) time = %v, want UTC within years 1 to 9999", token, got.Time)
		}
		// Decode skips unknown fields and takes the fields in any order, so only the cursor, not
		// the token, must come back.
		again := Encode(got)
		if len(again) > MaxLen {
			t.Fatalf("Encode(%v) = %d characters, over %d", got, len(again), MaxLen)
		}
		back, err := Decode(again)
		if err != nil || !back.Time.Equal(got.Time) || back.VideoID != got.VideoID {
			t.Fatalf("Decode(Encode(%v)) = (%v, %v)", got, back, err)
		}
	})
}

func FuzzRoundTrip(f *testing.F) {
	c := sample()
	f.Add(c.Time.UnixMicro(), c.VideoID[:])
	f.Add(fuzzFirst.UnixMicro(), []byte{})
	maxID := uuid.Max()
	f.Add(fuzzLast.UnixMicro(), maxID[:])
	f.Add(fuzzFirst.UnixMicro()-1, []byte{1, 2, 3})
	f.Add(fuzzLast.UnixMicro()+1, make([]byte, 20))
	f.Add(int64(-1<<63), []byte{0xff})
	f.Add(int64(1<<63-1), []byte{0xff})
	f.Fuzz(func(t *testing.T, micros int64, id []byte) {
		var in Cursor
		copy(in.VideoID[:], id)
		in.Time = time.UnixMicro(micros).UTC()
		token := Encode(in)
		if len(token) > MaxLen {
			t.Fatalf("Encode(%v) = %d characters, over %d", in, len(token), MaxLen)
		}
		got, err := Decode(token)
		if micros < fuzzFirst.UnixMicro() || micros > fuzzLast.UnixMicro() {
			if !errors.Is(err, ErrInvalid) {
				t.Fatalf("Decode(Encode(micros %d)) = (%v, %v), want ErrInvalid outside years 1 to 9999", micros, got, err)
			}
			return
		}
		if err != nil || !got.Time.Equal(in.Time) || got.VideoID != in.VideoID {
			t.Fatalf("Decode(Encode(%v)) = (%v, %v)", in, got, err)
		}
	})
}
