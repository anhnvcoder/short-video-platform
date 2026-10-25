// Package httpx is the gateway's HTTP edge: the server with its timeouts, JSON request bodies,
// problem+json errors (RFC 9457, docs/architecture.md §8.4), the middleware every route passes
// through, and the gRPC metadata sent to the services.
//
// The package logs through slog.Default; the gateway's main sets it to a logx logger, so every
// record carries the trace_id and span_id of the request's span and the user_id RequireAuth
// stores with logx.With.
package httpx

import (
	"context"
	"net/http"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc/filters"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"

	"github.com/anhnvcoder/short-video-platform/internal/callerid"
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
	userIDKey ctxKey = iota
	logStateKey
)

// OutgoingContext returns ctx with gRPC outgoing metadata built from scratch (threat model
// IN-1): x-user-id when the request is authenticated. Any outgoing metadata already in ctx is
// replaced, and no client header is ever copied. The traceparent of the request's span is added
// later, by the stats handler of ClientTelemetry.
func OutgoingContext(ctx context.Context) context.Context {
	md := metadata.MD{}
	if id, ok := ctx.Value(userIDKey).(string); ok {
		md.Set(callerid.MetadataKey, id)
	}
	return metadata.NewOutgoingContext(ctx, md)
}

// ClientTelemetry is the dial option of every connection to a service: the otelgrpc stats
// handler gives each RPC a client span, child of the request's span, and the
// rpc.client.call.duration metric, and sends the span's traceparent in the metadata through the
// global propagator. The health checks of /readyz are left out, as /readyz itself is.
func ClientTelemetry() grpc.DialOption {
	return grpc.WithStatsHandler(otelgrpc.NewClientHandler(
		otelgrpc.WithFilter(filters.Not(filters.FullMethodName(healthpb.Health_Check_FullMethodName))),
	))
}

// UserID returns the user id RequireAuth put into ctx, or "" outside RequireAuth.
func UserID(ctx context.Context) string {
	id, _ := ctx.Value(userIDKey).(string)
	return id
}

// traceID returns the trace id of the request's span, or "" outside Trace and for the probes
// Trace leaves out.
func traceID(ctx context.Context) string {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return ""
	}
	return sc.TraceID().String()
}
