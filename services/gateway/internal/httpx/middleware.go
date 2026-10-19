package httpx

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"runtime/debug"
	"strings"
	"time"
	"unicode/utf8"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
)

// Trace returns the otelhttp handler around next: every request gets a server span and the
// http.server.request.duration metric (docs/adr/0011-observability-stage3.md, sections 2 and 3).
// The span is always a new root trace: the propagator is empty, so a traceparent, tracestate or
// baggage the client sent is neither read nor linked (ADR-0007 section 8). logx writes the
// span's trace_id and span_id into every record logged with the request's context, and the
// stats handler of ClientTelemetry continues the trace in the services. The span is named after
// the method until Routes names the matched route. Its client.address comes from clientAddr,
// the same as the rate limits by IP: otelhttp would take the first element of X-Forwarded-For,
// which the client writes (threat model RL-1).
//
// server is the gateway's host:port, with a numeric port; it gives the server.address and
// server.port of spans and metrics. Without it otelhttp takes both from the Host header, which
// the client sets: every new value would be a new metric series, until the SDK's limit on series
// folds real routes into its overflow series (ADR-0011 section 5).
//
// The probes /healthz and /readyz, which run every few seconds, get neither span nor metric;
// they are matched by their exact path.
func Trace(server string, clientAddr ClientAddr) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			trace.SpanFromContext(r.Context()).SetAttributes(semconv.ClientAddress(clientAddr.Of(r)))
			next.ServeHTTP(w, r)
		}), "",
			otelhttp.WithServerName(server),
			otelhttp.WithPropagators(propagation.NewCompositeTextMapPropagator()),
			otelhttp.WithFilter(func(r *http.Request) bool {
				return r.URL.Path != "/healthz" && r.URL.Path != "/readyz"
			}),
		)
	}
}

// Recover turns a panic in next into a 500 problem response; the panic value and stack go to
// the log only.
func Recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if p := recover(); p != nil {
				slog.LogAttrs(r.Context(), slog.LevelError, "panic in http handler",
					slog.Any("panic", p),
					slog.String("stack", string(debug.Stack())),
				)
				WriteProblem(w, r, http.StatusInternalServerError, "INTERNAL", "")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// ValidUTF8 answers 400 INVALID_UTF8 when the decoded path, or a key or value of the query, is
// not valid UTF-8. Path values and query values go into proto3 string fields, which grpc-go
// refuses to marshal when they are not UTF-8: the call would fail as INTERNAL, a 500 the client
// caused. JSON bodies need no check, since encoding/json turns invalid UTF-8 into U+FFFD.
func ValidUTF8(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !validURL(r.URL) {
			WriteProblem(w, r, http.StatusBadRequest, "INVALID_UTF8", "path and query must be valid UTF-8")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// validURL reports whether the decoded path and every query key and value of u are valid UTF-8.
// ServeMux decodes path values from the same path, and handlers read the same parsed query.
func validURL(u *url.URL) bool {
	if !utf8.ValidString(u.Path) {
		return false
	}
	for k, vs := range u.Query() {
		if !utf8.ValidString(k) {
			return false
		}
		for _, v := range vs {
			if !utf8.ValidString(v) {
				return false
			}
		}
	}
	return true
}

// logState carries what the access log learns only after next ran: RequireAuth, deeper in the
// chain, writes the user id here because it cannot change the context AccessLog holds.
type logState struct {
	userID string
	// rateLimit is the class that refused the request, set by WriteRateLimited.
	rateLimit string
}

// AccessLog writes one line per request: method, route pattern, status, duration, response
// size, trace_id, user_id when authenticated and rate_limit when a rate limit refused it. Headers, query string and bodies are never
// logged, since they carry tokens and passwords (threat model JWT-8).
func AccessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		state := &logState{}
		r = r.WithContext(context.WithValue(r.Context(), logStateKey, state))
		rec := &statusRecorder{ResponseWriter: w}
		finished := false
		// Deferred so a panic, answered by an outer Recover, still gets its line.
		defer func() {
			status := rec.status
			if status == 0 {
				status = http.StatusOK
				if !finished {
					status = http.StatusInternalServerError
				}
			}
			attrs := []slog.Attr{
				slog.String("method", r.Method),
				// ServeMux sets Pattern on the request it was given, which is r.
				slog.String("route", r.Pattern),
				slog.Int("status", status),
				slog.Float64("duration_ms", float64(time.Since(start).Microseconds())/1000),
				slog.Int64("bytes", rec.bytes),
			}
			if state.userID != "" {
				attrs = append(attrs, slog.String("user_id", state.userID))
			}
			if state.rateLimit != "" {
				attrs = append(attrs, slog.String("rate_limit", state.rateLimit))
			}
			slog.LogAttrs(r.Context(), slog.LevelInfo, "http request", attrs...)
		}()
		next.ServeHTTP(rec, r)
		finished = true
	})
}

// statusRecorder remembers the status and counts the bytes written through it.
type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (s *statusRecorder) WriteHeader(code int) {
	if s.status == 0 {
		s.status = code
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	n, err := s.ResponseWriter.Write(b)
	s.bytes += int64(n)
	return n, err
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (s *statusRecorder) Unwrap() http.ResponseWriter {
	return s.ResponseWriter
}

// invalidTokenDetail is the same for every reason a token is rejected, so a client learns
// nothing about why.
const invalidTokenDetail = "missing or invalid access token"

// RequireAuth lets a request through only with a valid access token in the Authorization header
// ("Bearer <token>", scheme case-insensitive), never from the query string or a cookie (threat
// model JWT-3). The user id then goes into the context (for OutgoingContext) and the log
// context. Any failure is a 401 problem with code INVALID_TOKEN, a WWW-Authenticate: Bearer
// header and one detail for every reason.
func RequireAuth(verifier *authtoken.Verifier) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			userID, err := authenticate(verifier, r)
			if err != nil {
				slog.InfoContext(r.Context(), "access token rejected", slog.String("error", err.Error()))
				w.Header().Set("WWW-Authenticate", "Bearer")
				WriteProblem(w, r, http.StatusUnauthorized, "INVALID_TOKEN", invalidTokenDetail)
				return
			}
			if state, ok := r.Context().Value(logStateKey).(*logState); ok {
				state.userID = userID
			}
			ctx := context.WithValue(r.Context(), userIDKey, userID)
			ctx = logx.With(ctx, slog.String("user_id", userID))
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func authenticate(verifier *authtoken.Verifier, r *http.Request) (string, error) {
	values := r.Header.Values("Authorization")
	if len(values) != 1 {
		return "", errors.New("want exactly one Authorization header")
	}
	scheme, token, _ := strings.Cut(values[0], " ")
	if !strings.EqualFold(scheme, "Bearer") || token == "" {
		return "", errors.New("authorization scheme is not Bearer")
	}
	return verifier.Verify(token)
}
