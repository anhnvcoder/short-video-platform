package httpx

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/wrapperspb"

	"github.com/anhnvcoder/svp-backend/internal/authtoken"
)

// FuzzClientAddr reads hops as two numbers: hops%3 is the proxies trusted, (hops/3)%3 the number
// of X-Forwarded-For headers, taken from xff1 and xff2 in that order.
func FuzzClientAddr(f *testing.F) {
	for _, s := range []struct {
		remote, xff1, xff2 string
		hops               uint8
	}{
		{"192.0.2.1:5000", "203.0.113.7", "", 1 + 3},
		{"10.42.0.7:5000", "203.0.113.7, 198.51.100.9", "", 1 + 3},
		{"10.42.0.7:5000", "203.0.113.7, 203.0.113.8", "198.51.100.9", 1 + 6},
		{"10.42.0.7:5000", "198.51.100.9", "10.0.0.5", 2 + 6},
		{"10.42.0.7:5000", "::ffff:198.51.100.9", "", 1 + 3},
		{"[::ffff:10.42.0.7]:5000", "fe80::1%eth0", "", 1 + 3},
		{"10.42.0.7:5000", "198.51.100.9:443", "", 1 + 3},
		{"10.42.0.7:5000", "198.51.100.9,", "", 1 + 3},
		{"10.42.0.7:5000", "a@example.com, 198.51.100.9", "", 1 + 3},
		{"10.42.0.7:5000", "", "", 1},
		{"10.43.0.7:5000", "198.51.100.9", "", 1 + 3},
		{"10.42.0.7", "198.51.100.9", "", 1 + 3},
		{"pipe", "198.51.100.9", "", 1 + 3},
	} {
		f.Add(s.remote, s.xff1, s.xff2, s.hops)
	}
	trusted := netip.MustParsePrefix("10.42.0.0/16")
	f.Fuzz(func(t *testing.T, remoteAddr, xff1, xff2 string, hops uint8) {
		c := NewClientAddr(int(hops%3), []netip.Prefix{trusted})
		headers := []string{xff1, xff2}[:hops/3%3]
		request := func(values ...string) *http.Request {
			r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil)
			r.RemoteAddr = remoteAddr
			for _, v := range values {
				r.Header.Add("X-Forwarded-For", v)
			}
			return r
		}
		got := c.Of(request(headers...))

		host, _, err := net.SplitHostPort(remoteAddr)
		if err != nil {
			host = remoteAddr
		}
		conn, err := netip.ParseAddr(host)
		fromProxy := err == nil && trusted.Contains(conn.Unmap())
		if (hops%3 == 0 || !fromProxy) && got != host {
			t.Fatalf("Of = %q, want the connection's host %q (hops %d, trusted connection %v)", got, host, hops%3, fromProxy)
		}
		if got != host {
			a, err := netip.ParseAddr(got)
			if err != nil || a.String() != got || a.Is4In6() {
				t.Fatalf("Of = %q, not an IP address in canonical form: %v", got, err)
			}
		}
		// RL-1: what a client writes arrives before every element a trusted proxy appends, so a
		// header put in front of the list never changes the answer once the list is long enough.
		if fromProxy && hops%3 > 0 && len(headers) > 0 &&
			len(strings.Split(strings.Join(headers, ","), ",")) >= int(hops%3) {
			forged := xff2 + "," + xff1
			if again := c.Of(request(append([]string{forged}, headers...)...)); again != got {
				t.Fatalf("Of = %q, and %q with X-Forwarded-For %q in front", got, again, forged)
			}
		}
	})
}

// The key of FuzzRequireAuth comes from a fixed seed, so every worker process verifies with the
// same key. It signs nothing outside this test.
var fuzzKey = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{7}, ed25519.SeedSize))

// signedByFuzzKey reports whether token is three segments whose header names alg EdDSA and kid
// testKID and whose signature over the first two segments verifies with fuzzKey, checked without
// the jwt library (the signature segment decoded as the library does).
func signedByFuzzKey(token string) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	var header map[string]any
	if json.Unmarshal(raw, &header) != nil || header["alg"] != "EdDSA" || header["kid"] != testKID {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	return ed25519.Verify(fuzzKey.Public().(ed25519.PublicKey), []byte(parts[0]+"."+parts[1]), sig)
}

// FuzzRequireAuth sends n%3 Authorization headers, taken from auth1 and auth2 in that order.
func FuzzRequireAuth(f *testing.F) {
	verifier := authtoken.NewVerifier(map[string]ed25519.PublicKey{testKID: fuzzKey.Public().(ed25519.PublicKey)})
	tok, _, err := authtoken.NewIssuer(testKID, fuzzKey).Issue(userID)
	if err != nil {
		f.Fatal(err)
	}
	valid := tok.Reveal()
	pubKey := []byte(fuzzKey.Public().(ed25519.PublicKey))
	for _, s := range []struct {
		auth1, auth2 string
		n            uint8
	}{
		{"Bearer " + valid, "", 1},
		{"bearer " + valid, "", 1},
		{"BEARER " + valid, "", 1},
		{"Bearer " + valid, "Bearer " + valid, 2},
		{"Bearer  " + valid, "", 1},
		{"Bearer\t" + valid, "", 1},
		{valid, "", 1},
		{"Basic dXNlcjpwYXNz", "", 1},
		{"Bearer", "", 1},
		{"Bearer ", "", 1},
		{"", "", 0},
		{"Bearer " + sign(f, jwt.SigningMethodNone, jwt.UnsafeAllowNoneSignatureType, testKID, claims(userID)), "", 1},
		{"Bearer " + sign(f, jwt.SigningMethodHS256, pubKey, testKID, claims(userID)), "", 1},
		{"Bearer " + sign(f, jwt.SigningMethodEdDSA, fuzzKey, "k2", claims(userID)), "", 1},
		{"Bearer not.a.jwt", "", 1},
	} {
		f.Add(s.auth1, s.auth2, s.n)
	}
	f.Fuzz(func(t *testing.T, auth1, auth2 string, n uint8) {
		captureLog(t)
		values := []string{auth1, auth2}[:n%3]
		ran := false
		h := RequireAuth(verifier)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { ran = true }))
		r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/private/1", nil)
		for _, v := range values {
			r.Header.Add("Authorization", v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)

		if ran {
			if len(values) != 1 {
				t.Fatalf("handler ran with %d Authorization headers, want exactly one", len(values))
			}
			scheme, token, _ := strings.Cut(values[0], " ")
			if !strings.EqualFold(scheme, "Bearer") || !signedByFuzzKey(token) {
				t.Fatalf("handler ran with Authorization %q: not Bearer and a token signed by the configured key", values[0])
			}
			return
		}
		if len(values) == 1 && values[0] == "Bearer "+valid {
			t.Fatal("handler blocked with the issued token")
		}
		p := decodeProblem(t, rec)
		if rec.Code != http.StatusUnauthorized || p.Code != "INVALID_TOKEN" || p.Detail != invalidTokenDetail {
			t.Fatalf("got %d %q %q, want 401 INVALID_TOKEN %q", rec.Code, p.Code, p.Detail, invalidTokenDetail)
		}
		if got := rec.Header().Get("WWW-Authenticate"); got != "Bearer" {
			t.Fatalf("WWW-Authenticate = %q, want Bearer", got)
		}
	})
}

// marshals reports whether s goes into a proto3 string field, which refuses invalid UTF-8: the
// failure ValidUTF8 answers with a 400 before a service call would fail with a 500.
func marshals(s string) bool {
	_, err := proto.Marshal(wrapperspb.String(s))
	return err == nil
}

func FuzzValidUTF8(f *testing.F) {
	for _, s := range []struct{ path, query string }{
		{"videos/abc", "cursor=xyz"},
		{"videos/%C3%A9t%C3%A9", "q=%E2%82%AC&%E2%82%AC=1"},
		{"feed", "cursor=%ZZ"},
		{"videos/%FF", ""},
		{"videos/\xff", ""},
		{"videos/%C3%28/like", ""},
		{"feed", "cursor=%FF"},
		{"feed", "cursor=ok&cursor=%C3%28"},
		{"feed", "%FF=1"},
		{"feed", "a=%ED%A0%80"}, // an encoded surrogate half
		{"%2e%2e/x", ""},
	} {
		f.Add(s.path, s.query)
	}
	f.Fuzz(func(t *testing.T, path, query string) {
		u, err := url.ParseRequestURI("/" + path + "?" + query)
		if err != nil {
			return
		}
		ran := false
		var seen *url.URL
		h := ValidUTF8(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { ran, seen = true, r.URL }))
		r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil)
		r.URL = u
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)

		all := []string{u.Path}
		for k, vs := range u.Query() {
			all = append(all, k)
			all = append(all, vs...)
		}
		allMarshal := true
		for _, s := range all {
			if !marshals(s) {
				allMarshal = false
			}
		}
		if ran {
			if !allMarshal || seen != u {
				t.Fatalf("handler ran with %q: path or query does not marshal into a proto3 string", u.String())
			}
			return
		}
		if allMarshal {
			t.Fatalf("handler blocked for %q, whose path and query all marshal", u.String())
		}
		if p := decodeProblem(t, rec); rec.Code != http.StatusBadRequest || p.Code != "INVALID_UTF8" {
			t.Fatalf("got %d %q, want 400 INVALID_UTF8", rec.Code, p.Code)
		}
	})
}
