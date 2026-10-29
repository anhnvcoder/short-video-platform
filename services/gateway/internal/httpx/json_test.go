package httpx

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type body struct {
	Name string `json:"name"`
}

func decode(t *testing.T, payload string) (*httptest.ResponseRecorder, body, bool) {
	t.Helper()
	var dst body
	rec := httptest.NewRecorder()
	ok := DecodeJSON(rec, httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/", strings.NewReader(payload)), &dst)
	return rec, dst, ok
}

// objectOfSize returns {"name":"aaa…"} exactly n bytes long.
func objectOfSize(n int) string {
	const frame = `{"name":""}`
	return `{"name":"` + strings.Repeat("a", n-len(frame)) + `"}`
}

func TestDecodeJSONAccepts(t *testing.T) {
	for _, payload := range []string{`{"name":"x"}`, "{\"name\":\"x\"}\n", objectOfSize(maxBodyBytes)} {
		rec, dst, ok := decode(t, payload)
		if !ok || dst.Name == "" || rec.Body.Len() != 0 {
			t.Errorf("payload of %d bytes: ok = %v, name = %q, response %q; want decoded, nothing written", len(payload), ok, dst.Name, rec.Body)
		}
	}
}

func TestDecodeJSONRejects(t *testing.T) {
	tests := []struct {
		name    string
		payload string
		status  int
		code    string
	}{
		{"64 KiB + 1", objectOfSize(maxBodyBytes + 1), 413, "BODY_TOO_LARGE"},
		{"trailing data past the limit", `{"name":"x"}` + strings.Repeat(" ", maxBodyBytes), 413, "BODY_TOO_LARGE"},
		{"unknown field", `{"name":"x","admin":true}`, 400, "INVALID_JSON"},
		{"two objects", `{"name":"x"}{"name":"y"}`, 400, "INVALID_JSON"},
		{"trailing garbage", `{"name":"x"} x`, 400, "INVALID_JSON"},
		{"malformed", `{"name":`, 400, "INVALID_JSON"},
		{"wrong type", `{"name":1}`, 400, "INVALID_JSON"},
		{"empty", ``, 400, "INVALID_JSON"},
		// encoding/json leaves a field as it was on null, and decodes a null body into nothing:
		// both would reach the handler as an absent field or an empty object.
		{"null field", `{"name":null}`, 400, "INVALID_JSON"},
		{"null field with white space", "{\"name\" :\n null }", 400, "INVALID_JSON"},
		{"null body", `null`, 400, "INVALID_JSON"},
		{"array body", `[]`, 400, "INVALID_JSON"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec, _, ok := decode(t, tt.payload)
			if ok {
				t.Fatal("DecodeJSON() = true, want false")
			}
			p := decodeProblem(t, rec)
			if rec.Code != tt.status || p.Code != tt.code {
				t.Errorf("got %d %s, want %d %s", rec.Code, p.Code, tt.status, tt.code)
			}
		})
	}
}
