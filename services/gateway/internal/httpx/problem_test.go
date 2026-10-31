package httpx

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
)

// requestWithTrace returns the request a handler behind Trace sees, and its trace-id.
func requestWithTrace(t *testing.T) (*http.Request, string) {
	var seen *http.Request
	Trace(testServer, ClientAddr{})(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { seen = r })).
		ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil))
	return seen, traceID(seen.Context())
}

func TestGRPCCodeTable(t *testing.T) {
	tests := []struct {
		code   codes.Code
		status int
		title  string
		name   string
	}{
		{codes.OK, 200, "OK", "OK"},
		{codes.InvalidArgument, 400, "Bad Request", "INVALID_ARGUMENT"},
		{codes.FailedPrecondition, 400, "Bad Request", "FAILED_PRECONDITION"},
		{codes.OutOfRange, 400, "Bad Request", "OUT_OF_RANGE"},
		{codes.Unauthenticated, 401, "Unauthorized", "UNAUTHENTICATED"},
		{codes.PermissionDenied, 403, "Forbidden", "PERMISSION_DENIED"},
		{codes.NotFound, 404, "Not Found", "NOT_FOUND"},
		{codes.AlreadyExists, 409, "Conflict", "ALREADY_EXISTS"},
		{codes.Aborted, 409, "Conflict", "ABORTED"},
		{codes.ResourceExhausted, 429, "Too Many Requests", "RESOURCE_EXHAUSTED"},
		{codes.Canceled, 499, "Client Closed Request", "CANCELLED"},
		{codes.Unknown, 500, "Internal Server Error", "UNKNOWN"},
		{codes.Internal, 500, "Internal Server Error", "INTERNAL"},
		{codes.DataLoss, 500, "Internal Server Error", "DATA_LOSS"},
		{codes.Unimplemented, 501, "Not Implemented", "UNIMPLEMENTED"},
		{codes.Unavailable, 503, "Service Unavailable", "UNAVAILABLE"},
		{codes.DeadlineExceeded, 504, "Gateway Timeout", "DEADLINE_EXCEEDED"},
	}
	if len(grpcToHTTP) != len(tests) {
		t.Errorf("table has %d codes, want %d", len(grpcToHTTP), len(tests))
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if m := grpcToHTTP[tt.code]; m.status != tt.status || m.name != tt.name {
				t.Fatalf("table entry = %+v, want {%d %s}", m, tt.status, tt.name)
			}
			if tt.code == codes.OK {
				return // a call that succeeded returns no error to write
			}
			const reason, msg = "SOME_REASON", "db host 10.0.0.7 refused: SELECT * FROM users"
			for _, withReason := range []bool{true, false} {
				err := status.Error(tt.code, msg)
				if withReason {
					err = grpcerr.New(tt.code, reason, msg)
				}
				logs := captureLog(t)
				r, traceID := requestWithTrace(t)
				rec := httptest.NewRecorder()
				WriteGRPCError(rec, r, err)

				p := decodeProblem(t, rec)
				if rec.Code != tt.status || p.Title != tt.title || p.TraceID != traceID {
					t.Errorf("reason=%v: status %d title %q trace_id %q; want %d %q %q",
						withReason, rec.Code, p.Title, p.TraceID, tt.status, tt.title, traceID)
				}
				wantCode, wantDetail := tt.name, msg
				if withReason {
					wantCode = reason
				}
				if tt.status >= 500 {
					wantCode, wantDetail = tt.name, ""
					if strings.Contains(rec.Body.String(), "10.0.0.7") || strings.Contains(rec.Body.String(), reason) {
						t.Errorf("5xx body leaks the service message or reason: %s", rec.Body)
					}
					lines := logRecords(t, logs, "grpc call failed")
					if len(lines) != 1 || !strings.Contains(fmt.Sprint(lines[0]["error"]), "10.0.0.7") || lines[0]["trace_id"] != traceID ||
						lines[0]["code"] != tt.code.String() || lines[0]["grpc_code"] != nil {
						t.Errorf("5xx log = %v, want the original error with trace_id %s and code %s", lines, traceID, tt.code)
					}
				}
				if p.Code != wantCode || p.Detail != wantDetail {
					t.Errorf("reason=%v: code %q detail %q; want %q %q", withReason, p.Code, p.Detail, wantCode, wantDetail)
				}
			}
		})
	}
}

func TestWriteGRPCErrorUnwrapsWrappedStatus(t *testing.T) {
	wrapped := fmt.Errorf("get video: %w", grpcerr.New(codes.NotFound, "VIDEO_NOT_FOUND", "video not found"))
	rec := httptest.NewRecorder()
	WriteGRPCError(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil), wrapped)
	p := decodeProblem(t, rec)
	if rec.Code != 404 || p.Code != "VIDEO_NOT_FOUND" || p.Detail != "video not found" {
		t.Errorf("got %d code %q detail %q, want 404 VIDEO_NOT_FOUND %q", rec.Code, p.Code, p.Detail, "video not found")
	}
}

func TestWriteGRPCErrorNonStatusIsInternal(t *testing.T) {
	captureLog(t)
	rec := httptest.NewRecorder()
	WriteGRPCError(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil), errors.New("dial tcp 10.0.0.7:9101: refused"))
	p := decodeProblem(t, rec)
	if rec.Code != 500 || p.Code != "INTERNAL" || p.Detail != "" {
		t.Errorf("got %d %+v, want 500 INTERNAL with empty detail", rec.Code, p)
	}
}

func TestWriteProblem(t *testing.T) {
	r, traceID := requestWithTrace(t)
	rec := httptest.NewRecorder()
	WriteProblem(rec, r, http.StatusUnauthorized, "INVALID_TOKEN", "missing or invalid access token")
	p := decodeProblem(t, rec)
	want := problem{"about:blank", "Unauthorized", 401, "missing or invalid access token", "INVALID_TOKEN", traceID}
	if p != want {
		t.Errorf("problem = %+v, want %+v", p, want)
	}
}

func TestWriteRateLimited(t *testing.T) {
	for _, tt := range []struct {
		retryAfter time.Duration
		want       string
	}{
		{0, "1"},
		{time.Nanosecond, "1"},
		{time.Second, "1"},
		{1500 * time.Millisecond, "2"},
		{time.Minute, "60"},
	} {
		t.Run(tt.retryAfter.String(), func(t *testing.T) {
			r, id := requestWithTrace(t)
			rec := httptest.NewRecorder()
			WriteRateLimited(rec, r, "login-ip", tt.retryAfter)
			if got := rec.Header().Get("Retry-After"); got != tt.want {
				t.Errorf("Retry-After = %q, want %q", got, tt.want)
			}
			p := decodeProblem(t, rec)
			want := problem{Type: "about:blank", Title: "Too Many Requests", Status: 429, Detail: "too many requests", Code: "RATE_LIMITED", TraceID: id}
			if p != want {
				t.Errorf("problem = %+v, want %+v", p, want)
			}
		})
	}
}

func TestAccessLogNamesRateLimit(t *testing.T) {
	logs := captureLog(t)
	h := Trace(testServer, ClientAddr{})(AccessLog(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		WriteRateLimited(w, r, "register", time.Minute)
	})))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/auth/register", nil))
	lines := logRecords(t, logs, "http request")
	if len(lines) != 1 || lines[0]["status"] != 429.0 || lines[0]["rate_limit"] != "register" {
		t.Errorf("access log = %v, want one line with status 429 and rate_limit register", lines)
	}
}
