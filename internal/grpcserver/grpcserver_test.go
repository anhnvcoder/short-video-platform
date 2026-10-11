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
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
)

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

func start(t *testing.T, interceptors ...grpc.UnaryServerInterceptor) *harness {
	t.Helper()
	var lc net.ListenConfig
	lis, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	logs := &lockedBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))
	svc := &testService{release: make(chan struct{}), started: make(chan struct{})}

	conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
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
	h := start(t)
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
	rpcs := h.logs.records(t, "rpc")
	if len(rpcs) == 0 || rpcs[0]["code"] != "Internal" {
		t.Errorf("rpc log for the panicking call = %v, want code Internal", rpcs)
	}
}

func TestTraceIDInLog(t *testing.T) {
	tests := []struct {
		name        string
		traceparent string
		wantTraceID string
	}{
		{name: "valid", traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", wantTraceID: "4bf92f3577b34da6a3ce929d0e0e4736"},
		{name: "malformed", traceparent: "00-zzzz-00f067aa0ba902b7-01"},
		{name: "missing"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := start(t)
			ctx := timeout(t)
			if tt.traceparent != "" {
				ctx = metadata.AppendToOutgoingContext(ctx, "traceparent", tt.traceparent)
			}
			if err := h.invoke(ctx, "Echo"); err != nil {
				t.Fatalf("Echo = %v, want nil", err)
			}
			recs := h.logs.records(t, "rpc")
			if len(recs) != 1 {
				t.Fatalf("got %d rpc log lines, want 1", len(recs))
			}
			rec := recs[0]
			got, has := rec["trace_id"]
			if tt.wantTraceID == "" && has {
				t.Errorf("trace_id = %v, want none", got)
			}
			if tt.wantTraceID != "" && got != tt.wantTraceID {
				t.Errorf("trace_id = %v, want %s", got, tt.wantTraceID)
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
	var sawTraceID bool
	probe := func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		var buf bytes.Buffer
		slog.New(logx.NewHandler(slog.NewJSONHandler(&buf, nil))).InfoContext(ctx, "probe")
		sawTraceID = strings.Contains(buf.String(), `"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"`)
		return nil, status.Error(codes.PermissionDenied, "denied")
	}
	h := start(t, probe)
	ctx := metadata.AppendToOutgoingContext(timeout(t), "traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")

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

func TestTraceparentInContext(t *testing.T) {
	const valid = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	tests := []struct {
		name        string
		traceparent string
		want        string
	}{
		{name: "valid", traceparent: valid, want: valid},
		{name: "malformed", traceparent: "00-zzzz-00f067aa0ba902b7-01"},
		{name: "missing"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var got string
			var has bool
			probe := func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
				got, has = traceparent.FromContext(ctx)
				return handler(ctx, req)
			}
			h := start(t, probe)
			ctx := timeout(t)
			if tt.traceparent != "" {
				ctx = metadata.AppendToOutgoingContext(ctx, "traceparent", tt.traceparent)
			}
			if err := h.invoke(ctx, "Echo"); err != nil {
				t.Fatalf("Echo = %v, want nil", err)
			}
			if has != (tt.want != "") || got != tt.want {
				t.Errorf("traceparent.FromContext = (%q, %v), want %q", got, has, tt.want)
			}
		})
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
