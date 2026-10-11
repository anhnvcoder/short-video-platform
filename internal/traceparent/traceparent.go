// Package traceparent creates and parses W3C Trace Context traceparent values
// (https://www.w3.org/TR/trace-context/#traceparent-header). Stage 1 only needs the trace-id
// for logs; OpenTelemetry takes over generation in stage 3 with the same metadata key.
package traceparent

import (
	"crypto/rand"
	"encoding/hex"
)

// MetadataKey is the gRPC metadata key (and HTTP header name) carrying the value.
const MetadataKey = "traceparent"

// version 00 layout: "00-" + 32 hex trace-id + "-" + 16 hex parent-id + "-" + 2 hex flags.
const v00Len = 55

// New returns a fresh value with version 00, a random trace-id and parent-id, and the sampled
// flag set.
func New() string {
	var b [24]byte
	// crypto/rand.Read never returns an error (Go 1.24+); it crashes the program instead.
	_, _ = rand.Read(b[:])
	return "00-" + hex.EncodeToString(b[:16]) + "-" + hex.EncodeToString(b[16:]) + "-01"
}

// TraceID returns the trace-id of v and true, or "" and false when v is not a valid
// traceparent: wrong layout, uppercase or non-hex digits, version ff, or an all-zero trace-id
// or parent-id. A version above 00 may carry extra fields after the flags, as the spec allows.
func TraceID(v string) (string, bool) {
	if len(v) < v00Len || v[2] != '-' || v[35] != '-' || v[52] != '-' {
		return "", false
	}
	version, traceID, parentID, flags := v[0:2], v[3:35], v[36:52], v[53:55]
	if !isLowerHex(version) || !isLowerHex(traceID) || !isLowerHex(parentID) || !isLowerHex(flags) {
		return "", false
	}
	if version == "ff" || isZero(traceID) || isZero(parentID) {
		return "", false
	}
	if len(v) > v00Len && (version == "00" || v[v00Len] != '-') {
		return "", false
	}
	return traceID, true
}

func isLowerHex(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func isZero(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != '0' {
			return false
		}
	}
	return true
}
