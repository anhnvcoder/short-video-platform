// Package pagetoken encodes and decodes an opaque page_token: the keyset position (time,
// video_id) of the last item of a page, for lists ordered newest first by a timestamp and the
// video id. The time is the list's sort key: published_at for the feeds, created_at for the videos
// of an author (docs/architecture.md §8.3).
//
// The token is the unpadded base64url form of the protobuf bytes of a message with no .proto
// file, encoded by hand with protowire:
//
//	field 1  time          varint (int64)  microseconds since the Unix epoch
//	field 2  video_id      bytes           exactly 16 bytes
//
// It is not signed: which items a caller may see always comes from the request and the caller in
// x-user-id, never from the token, so an edited or borrowed token only moves where the caller
// reads in what it may see anyway (threat model PG-1).
package pagetoken

import (
	"encoding/base64"
	"errors"
	"time"
	"uuid"

	"google.golang.org/protobuf/encoding/protowire"
)

// MaxLen is the longest token Decode accepts, checked before decoding anything (threat model
// PG-2). A token Encode makes for a current date is 36 characters.
const MaxLen = 64

const (
	fieldTime    protowire.Number = 1
	fieldVideoID protowire.Number = 2
)

// The time range a token may carry: years 1 to 9999. Postgres stores more, but no listed row is
// outside it, and a value far outside would fail in the database instead of here.
var (
	minMicros = time.Date(1, time.January, 1, 0, 0, 0, 0, time.UTC).UnixMicro()
	maxMicros = time.Date(10000, time.January, 1, 0, 0, 0, 0, time.UTC).UnixMicro() - 1
)

// ErrInvalid means the token is too long or is not one Encode made.
var ErrInvalid = errors.New("pagetoken: invalid page token")

// Cursor is a keyset position: the next page holds the items strictly older than it in
// (Time DESC, VideoID DESC) order.
type Cursor struct {
	Time    time.Time
	VideoID uuid.UUID
}

// Encode returns the token of c. Time is kept to the microsecond, the precision of
// timestamptz.
func Encode(c Cursor) string {
	b := protowire.AppendTag(nil, fieldTime, protowire.VarintType)
	b = protowire.AppendVarint(b, uint64(c.Time.UnixMicro()))
	b = protowire.AppendTag(b, fieldVideoID, protowire.BytesType)
	b = protowire.AppendBytes(b, c.VideoID[:])
	return base64.RawURLEncoding.EncodeToString(b)
}

// Decode returns the cursor in token. It fails with ErrInvalid when the token is longer than
// MaxLen, is not unpadded base64url, is not valid protobuf, lacks a field, has a field of the
// wrong wire type, a video_id that is not 16 bytes or a time outside years 1 to 9999.
// Unknown fields are skipped, as protobuf does. The empty token is not a cursor: callers treat
// it as the first page before calling Decode.
func Decode(token string) (Cursor, error) {
	if len(token) > MaxLen {
		return Cursor{}, ErrInvalid
	}
	b, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return Cursor{}, ErrInvalid
	}
	var (
		c                   Cursor
		hasTime, hasVideoID bool
	)
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return Cursor{}, ErrInvalid
		}
		b = b[n:]
		switch {
		case num == fieldTime && typ == protowire.VarintType:
			v, n := protowire.ConsumeVarint(b)
			if n < 0 {
				return Cursor{}, ErrInvalid
			}
			b = b[n:]
			micros := int64(v) //nolint:gosec // protobuf int64 is the varint of its two's complement; range checked below
			if micros < minMicros || micros > maxMicros {
				return Cursor{}, ErrInvalid
			}
			c.Time = time.UnixMicro(micros).UTC()
			hasTime = true
		case num == fieldVideoID && typ == protowire.BytesType:
			v, n := protowire.ConsumeBytes(b)
			if n < 0 || len(v) != len(c.VideoID) {
				return Cursor{}, ErrInvalid
			}
			b = b[n:]
			c.VideoID = uuid.UUID(v)
			hasVideoID = true
		case num == fieldTime || num == fieldVideoID:
			// A known field with another wire type.
			return Cursor{}, ErrInvalid
		default:
			n := protowire.ConsumeFieldValue(num, typ, b)
			if n < 0 {
				return Cursor{}, ErrInvalid
			}
			b = b[n:]
		}
	}
	if !hasTime || !hasVideoID {
		return Cursor{}, ErrInvalid
	}
	return c, nil
}
