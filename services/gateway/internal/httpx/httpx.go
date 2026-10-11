// Package httpx is the gateway's HTTP edge: the server with its timeouts, JSON request bodies,
// problem+json errors (RFC 9457, docs/architecture.md §8.4), the middleware every route passes
// through, and the gRPC metadata sent to the services.
//
// The package logs through slog.Default; the gateway's main sets it to a logx logger, so the
// trace_id and user_id the middleware stores with logx.With land in every record.
package httpx

import (
	"context"
	"net/http"
	"time"

	"google.golang.org/grpc/metadata"

	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
)

// Server limits (threat model RL-4): Go's http.Server has no timeout by default.
const (
	readHeaderTimeout = 5 * time.Second
	readTimeout       = 10 * time.Second
	writeTimeout      = 15 * time.Second
	idleTimeout       = 60 * time.Second
	maxHeaderBytes    = 16 << 10
)

// NewServer returns an http.Server for handler on addr with the timeouts and header limit of
// threat model RL-4. It panics when handler is nil or http.DefaultServeMux, which a nil handler
// would serve too: anything a package registers there, such as net/http/pprof, must never be
// exposed (OPS-1). Pass a mux built with http.NewServeMux.
func NewServer(addr string, handler http.Handler) *http.Server {
	if handler == nil || handler == http.DefaultServeMux {
		panic("httpx: NewServer needs its own handler, not nil or http.DefaultServeMux")
	}
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		MaxHeaderBytes:    maxHeaderBytes,
	}
}

type ctxKey int

const (
	traceparentKey ctxKey = iota
	userIDKey
	logStateKey
)

// OutgoingContext returns ctx with gRPC outgoing metadata built from scratch (threat model
// IN-1): x-user-id when the request is authenticated and the traceparent of the request. Any
// outgoing metadata already in ctx is replaced, and no client header is ever copied.
func OutgoingContext(ctx context.Context) context.Context {
	md := metadata.MD{}
	if id, ok := ctx.Value(userIDKey).(string); ok {
		md.Set(callerid.MetadataKey, id)
	}
	if tp, ok := ctx.Value(traceparentKey).(string); ok {
		md.Set(traceparent.MetadataKey, tp)
	}
	return metadata.NewOutgoingContext(ctx, md)
}

// UserID returns the user id RequireAuth put into ctx, or "" outside RequireAuth.
func UserID(ctx context.Context) string {
	id, _ := ctx.Value(userIDKey).(string)
	return id
}

// traceID returns the trace-id of the request's traceparent, or "" outside Trace.
func traceID(ctx context.Context) string {
	tp, _ := ctx.Value(traceparentKey).(string)
	id, _ := traceparent.TraceID(tp)
	return id
}
