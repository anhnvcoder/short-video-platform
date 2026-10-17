package httpx

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
)

// StatusClientClosedRequest is the non-standard status (from nginx) for a request the client
// gave up on; gRPC CANCELLED maps to it.
const StatusClientClosedRequest = 499

// problem is the RFC 9457 body of every error response (docs/architecture.md §8.4).
type problem struct {
	Type    string `json:"type"`
	Title   string `json:"title"`
	Status  int    `json:"status"`
	Detail  string `json:"detail"`
	Code    string `json:"code"`
	TraceID string `json:"trace_id"`
}

// WriteProblem writes an application/problem+json response with status, the machine-readable
// code (UPPER_SNAKE_CASE) and detail, for errors the gateway itself raises. Leave detail empty
// for 5xx statuses.
func WriteProblem(w http.ResponseWriter, r *http.Request, status int, code, detail string) {
	title := http.StatusText(status)
	if status == StatusClientClosedRequest {
		title = "Client Closed Request"
	}
	body, err := json.Marshal(problem{
		Type:    "about:blank",
		Title:   title,
		Status:  status,
		Detail:  detail,
		Code:    code,
		TraceID: traceID(r.Context()),
	})
	if err != nil {
		// A struct of strings and an int always marshals.
		panic(err)
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// WriteRateLimited writes the 429 problem of a request the rate limit class refused (code
// RATE_LIMITED, docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md section 2), with a
// Retry-After header of retryAfter in whole seconds, rounded up and at least 1. The access log
// line of the request names class.
func WriteRateLimited(w http.ResponseWriter, r *http.Request, class string, retryAfter time.Duration) {
	if state, ok := r.Context().Value(logStateKey).(*logState); ok {
		state.rateLimit = class
	}
	secs := max(int64((retryAfter+time.Second-1)/time.Second), 1)
	w.Header().Set("Retry-After", strconv.FormatInt(secs, 10))
	WriteProblem(w, r, http.StatusTooManyRequests, "RATE_LIMITED", "too many requests")
}

// Routes serves mux, answering a request that matches no route with a problem response instead
// of ServeMux's text/plain one: 404 NOT_FOUND, or 405 METHOD_NOT_ALLOWED with the Allow header
// ServeMux sets. A matched request has its route set on the span and metric of Trace before the
// route's handler, and so before its authentication and rate limit, runs.
func Routes(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h, pattern := mux.Handler(r)
		if pattern != "" {
			setRoute(r, pattern)
			mux.ServeHTTP(w, r)
			return
		}
		h.ServeHTTP(&unmatchedWriter{ResponseWriter: w, r: r}, r)
	})
}

// setRoute names the request's span "METHOD /route" and sets http.route on the span and on
// http.server.request.duration (docs/adr/0011-observability-stage3.md, section 2). The route is
// the path of the mux pattern, such as /videos/{video_id}, never the URL path, which holds ids.
// otelhttp cannot see the pattern itself: ServeMux sets it on a copy of the request made deeper
// in the chain.
func setRoute(r *http.Request, pattern string) {
	i := strings.IndexByte(pattern, '/')
	if i < 0 {
		return
	}
	route := pattern[i:]
	span := trace.SpanFromContext(r.Context())
	span.SetName(r.Method + " " + route)
	span.SetAttributes(semconv.HTTPRoute(route))
	labeler, _ := otelhttp.LabelerFromContext(r.Context())
	labeler.Add(semconv.HTTPRoute(route))
}

// unmatchedWriter replaces the 404 or 405 reply of ServeMux with a problem response. Other
// statuses, such as the redirect to a cleaned path, pass through.
type unmatchedWriter struct {
	http.ResponseWriter
	r        *http.Request
	replaced bool
}

func (w *unmatchedWriter) WriteHeader(status int) {
	switch status {
	case http.StatusNotFound:
		w.replaced = true
		WriteProblem(w.ResponseWriter, w.r, status, "NOT_FOUND", "no route for this path")
	case http.StatusMethodNotAllowed:
		w.replaced = true
		WriteProblem(w.ResponseWriter, w.r, status, "METHOD_NOT_ALLOWED", "method not allowed for this path")
	default:
		w.ResponseWriter.WriteHeader(status)
	}
}

func (w *unmatchedWriter) Write(b []byte) (int, error) {
	if w.replaced {
		return len(b), nil // ServeMux's text/plain body
	}
	return w.ResponseWriter.Write(b)
}

// grpcMapping is the HTTP status and code name of one gRPC code.
type grpcMapping struct {
	status int
	name   string
}

// grpcToHTTP is the table of docs/architecture.md §8.4.
var grpcToHTTP = map[codes.Code]grpcMapping{
	codes.OK:                 {http.StatusOK, "OK"},
	codes.InvalidArgument:    {http.StatusBadRequest, "INVALID_ARGUMENT"},
	codes.FailedPrecondition: {http.StatusBadRequest, "FAILED_PRECONDITION"},
	codes.OutOfRange:         {http.StatusBadRequest, "OUT_OF_RANGE"},
	codes.Unauthenticated:    {http.StatusUnauthorized, "UNAUTHENTICATED"},
	codes.PermissionDenied:   {http.StatusForbidden, "PERMISSION_DENIED"},
	codes.NotFound:           {http.StatusNotFound, "NOT_FOUND"},
	codes.AlreadyExists:      {http.StatusConflict, "ALREADY_EXISTS"},
	codes.Aborted:            {http.StatusConflict, "ABORTED"},
	codes.ResourceExhausted:  {http.StatusTooManyRequests, "RESOURCE_EXHAUSTED"},
	codes.Canceled:           {StatusClientClosedRequest, "CANCELLED"},
	codes.Unknown:            {http.StatusInternalServerError, "UNKNOWN"},
	codes.Internal:           {http.StatusInternalServerError, "INTERNAL"},
	codes.DataLoss:           {http.StatusInternalServerError, "DATA_LOSS"},
	codes.Unimplemented:      {http.StatusNotImplemented, "UNIMPLEMENTED"},
	codes.Unavailable:        {http.StatusServiceUnavailable, "UNAVAILABLE"},
	codes.DeadlineExceeded:   {http.StatusGatewayTimeout, "DEADLINE_EXCEEDED"},
}

// WriteGRPCError writes the problem response for err, an error returned by a gRPC call, mapped
// by docs/architecture.md §8.4: code is the ErrorInfo reason, or the gRPC code name when there
// is none, and detail is the service's message. A wrapped gRPC error (fmt.Errorf("...: %w", err))
// is unwrapped first, so the wrapping text never reaches detail.
//
// A 5xx response never carries the service's message or reason (threat model IN-8): detail is
// empty, code is the gRPC code name, and the original error goes to an ERROR log line with the
// trace_id, the route pattern (route, empty outside a route) and the gRPC code (code). The error
// tracker groups that line by route and reads the error's type and code from error, which stays
// an error value. An error that is not a gRPC status is answered as INTERNAL.
func WriteGRPCError(w http.ResponseWriter, r *http.Request, err error) {
	var se interface{ GRPCStatus() *status.Status }
	ok := errors.As(err, &se)
	st := status.Convert(err)
	if ok {
		st = se.GRPCStatus()
	}
	m, known := grpcToHTTP[st.Code()]
	if !ok || !known {
		m = grpcToHTTP[codes.Internal]
	}
	if m.status >= http.StatusInternalServerError {
		slog.ErrorContext(r.Context(), "grpc call failed",
			slog.String("route", r.Pattern),
			slog.String("code", st.Code().String()),
			slog.Any("error", err),
		)
		WriteProblem(w, r, m.status, m.name, "")
		return
	}
	code := grpcerr.Reason(err)
	if code == "" {
		code = m.name
	}
	WriteProblem(w, r, m.status, code, st.Message())
}
