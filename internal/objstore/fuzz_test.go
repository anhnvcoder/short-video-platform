package objstore

import (
	"path"
	"regexp"
	"strings"
	"testing"
	"uuid"
)

// fuzzSegments is the part of a media key after "media/<videoID>/", written out again apart from
// IsMediaKey: one or more "/"-separated segments of letters, digits, ".", "_" and "-".
var fuzzSegments = regexp.MustCompile(`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`)

// FuzzIsMediaKey takes the video id from the first 16 bytes of id (padded with zeros), in the
// canonical form every caller passes (uuid.UUID.String).
func FuzzIsMediaKey(f *testing.F) {
	const id = "0190a6e4-7b2c-7d3e-9f40-123456789abc"
	idBytes := uuid.MustParse(id)
	prefix := MediaPrefix + id + "/"
	for _, key := range []string{
		prefix + "master.m3u8", prefix + "720p/seg_000.ts", prefix + "thumbnail.jpg", prefix + "...",
		prefix + "../x", prefix + "..", prefix + "./master.m3u8", prefix + "%2e%2e/x", prefix + ".%2E/x",
		prefix + `a\b`, prefix + "/x", prefix + "720p//x", prefix + "720p/", prefix, "media/" + id,
		"media/0190a6e4-7b2c-7d3e-9f40-123456789abd/master.m3u8", "x" + prefix + "master.m3u8",
		prefix + "master.m3u8?x=1", prefix + "m\u00e4ster.m3u8", "",
	} {
		f.Add(key, idBytes[:])
	}
	f.Add(MediaPrefix+uuid.Nil().String()+"/master.m3u8", []byte{})
	f.Fuzz(func(t *testing.T, key string, id []byte) {
		var u uuid.UUID
		copy(u[:], id)
		videoID := u.String()

		rest, hasPrefix := strings.CutPrefix(key, MediaPrefix+videoID+"/")
		want := hasPrefix && fuzzSegments.MatchString(rest)
		for seg := range strings.SplitSeq(rest, "/") {
			if seg == "." || seg == ".." {
				want = false
			}
		}
		got := IsMediaKey(key, videoID)
		if got != want {
			t.Fatalf("IsMediaKey(%q, %q) = %v, want %v", key, videoID, got, want)
		}
		if got && path.Clean(key) != key {
			t.Fatalf("IsMediaKey(%q, %q) accepted a key path.Clean changes to %q", key, videoID, path.Clean(key))
		}
	})
}
