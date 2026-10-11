package traceparent

import (
	"regexp"
	"testing"
)

var newFormat = regexp.MustCompile(`^00-[0-9a-f]{32}-[0-9a-f]{16}-01$`)

func TestNew(t *testing.T) {
	seen := make(map[string]bool)
	for range 100 {
		v := New()
		if !newFormat.MatchString(v) {
			t.Fatalf("New() = %q, does not match %s", v, newFormat)
		}
		id, ok := TraceID(v)
		if !ok {
			t.Fatalf("TraceID(New()) rejected %q", v)
		}
		if seen[id] {
			t.Fatalf("New() repeated trace-id %s", id)
		}
		seen[id] = true
	}
}

func TestTraceID(t *testing.T) {
	const valid = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	tests := []struct {
		name   string
		value  string
		wantID string
		wantOK bool
	}{
		{name: "valid", value: valid, wantID: "4bf92f3577b34da6a3ce929d0e0e4736", wantOK: true},
		{name: "unsampled flags", value: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00", wantID: "4bf92f3577b34da6a3ce929d0e0e4736", wantOK: true},
		{name: "future version with extra field", value: "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra", wantID: "4bf92f3577b34da6a3ce929d0e0e4736", wantOK: true},
		{name: "empty", value: ""},
		{name: "garbage", value: "not-a-traceparent"},
		{name: "version ff", value: "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"},
		{name: "zero trace-id", value: "00-00000000000000000000000000000000-00f067aa0ba902b7-01"},
		{name: "zero parent-id", value: "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"},
		{name: "uppercase hex", value: "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01"},
		{name: "non-hex", value: "00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01"},
		{name: "short trace-id", value: "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01"},
		{name: "wrong separator", value: "00_4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"},
		{name: "version 00 with trailing data", value: valid + "-extra"},
		{name: "future version without dash before extra", value: "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			id, ok := TraceID(tt.value)
			if ok != tt.wantOK || id != tt.wantID {
				t.Errorf("TraceID(%q) = (%q, %v), want (%q, %v)", tt.value, id, ok, tt.wantID, tt.wantOK)
			}
		})
	}
}

func TestContext(t *testing.T) {
	if v, ok := FromContext(t.Context()); ok || v != "" {
		t.Errorf("FromContext(empty) = (%q, %v), want (\"\", false)", v, ok)
	}
	const tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	if v, ok := FromContext(NewContext(t.Context(), tp)); !ok || v != tp {
		t.Errorf("FromContext(NewContext(v)) = (%q, %v), want (%q, true)", v, ok, tp)
	}
}
