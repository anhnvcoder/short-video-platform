package ratelimit

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestClientIP(t *testing.T) {
	for _, tt := range []struct{ remote, want string }{
		{"192.0.2.1:5000", "192.0.2.1"},
		{"192.0.2.2:5000", "192.0.2.2"},
		{"[2001:db8::1]:5000", "2001:db8::/64"},
		{"[2001:db8::2]:6000", "2001:db8::/64"},
		{"[2001:db8:0:1::1]:5000", "2001:db8:0:1::/64"},
		{"[::ffff:192.0.2.1]:5000", "192.0.2.1"},
		{"[fe80::1%en0]:5000", "fe80::/64"},
	} {
		r := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/auth/login", nil)
		r.RemoteAddr = tt.remote
		if got := ClientIP(r); got != tt.want {
			t.Errorf("ClientIP(%s) = %q, want %q", tt.remote, got, tt.want)
		}
	}
}

func TestClientIPIgnoresHeaders(t *testing.T) {
	r := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/auth/login", nil)
	r.RemoteAddr = "192.0.2.1:5000"
	r.Header.Set("X-Forwarded-For", "203.0.113.7")
	r.Header.Set("X-Real-IP", "203.0.113.8")
	r.Header.Set("Forwarded", "for=203.0.113.9")
	if got := ClientIP(r); got != "192.0.2.1" {
		t.Errorf("ClientIP = %q, want the connection's 192.0.2.1", got)
	}
}

func TestLoginEmailID(t *testing.T) {
	id := LoginEmailID("192.0.2.1", "a@example.com")
	ip, hash, _ := strings.Cut(id, ":")
	if ip != "192.0.2.1" || len(hash) != 32 || strings.Contains(id, "example") {
		t.Errorf("LoginEmailID = %q, want the IP and 32 hex characters, no raw email", id)
	}
	if got := LoginEmailID("192.0.2.1", "  A@Example.COM "); got != id {
		t.Errorf("normalized email gives %q, want %q", got, id)
	}
	if LoginEmailID("192.0.2.1", "b@example.com") == id || LoginEmailID("192.0.2.2", "a@example.com") == id {
		t.Error("another email or IP shares the id")
	}
}
