package pagetoken

import (
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
	"uuid"

	"google.golang.org/protobuf/encoding/protowire"
)

func sample() Cursor {
	return Cursor{
		Time:    time.Date(2026, time.October, 11, 8, 30, 15, 123456000, time.UTC),
		VideoID: uuid.MustParse("01928c6e-7b3a-7cde-8f01-23456789abcd"),
	}
}

func encodeRaw(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func appendTime(b []byte, micros int64) []byte {
	b = protowire.AppendTag(b, fieldTime, protowire.VarintType)
	return protowire.AppendVarint(b, uint64(micros)) //nolint:gosec // protobuf int64 is the varint of its two's complement
}

func appendVideoID(b, id []byte) []byte {
	b = protowire.AppendTag(b, fieldVideoID, protowire.BytesType)
	return protowire.AppendBytes(b, id)
}

func TestRoundTrip(t *testing.T) {
	for _, c := range []Cursor{
		sample(),
		{Time: time.Unix(0, 0).UTC(), VideoID: uuid.Max()},
		{Time: time.Date(1969, time.July, 20, 20, 17, 0, 0, time.UTC), VideoID: uuid.Nil()},
	} {
		token := Encode(c)
		if len(token) > MaxLen || strings.ContainsAny(token, "+/=") {
			t.Errorf("Encode(%v) = %q, want unpadded base64url within %d characters", c, token, MaxLen)
		}
		got, err := Decode(token)
		if err != nil {
			t.Fatalf("Decode(%q) = %v", token, err)
		}
		if !got.Time.Equal(c.Time) || got.VideoID != c.VideoID {
			t.Errorf("Decode(Encode(%v)) = %v", c, got)
		}
	}
}

// The token keeps microseconds, the precision of timestamptz.
func TestEncodeTruncatesToMicroseconds(t *testing.T) {
	c := sample()
	c.Time = c.Time.Add(789 * time.Nanosecond)
	got, err := Decode(Encode(c))
	if err != nil {
		t.Fatal(err)
	}
	if want := c.Time.Truncate(time.Microsecond); !got.Time.Equal(want) {
		t.Errorf("Time = %v, want %v", got.Time, want)
	}
}

// Fields an older or newer version does not know are skipped, as protobuf does.
func TestUnknownFieldsAreSkipped(t *testing.T) {
	c := sample()
	b := protowire.AppendTag(nil, 9, protowire.BytesType)
	b = protowire.AppendBytes(b, []byte("future"))
	b = appendVideoID(b, c.VideoID[:])
	b = protowire.AppendTag(b, 7, protowire.VarintType)
	b = protowire.AppendVarint(b, 42)
	b = appendTime(b, c.Time.UnixMicro())
	got, err := Decode(encodeRaw(b))
	if err != nil {
		t.Fatal(err)
	}
	if !got.Time.Equal(c.Time) || got.VideoID != c.VideoID {
		t.Errorf("Decode() = %v, want %v", got, c)
	}
}

func TestInvalidTokens(t *testing.T) {
	c := sample()
	micros := c.Time.UnixMicro()
	valid := Encode(c)
	both := appendVideoID(appendTime(nil, micros), c.VideoID[:])
	for _, tc := range []struct{ name, token string }{
		{"65 characters", valid + strings.Repeat("A", MaxLen+1-len(valid))},
		{"very long", strings.Repeat("A", 10_000)},
		{"standard base64 alphabet", base64.RawStdEncoding.EncodeToString(append(both, 0xfb, 0xff))},
		// A valid message of 29 bytes (an unknown field added), which padding would end with "=".
		{"padded", base64.URLEncoding.EncodeToString(protowire.AppendVarint(protowire.AppendTag(both, 7, protowire.VarintType), 0))},
		{"not base64", "%%%"},
		{"impossible length", "AAAAA"},
		{"truncated protobuf", encodeRaw(both[:len(both)-3])},
		{"truncated varint", encodeRaw(append(appendVideoID(nil, c.VideoID[:]), byte(fieldTime<<3), 0x80))},
		{"bad tag", encodeRaw([]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})},
		{"no time", encodeRaw(appendVideoID(nil, c.VideoID[:]))},
		{"no video_id", encodeRaw(appendTime(nil, micros))},
		{"empty", ""},
		{"zero tag", encodeRaw([]byte{0})},
		{"video_id of 15 bytes", encodeRaw(appendVideoID(appendTime(nil, micros), c.VideoID[:15]))},
		{"video_id of 17 bytes", encodeRaw(appendVideoID(appendTime(nil, micros), append(c.VideoID[:], 0)))},
		{"time as bytes", encodeRaw(appendVideoID(protowire.AppendBytes(
			protowire.AppendTag(nil, fieldTime, protowire.BytesType), []byte{1}), c.VideoID[:]))},
		{"video_id as varint", encodeRaw(protowire.AppendVarint(
			protowire.AppendTag(appendTime(nil, micros), fieldVideoID, protowire.VarintType), 1))},
		{"time after year 9999", encodeRaw(appendVideoID(appendTime(nil, maxMicros+1), c.VideoID[:]))},
		{"time before year 1", encodeRaw(appendVideoID(appendTime(nil, minMicros-1), c.VideoID[:]))},
		{"time of max int64", encodeRaw(appendVideoID(appendTime(nil, 1<<63-1), c.VideoID[:]))},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := Decode(tc.token); !errors.Is(err, ErrInvalid) {
				t.Errorf("Decode(%q) = %v, want ErrInvalid", tc.token, err)
			}
		})
	}
}

// The edges of the accepted time range decode.
func TestTimeRangeEdges(t *testing.T) {
	id := uuid.Max()
	for _, micros := range []int64{minMicros, maxMicros} {
		got, err := Decode(encodeRaw(appendVideoID(appendTime(nil, micros), id[:])))
		if err != nil {
			t.Fatalf("micros %d: %v", micros, err)
		}
		if got.Time.UnixMicro() != micros {
			t.Errorf("micros %d decoded as %v", micros, got.Time)
		}
	}
}
