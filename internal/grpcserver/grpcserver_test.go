package grpcserver

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"

	"go.opentelemetry.io/otel"
	otelcodes "go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	"go.opentelemetry.io/otel/trace/noop"

	"github.com/anhnvcoder/svp-backend/internal/logx"
)

const (
	validTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	validTraceID     = "4bf92f3577b34da6a3ce929d0e0e4736"
	validSpanID      = "00f067aa0ba902b7"
)

// recordSpans installs a global tracer provider that records every ended span, and the W3C
// TraceContext propagator that telemetry.Setup installs; both are reset when t ends. Call it
// before start: the stats handler takes the global providers when the server is built.
func recordSpans(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		otel.SetTracerProvider(noop.NewTracerProvider())
		otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator())
		_ = tp.Shutdown(context.Background())
	})
	return sr
}

// serverSpans returns the ended server spans of the test service.
func serverSpans(sr *tracetest.SpanRecorder) []sdktrace.ReadOnlySpan {
	var out []sdktrace.ReadOnlySpan
	for _, s := range sr.Ended() {
		if s.SpanKind() == trace.SpanKindServer {
			out = append(out, s)
		}
	}
	return out
}

// lockedBuffer collects log output written from server goroutines.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// records returns the decoded JSON log lines whose msg is msg.
func (b *lockedBuffer) records(t *testing.T, msg string) []map[string]any {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for line := range strings.SplitSeq(strings.TrimSpace(b.buf.String()), "\n") {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("log line %q is not JSON: %v", line, err)
		}
		if rec["msg"] == msg {
			out = append(out, rec)
		}
	}
	return out
}

// testService is a hand-written service with three unary methods taking and returning Empty:
// Echo returns, Panic panics, Block waits until release is closed.
type testService struct {
	release chan struct{}
	started chan struct{}
}

func unary(fn func(ctx context.Context) error) func(any, context.Context, func(any) error, grpc.UnaryServerInterceptor) (any, error) {
	return func(_ any, ctx context.Context, dec func(any) error, interceptor grpc.UnaryServerInterceptor) (any, error) {
		in := new(emptypb.Empty)
		if err := dec(in); err != nil {
			return nil, err
		}
		handler := func(ctx context.Context, _ any) (any, error) {
			if err := fn(ctx); err != nil {
				return nil, err
			}
			return &emptypb.Empty{}, nil
		}
		return interceptor(ctx, in, &grpc.UnaryServerInfo{FullMethod: "/svp.test.Test/X"}, handler)
	}
}

func (s *testService) register(srv *grpc.Server) {
	srv.RegisterService(&grpc.ServiceDesc{
		ServiceName: "svp.test.Test",
		HandlerType: (*any)(nil),
		Methods: []grpc.MethodDesc{
			{MethodName: "Echo", Handler: unary(func(context.Context) error { return nil })},
			{MethodName: "Panic", Handler: unary(func(context.Context) error { panic("secret detail from handler") })},
			{MethodName: "Block", Handler: unary(func(context.Context) error {
				close(s.started)
				<-s.release
				return nil
			})},
		},
	}, struct{}{})
}

type harness struct {
	addr   string
	logs   *lockedBuffer
	conn   *grpc.ClientConn
	cancel context.CancelFunc
	// stopped is closed when serve returns; serveErr is its result.
	stopped  chan struct{}
	serveErr error
	svc      *testService
}

// start serves on a TCP port of 127.0.0.1, which Healthcheck needs.
func start(t *testing.T, interceptors ...grpc.UnaryServerInterceptor) *harness {
	t.Helper()
	var lc net.ListenConfig
	lis, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	return startOn(t, lis, conn, interceptors...)
}

// startBufconn serves on an in-memory listener.
func startBufconn(t *testing.T, interceptors ...grpc.UnaryServerInterceptor) *harness {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	return startOn(t, lis, conn, interceptors...)
}

func startOn(t *testing.T, lis net.Listener, conn *grpc.ClientConn, interceptors ...grpc.UnaryServerInterceptor) *harness {
	t.Helper()
	logs := &lockedBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))
	svc := &testService{release: make(chan struct{}), started: make(chan struct{})}

	ctx, cancel := context.WithCancel(context.Background())
	h := &harness{addr: lis.Addr().String(), logs: logs, conn: conn, cancel: cancel, stopped: make(chan struct{}), svc: svc}
	go func() {
		h.serveErr = serve(ctx, lis, logger, svc.register, interceptors...)
		close(h.stopped)
	}()
	t.Cleanup(func() {
		_ = conn.Close()
		cancel()
		select {
		case <-h.stopped:
		case <-time.After(15 * time.Second):
			t.Error("server did not stop")
		}
	})
	return h
}

// stop stops the server and waits for serve to return. grpc-go ends the server span after it has
// sent the reply, so the client can see the reply first: read spans only after stop, once every
// handler goroutine has returned.
func (h *harness) stop(t *testing.T) {
	t.Helper()
	h.cancel()
	select {
	case <-h.stopped:
	case <-time.After(15 * time.Second):
		t.Fatal("server did not stop")
	}
}

func (h *harness) invoke(ctx context.Context, method string) error {
	return h.conn.Invoke(ctx, "/svp.test.Test/"+method, &emptypb.Empty{}, &emptypb.Empty{})
}

func timeout(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestHealthServing(t *testing.T) {
	h := start(t)
	if err := Healthcheck(timeout(t), h.addr); err != nil {
		t.Fatalf("Healthcheck() = %v, want nil", err)
	}
}

func TestHealthCheckHasNoSpan(t *testing.T) {
	sr := recordSpans(t)
	h := start(t)
	for range 3 {
		if err := Healthcheck(timeout(t), h.addr); err != nil {
			t.Fatalf("Healthcheck() = %v, want nil", err)
		}
	}
	if err := h.invoke(timeout(t), "Echo"); err != nil {
		t.Fatalf("Echo = %v, want nil", err)
	}
	h.stop(t)
	spans := serverSpans(sr)
	if len(spans) != 1 || spans[0].Name() != "svp.test.Test/Echo" {
		var names []string
		for _, s := range spans {
			names = append(names, s.Name())
		}
		t.Errorf("server spans = %v, want only svp.test.Test/Echo", names)
	}
}

func TestShutdownDrainsInFlightRPC(t *testing.T) {
	h := start(t)
	ctx := timeout(t)

	rpcErr := make(chan error, 1)
	go func() { rpcErr <- h.invoke(ctx, "Block") }()
	<-h.svc.started

	h.cancel()
	// The server must wait for the in-flight RPC instead of returning.
	select {
	case <-h.stopped:
		t.Fatalf("server returned %v before the in-flight RPC finished", h.serveErr)
	case <-time.After(200 * time.Millisecond):
	}

	close(h.svc.release)
	if err := <-rpcErr; err != nil {
		t.Errorf("in-flight RPC failed during graceful stop: %v", err)
	}
	select {
	case <-h.stopped:
		if h.serveErr != nil {
			t.Errorf("serve() = %v, want nil after ctx cancel", h.serveErr)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop after the in-flight RPC finished")
	}
	if err := Healthcheck(timeout(t), h.addr); err == nil {
		t.Error("Healthcheck() = nil after shutdown, want an error")
	}
}

func TestPanicReturnsInternal(t *testing.T) {
	sr := recordSpans(t)
	h := startBufconn(t)
	ctx := timeout(t)

	err := h.invoke(ctx, "Panic")
	st, _ := status.FromError(err)
	if st.Code() != codes.Internal {
		t.Fatalf("code = %v, want Internal", st.Code())
	}
	if st.Message() != "internal error" {
		t.Errorf("message = %q, want the generic %q", st.Message(), "internal error")
	}

	// The server survives and keeps serving.
	if err := h.invoke(ctx, "Echo"); err != nil {
		t.Errorf("Echo after panic = %v, want nil", err)
	}

	recs := h.logs.records(t, "panic in grpc handler")
	if len(recs) != 1 {
		t.Fatalf("got %d panic log lines, want 1", len(recs))
	}
	if stack, _ := recs[0]["stack"].(string); !strings.Contains(stack, "goroutine") {
		t.Errorf("panic log has no stack: %v", recs[0])
	}
	if recs[0]["level"] != "ERROR" {
		t.Errorf("panic log level = %v, want ERROR", recs[0]["level"])
	}
	rpcs := h.logs.records(t, "rpc")
	if len(rpcs) == 0 || rpcs[0]["code"] != "Internal" || rpcs[0]["level"] != "ERROR" {
		t.Errorf("rpc log for the panicking call = %v, want code Internal at level ERROR", rpcs)
	}

	h.stop(t)
	spans := map[string]sdktrace.ReadOnlySpan{}
	for _, s := range serverSpans(sr) {
		spans[s.Name()] = s
	}
	panicSpan, echoSpan := spans["svp.test.Test/Panic"], spans["svp.test.Test/Echo"]
	if len(spans) != 2 || panicSpan == nil || echoSpan == nil {
		t.Fatalf("server spans = %v, want svp.test.Test/Panic and svp.test.Test/Echo", spans)
	}
	if got := panicSpan.Status(); got.Code != otelcodes.Error || got.Description != "internal error" {
		t.Errorf("span status of the panicking call = %+v, want Error with the generic message", got)
	}
	if got := echoSpan.Status().Code; got != otelcodes.Unset {
		t.Errorf("span status of Echo = %v, want Unset", got)
	}
}

// failWith returns a service interceptor that fails every RPC with code (none for OK).
func failWith(code codes.Code) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if code == codes.OK {
			return handler(ctx, req)
		}
		return nil, status.Error(code, "failed")
	}
}

func TestRPCLogLevelByCode(t *testing.T) {
	tests := []struct {
		code codes.Code
		want string
	}{
		{codes.OK, "INFO"},
		{codes.InvalidArgument, "INFO"},
		{codes.NotFound, "INFO"},
		{codes.Unauthenticated, "INFO"},
		{codes.Unavailable, "INFO"},
		{codes.DeadlineExceeded, "INFO"},
		{codes.Unknown, "ERROR"},
		{codes.Internal, "ERROR"},
		{codes.DataLoss, "ERROR"},
	}
	for _, tt := range tests {
		t.Run(tt.code.String(), func(t *testing.T) {
			h := startBufconn(t, failWith(tt.code))
			if got := status.Code(h.invoke(timeout(t), "Echo")); got != tt.code {
				t.Fatalf("code = %v, want %v", got, tt.code)
			}
			recs := h.logs.records(t, "rpc")
			if len(recs) != 1 || recs[0]["code"] != tt.code.String() || recs[0]["level"] != tt.want {
				t.Errorf("rpc log = %v, want one line with code %v at level %s", recs, tt.code, tt.want)
			}
		})
	}
}

func TestServerSpanContinuesMetadataTrace(t *testing.T) {
	tests := []struct {
		name        string
		traceparent string
		wantParent  bool
	}{
		{name: "valid", traceparent: validTraceparent, wantParent: true},
		{name: "malformed", traceparent: "00-zzzz-00f067aa0ba902b7-01"},
		{name: "all-zero trace id", traceparent: "00-00000000000000000000000000000000-00f067aa0ba902b7-01"},
		{name: "missing"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sr := recordSpans(t)
			var handlerSC trace.SpanContext
			probe := func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
				handlerSC = trace.SpanContextFromContext(ctx)
				return handler(ctx, req)
			}
			h := startBufconn(t, probe)
			ctx := timeout(t)
			if tt.traceparent != "" {
				ctx = metadata.AppendToOutgoingContext(ctx, "traceparent", tt.traceparent)
			}
			if err := h.invoke(ctx, "Echo"); err != nil {
				t.Fatalf("Echo = %v, want nil", err)
			}

			h.stop(t)
			spans := serverSpans(sr)
			if len(spans) != 1 {
				t.Fatalf("got %d server spans, want 1", len(spans))
			}
			span := spans[0]
			sc, parent := span.SpanContext(), span.Parent()
			if !sc.IsValid() || !handlerSC.Equal(sc) {
				t.Errorf("handler span context = %v, want the server span %v", handlerSC, sc)
			}
			if tt.wantParent {
				if sc.TraceID().String() != validTraceID || parent.SpanID().String() != validSpanID || !parent.IsRemote() {
					t.Errorf("span trace %s parent %s (remote %v), want trace %s parent %s (remote)",
						sc.TraceID(), parent.SpanID(), parent.IsRemote(), validTraceID, validSpanID)
				}
			} else if parent.IsValid() {
				t.Errorf("span parent = %v, want a new root trace", parent)
			}

			recs := h.logs.records(t, "rpc")
			if len(recs) != 1 {
				t.Fatalf("got %d rpc log lines, want 1", len(recs))
			}
			rec := recs[0]
			if rec["trace_id"] != sc.TraceID().String() || rec["span_id"] != sc.SpanID().String() {
				t.Errorf("rpc log trace_id, span_id = %v, %v, want the server span %s, %s",
					rec["trace_id"], rec["span_id"], sc.TraceID(), sc.SpanID())
			}
			if rec["code"] != "OK" || rec["method"] != "/svp.test.Test/X" {
				t.Errorf("rpc log = %v, want code OK and the method", rec)
			}
			if _, ok := rec["duration_ms"]; !ok {
				t.Errorf("rpc log has no duration_ms: %v", rec)
			}
		})
	}
}

func TestServiceInterceptorsRunInsideBuiltins(t *testing.T) {
	recordSpans(t)
	var sawTraceID bool
	probe := func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		var buf bytes.Buffer
		slog.New(logx.NewHandler(slog.NewJSONHandler(&buf, nil))).InfoContext(ctx, "probe")
		sawTraceID = strings.Contains(buf.String(), `"trace_id":"`+validTraceID+`"`)
		return nil, status.Error(codes.PermissionDenied, "denied")
	}
	h := start(t, probe)
	ctx := metadata.AppendToOutgoingContext(timeout(t), "traceparent", validTraceparent)

	if code := status.Code(h.invoke(ctx, "Echo")); code != codes.PermissionDenied {
		t.Fatalf("code = %v, want PermissionDenied from the service interceptor", code)
	}
	if !sawTraceID {
		t.Error("service interceptor did not see trace_id in the log context")
	}
	if recs := h.logs.records(t, "rpc"); len(recs) != 1 || recs[0]["code"] != "PermissionDenied" {
		t.Errorf("rpc log = %v, want one line with code PermissionDenied", recs)
	}
}

func TestRunPortInUse(t *testing.T) {
	var lc net.ListenConfig
	lis, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = lis.Close() }()

	logger := slog.New(slog.DiscardHandler)
	err = Run(t.Context(), lis.Addr().String(), logger, func(*grpc.Server) {})
	if err == nil {
		t.Fatal("Run() = nil on a busy port, want an error")
	}
}

func TestRunReturnsNilOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- Run(ctx, "127.0.0.1:0", slog.New(slog.DiscardHandler), func(*grpc.Server) {}) }()

	time.Sleep(100 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Run() = %v, want nil", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run() did not return after ctx cancel")
	}
}
