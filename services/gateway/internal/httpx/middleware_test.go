package httpx

import (
	"bytes"
	"crypto/ed25519"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/metadata"

	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
)

const (
	testKID     = "k1"
	userID      = "01928c6e-7b3a-7cde-8f01-23456789abcd"
	otherUserID = "01928c6e-7b3a-7cde-8f01-000000000000"
	// clientTraceparent is a valid traceparent a client might send. Only TrustTraceContext may make
	// it the parent; everywhere else the gateway must ignore it.
	clientTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	clientTraceID     = "4bf92f3577b34da6a3ce929d0e0e4736"
)

// edge is the middleware chain the gateway uses, in front of a mux with a private route, a
// public route and a route that panics. Each handler records the outgoing metadata it would
// send to a service and the span context of its request.
type edge struct {
	handler http.Handler
	key     ed25519.PrivateKey
	ran     bool
	md      metadata.MD
	span    trace.SpanContext
}

func newEdge(t *testing.T) *edge {
	t.Helper()
	key, err := authtoken.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	e := &edge{key: key}
	verifier := authtoken.NewVerifier(map[string]ed25519.PublicKey{testKID: key.Public().(ed25519.PublicKey)})
	record := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		e.ran = true
		e.md, _ = metadata.FromOutgoingContext(OutgoingContext(r.Context()))
		e.span = trace.SpanContextFromContext(r.Context())
		_, _ = w.Write([]byte("hello"))
	})
	mux := http.NewServeMux()
	mux.Handle("GET /private/{id}", RequireAuth(verifier)(record))
	mux.Handle("GET /public", record)
	mux.HandleFunc("GET /panic", func(http.ResponseWriter, *http.Request) { panic("boom") })
	e.handler = Trace(testServer, ClientAddr{})(Recover(AccessLog(mux)))
	return e
}

func (e *edge) serve(r *http.Request) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, r)
	return rec
}

// claims returns valid claims for sub, as the issuer writes them.
func claims(sub string) jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss": authtoken.IssuerName,
		"aud": []string{authtoken.Audience},
		"sub": sub,
		"iat": now.Unix(),
		"exp": now.Add(authtoken.TTL).Unix(),
	}
}

func sign(t testing.TB, method jwt.SigningMethod, key any, kid string, c jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(method, c)
	tok.Header["kid"] = kid
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func (e *edge) validToken(t *testing.T) string {
	t.Helper()
	tok, _, err := authtoken.NewIssuer(testKID, e.key).Issue(userID)
	if err != nil {
		t.Fatal(err)
	}
	return tok.Reveal()
}

func TestRequireAuthRejects(t *testing.T) {
	e := newEdge(t)
	valid := e.validToken(t)
	pubKey := []byte(e.key.Public().(ed25519.PublicKey))
	expired := claims(userID)
	expired["iat"] = time.Now().Add(-2 * time.Hour).Unix()
	expired["exp"] = time.Now().Add(-time.Hour).Unix()
	wrongAud := claims(userID)
	wrongAud["aud"] = []string{"other-api"}

	tests := []struct {
		name   string
		target string
		header []string // Authorization values
		cookie string
	}{
		{name: "no header", target: "/private/1"},
		{name: "basic scheme", target: "/private/1", header: []string{"Basic dXNlcjpwYXNz"}},
		{name: "bearer without token", target: "/private/1", header: []string{"Bearer"}},
		{name: "bearer with empty token", target: "/private/1", header: []string{"Bearer "}},
		{name: "token without scheme", target: "/private/1", header: []string{valid}},
		{name: "token in query", target: "/private/1?access_token=" + valid},
		{name: "token in cookie", target: "/private/1", cookie: valid},
		{name: "two headers", target: "/private/1", header: []string{"Bearer " + valid, "Bearer " + valid}},
		{name: "alg none", target: "/private/1", header: []string{"Bearer " + sign(t, jwt.SigningMethodNone, jwt.UnsafeAllowNoneSignatureType, testKID, claims(userID))}},
		{name: "HS256 keyed with the public key", target: "/private/1", header: []string{"Bearer " + sign(t, jwt.SigningMethodHS256, pubKey, testKID, claims(userID))}},
		{name: "expired", target: "/private/1", header: []string{"Bearer " + sign(t, jwt.SigningMethodEdDSA, e.key, testKID, expired)}},
		{name: "wrong aud", target: "/private/1", header: []string{"Bearer " + sign(t, jwt.SigningMethodEdDSA, e.key, testKID, wrongAud)}},
		{name: "unknown kid", target: "/private/1", header: []string{"Bearer " + sign(t, jwt.SigningMethodEdDSA, e.key, "k2", claims(userID))}},
		{name: "garbage", target: "/private/1", header: []string{"Bearer not.a.jwt"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			captureLog(t)
			e.ran = false
			r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, tt.target, nil)
			for _, v := range tt.header {
				r.Header.Add("Authorization", v)
			}
			if tt.cookie != "" {
				r.Header.Set("Cookie", "access_token="+tt.cookie)
			}
			rec := e.serve(r)
			if e.ran {
				t.Error("handler ran, want it blocked")
			}
			p := decodeProblem(t, rec)
			if rec.Code != http.StatusUnauthorized || p.Code != "INVALID_TOKEN" || p.Detail != invalidTokenDetail {
				t.Errorf("got %d %q %q, want 401 INVALID_TOKEN %q", rec.Code, p.Code, p.Detail, invalidTokenDetail)
			}
			if got := rec.Header().Get("WWW-Authenticate"); got != "Bearer" {
				t.Errorf("WWW-Authenticate = %q, want Bearer", got)
			}
			if p.TraceID == "" {
				t.Error("trace_id is empty")
			}
		})
	}
}

func TestRequireAuthPassesIdentityFromTokenOnly(t *testing.T) {
	captureLog(t)
	e := newEdge(t)
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/private/1", nil)
	r.Header.Set("Authorization", "bearer "+e.validToken(t))
	r.Header.Set("X-User-Id", otherUserID)
	r.Header.Set("Traceparent", clientTraceparent)
	r.Header.Set("X-Foo", "bar")
	rec := e.serve(r)
	if rec.Code != http.StatusOK || !e.ran {
		t.Fatalf("status %d, ran = %v; want 200 from the handler", rec.Code, e.ran)
	}
	if got := e.md.Get(callerid.MetadataKey); len(got) != 1 || got[0] != userID {
		t.Errorf("x-user-id = %v, want [%s] from the token", got, userID)
	}
	if !e.span.IsValid() || e.span.TraceID().String() == clientTraceID {
		t.Errorf("request span = %v, want a new trace, not the client's", e.span)
	}
	if len(e.md) != 1 {
		t.Errorf("metadata = %v, want only x-user-id", e.md)
	}
}

func TestPublicRouteSendsNoUserID(t *testing.T) {
	captureLog(t)
	e := newEdge(t)
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/public", nil)
	r.Header.Set("X-User-Id", otherUserID)
	if rec := e.serve(r); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if len(e.md) != 0 {
		t.Errorf("metadata = %v, want none", e.md)
	}
}

func TestAccessLog(t *testing.T) {
	logs := captureLog(t)
	e := newEdge(t)
	token := e.validToken(t)
	const queryToken = "query-secret-token-value"
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/private/42?access_token="+queryToken, nil)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Traceparent", clientTraceparent)
	e.serve(r)
	e.serve(httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/private/42?access_token="+queryToken, nil))

	lines := logRecords(t, logs, "http request")
	if len(lines) != 2 {
		t.Fatalf("access log lines = %d, want 2: %s", len(lines), logs)
	}
	ok, denied := lines[0], lines[1]
	want := map[string]any{"method": "GET", "route": "GET /private/{id}", "status": 200.0, "bytes": 5.0, "user_id": userID}
	for k, v := range want {
		if ok[k] != v {
			t.Errorf("authenticated line %s = %v, want %v", k, ok[k], v)
		}
	}
	if ok["trace_id"] != e.span.TraceID().String() || ok["span_id"] != e.span.SpanID().String() {
		t.Errorf("trace_id, span_id = %v, %v; want %s, %s of the request's span",
			ok["trace_id"], ok["span_id"], e.span.TraceID(), e.span.SpanID())
	}
	if _, has := ok["duration_ms"]; !has {
		t.Error("duration_ms missing")
	}
	if denied["status"] != 401.0 || denied["user_id"] != nil {
		t.Errorf("unauthenticated line = %v, want status 401 and no user_id", denied)
	}
	for _, secret := range []string{token, queryToken, clientTraceID, "access_token"} {
		if strings.Contains(logs.String(), secret) {
			t.Errorf("log contains %q:\n%s", secret, logs)
		}
	}
}

func TestRecover(t *testing.T) {
	logs := captureLog(t)
	e := newEdge(t)
	rec := e.serve(httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/panic", nil))
	p := decodeProblem(t, rec)
	if rec.Code != http.StatusInternalServerError || p.Code != "INTERNAL" || p.Detail != "" || p.TraceID == "" {
		t.Errorf("got %d %+v, want 500 INTERNAL, empty detail, a trace_id", rec.Code, p)
	}
	if bytes.Contains(rec.Body.Bytes(), []byte("boom")) {
		t.Errorf("response leaks the panic value: %s", rec.Body)
	}
	panics := logRecords(t, logs, "panic in http handler")
	if len(panics) != 1 || panics[0]["panic"] != "boom" || !strings.Contains(fmt.Sprint(panics[0]["stack"]), "middleware_test.go") {
		t.Errorf("panic log = %v, want the value and a stack", panics)
	}
	if panics[0]["trace_id"] != p.TraceID {
		t.Errorf("panic log trace_id = %v, want %s", panics[0]["trace_id"], p.TraceID)
	}
	access := logRecords(t, logs, "http request")
	if len(access) != 1 || access[0]["status"] != 500.0 || access[0]["route"] != "GET /panic" {
		t.Errorf("access log = %v, want one line with status 500 and route GET /panic", access)
	}
}

func TestValidUTF8(t *testing.T) {
	ran := false
	h := ValidUTF8(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { ran = true }))

	for _, target := range []string{"/videos/abc?cursor=xyz", "/videos/%C3%A9t%C3%A9?q=%E2%82%AC&%E2%82%AC=1", "/feed?cursor=%ZZ"} {
		ran = false
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, target, nil))
		if rec.Code != http.StatusOK || !ran {
			t.Errorf("%s: status %d, handler ran %v; want 200 from the handler", target, rec.Code, ran)
		}
	}

	for _, target := range []string{
		"/videos/%FF",
		"/videos/\xff",
		"/videos/%C3%28/like",
		"/feed?cursor=%FF",
		"/feed?cursor=ok&cursor=%C3%28",
		"/feed?%FF=1",
	} {
		ran = false
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, target, nil))
		if rec.Code != http.StatusBadRequest || ran {
			t.Errorf("%q: status %d, handler ran %v; want 400 without the handler", target, rec.Code, ran)
			continue
		}
		if p := decodeProblem(t, rec); p.Code != "INVALID_UTF8" || p.Detail == "" {
			t.Errorf("%q: problem = %+v, want code INVALID_UTF8 with a detail", target, p)
		}
	}
}

// TestTrustTraceContextAcceptsLaterVersion: W3C TraceContext asks a reader to parse a version it
// does not know (01 to fe) as 00, so such a traceparent continues the sender's trace; only ff
// and a version that is not hex start a new root (TestTrustTraceContextInvalidStartsNewRoot).
func TestTrustTraceContextAcceptsLaterVersion(t *testing.T) {
	spans := recordSpans(t)
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/x", nil)
	r.Header.Set("Traceparent", "01-"+clientTraceID+"-"+clientSpanID+"-01")
	TrustTraceContext(Trace(testServer, ClientAddr{})(http.NotFoundHandler())).ServeHTTP(httptest.NewRecorder(), r)

	ended := spans.Ended()
	if len(ended) != 1 {
		t.Fatalf("spans = %d, want 1", len(ended))
	}
	s := ended[0]
	if got := s.SpanContext().TraceID().String(); got != clientTraceID {
		t.Errorf("trace id = %s, want the client's %s", got, clientTraceID)
	}
	if p := s.Parent(); p.SpanID().String() != clientSpanID || !p.IsRemote() {
		t.Errorf("parent = %s (remote %v), want the remote span %s", p.SpanID(), p.IsRemote(), clientSpanID)
	}
}
