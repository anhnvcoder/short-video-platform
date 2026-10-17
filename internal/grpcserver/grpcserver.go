// Package grpcserver runs a service's gRPC server with the interceptors and health service every
// service shares, and checks a running server's health.
package grpcserver

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"runtime/debug"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc/filters"
)

// shutdownTimeout bounds GracefulStop; after it, in-flight RPCs are cut off by Stop.
const shutdownTimeout = 10 * time.Second

// healthCheckMethod is the RPC Healthcheck and the compose health checks call.
const healthCheckMethod = "/grpc.health.v1.Health/Check"

// Run listens on addr and serves gRPC until ctx is done, then stops gracefully. It returns an
// error when it cannot listen or serving fails, and nil after a shutdown caused by ctx.
//
// register adds the service's handlers. Every RPC but the health check gets a server span and
// the rpc.server.call.duration metric from the otelgrpc stats handler, which continues the trace
// of the metadata traceparent (a new root trace when it is missing or malformed), using the
// global OTel providers and propagator. Every unary RPC then passes, in order, through: the RPC
// log line, panic recovery, then interceptors. The standard health service reports SERVING until
// shutdown starts.
func Run(ctx context.Context, addr string, logger *slog.Logger, register func(*grpc.Server), interceptors ...grpc.UnaryServerInterceptor) error {
	var lc net.ListenConfig
	lis, err := lc.Listen(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", addr, err)
	}
	return serve(ctx, lis, logger, register, interceptors...)
}

func serve(ctx context.Context, lis net.Listener, logger *slog.Logger, register func(*grpc.Server), interceptors ...grpc.UnaryServerInterceptor) error {
	chain := append([]grpc.UnaryServerInterceptor{logInterceptor(logger), recoverInterceptor(logger)}, interceptors...)
	srv := grpc.NewServer(
		// Docker probes the health check every 10 s: no span or metric for it.
		grpc.StatsHandler(otelgrpc.NewServerHandler(otelgrpc.WithFilter(filters.Not(filters.FullMethodName(healthCheckMethod))))),
		grpc.ChainUnaryInterceptor(chain...),
	)

	hs := health.NewServer()
	healthpb.RegisterHealthServer(srv, hs)
	register(srv)

	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(lis) }()
	logger.InfoContext(ctx, "grpc server listening", slog.String("addr", lis.Addr().String()))

	select {
	case err := <-errCh:
		return fmt.Errorf("serve grpc: %w", err)
	case <-ctx.Done():
	}

	// Report NOT_SERVING first so health checks stop routing traffic here while RPCs drain.
	hs.Shutdown()
	logger.Info("grpc server stopping")
	stopped := make(chan struct{})
	go func() {
		srv.GracefulStop()
		close(stopped)
	}()
	timer := time.NewTimer(shutdownTimeout)
	defer timer.Stop()
	select {
	case <-stopped:
	case <-timer.C:
		logger.Warn("graceful stop timed out, closing remaining connections", slog.Duration("timeout", shutdownTimeout))
		srv.Stop()
		<-stopped
	}
	if err := <-errCh; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
		return fmt.Errorf("serve grpc: %w", err)
	}
	logger.Info("grpc server stopped")
	return nil
}

// logInterceptor writes one line per RPC: method, status code and duration. Request and
// response bodies are never logged, since they can hold passwords and tokens. The line is at
// ERROR for the codes that mean a fault of the server (UNKNOWN, INTERNAL, DATA_LOSS), so the error
// tracker gets it, and at INFO otherwise.
func logInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		code := status.Code(err)
		level := slog.LevelInfo
		switch code {
		case codes.Unknown, codes.Internal, codes.DataLoss:
			level = slog.LevelError
		}
		logger.LogAttrs(ctx, level, "rpc",
			slog.String("method", info.FullMethod),
			slog.String("code", code.String()),
			slog.Float64("duration_ms", float64(time.Since(start).Microseconds())/1000),
		)
		return resp, err
	}
}

// recoverInterceptor turns a panic in the handler or a later interceptor into INTERNAL with a
// generic message; the panic value and stack go to the log only.
func recoverInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
		defer func() {
			if r := recover(); r != nil {
				logger.LogAttrs(ctx, slog.LevelError, "panic in grpc handler",
					slog.String("method", info.FullMethod),
					slog.Any("panic", r),
					slog.String("stack", string(debug.Stack())),
				)
				resp, err = nil, status.Error(codes.Internal, "internal error")
			}
		}()
		return handler(ctx, req)
	}
}

// Healthcheck asks the server at addr for its overall health over an insecure connection and
// returns nil only when it is SERVING. Bound the call with a deadline on ctx.
func Healthcheck(ctx context.Context, addr string) error {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("create grpc client for %s: %w", addr, err)
	}
	defer func() { _ = conn.Close() }()

	resp, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{})
	if err != nil {
		return fmt.Errorf("health check %s: %w", addr, err)
	}
	if s := resp.GetStatus(); s != healthpb.HealthCheckResponse_SERVING {
		return fmt.Errorf("health check %s: status %s", addr, s)
	}
	return nil
}
