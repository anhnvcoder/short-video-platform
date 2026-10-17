// Command user-service runs the user service (serve, the default), applies its database
// migrations (migrate) or checks a running instance's health (healthcheck). Configuration comes
// from environment variables (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 4);
// serve also needs KAFKA_BROKERS for the outbox relay (docs/adr/0009-engagement-feed-stage2b.md,
// section 1), exports telemetry when OTEL_EXPORTER_OTLP_ENDPOINT is set, profiles when
// PYROSCOPE_SERVER_ADDRESS is, and reports errors when SENTRY_DSN is
// (docs/adr/0011-observability-stage3.md).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/grpcserver"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/outbox"
	"github.com/anhnvcoder/short-video-platform/internal/pgpool"
	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
	"github.com/anhnvcoder/short-video-platform/internal/telemetry"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/password"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/server"
	"github.com/anhnvcoder/short-video-platform/services/user-service/migrations"
)

const (
	serviceName       = "user-service"
	defaultListenAddr = "127.0.0.1:9101"
	// healthcheckTimeout bounds the healthcheck subcommand, which a container runtime calls often.
	healthcheckTimeout = 3 * time.Second
)

func main() {
	logger := logx.New(serviceName)
	// dbmigrate logs through the default logger.
	slog.SetDefault(logger)

	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var err error
	switch cmd {
	case "serve":
		err = serve(ctx, logger)
	case "migrate":
		err = migrate(ctx)
	case "healthcheck":
		err = healthcheck(ctx)
	default:
		err = fmt.Errorf("unknown subcommand %q, want serve, migrate or healthcheck", cmd)
	}
	if err != nil {
		if _, logged := errors.AsType[loggedError](err); !logged {
			logFailure(logger, err)
		}
		stop()
		os.Exit(1)
	}
}

// logFailure logs that a subcommand failed with err, under a constant message so the error
// tracker groups it (ADR-0011, section 7).
func logFailure(logger *slog.Logger, err error) {
	logger.Error("user-service failed", slog.Any("error", err))
}

// loggedError is a serve failure that serve has already logged, while the error tracker and the
// telemetry providers were still running, so that it reaches both (ADR-0011, sections 4 and 7).
type loggedError struct{ error }

func (e loggedError) Unwrap() error { return e.error }

func serve(ctx context.Context, logger *slog.Logger) (err error) {
	addr := envcfg.String("LISTEN_ADDR", defaultListenAddr)
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	kid, err := envcfg.Required("JWT_SIGNING_KID")
	if err != nil {
		return err
	}
	seed, err := envcfg.Required("JWT_SIGNING_KEY")
	if err != nil {
		return err
	}
	key, err := authtoken.ParseSigningKey(kid, seed)
	if err != nil {
		return fmt.Errorf("JWT_SIGNING_KID or JWT_SIGNING_KEY: %w", err)
	}
	brokers, err := envcfg.Required("KAFKA_BROKERS")
	if err != nil {
		return err
	}
	kafka, err := kafkax.NewClient(brokers, serviceName)
	if err != nil {
		return fmt.Errorf("KAFKA_BROKERS: %w", err)
	}
	defer kafka.Close()

	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName)
	if err != nil {
		return fmt.Errorf("set up telemetry: %w", err)
	}
	flushErrors, err := sentryx.Init(serviceName)
	if err != nil {
		return errors.Join(err, shutdownTelemetry(context.WithoutCancel(ctx)))
	}
	var pool *pgxpool.Pool
	// Runs once the server and the relay have stopped: a failure is logged first, while the error
	// tracker and the providers still run, then telemetry is flushed while the pool still exists,
	// then the error reports, and the pool closes last.
	defer func() {
		if err != nil {
			logFailure(logger, err)
			err = loggedError{err}
		}
		if err := shutdownTelemetry(context.WithoutCancel(ctx)); err != nil {
			logger.Warn("telemetry shutdown failed", slog.Any("error", err))
		}
		flushErrors()
		if pool != nil {
			pool.Close()
		}
	}()
	pool, err = pgpool.New(ctx, databaseURL)
	if err != nil {
		return fmt.Errorf("DATABASE_URL: %w", err)
	}

	// The relay stops after the server has drained. It does not flush: rows the last RPCs wrote
	// that it has not sent yet stay in the outbox and go out at the next start.
	relayCtx, stopRelay := context.WithCancel(context.WithoutCancel(ctx))
	relayDone := make(chan struct{})
	go func() {
		defer close(relayDone)
		outbox.NewRelay(pool, kafka, logger).Run(relayCtx)
	}()
	defer func() {
		stopRelay()
		<-relayDone
	}()

	srv := server.New(pool, password.NewHasher(), authtoken.NewIssuer(kid, key), logger)
	return grpcserver.Run(ctx, addr, logger,
		func(s *grpc.Server) { userv1.RegisterUserServiceServer(s, srv) },
		callerid.UnaryServerInterceptor(server.PublicMethods...),
	)
}

func migrate(ctx context.Context) error {
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	return dbmigrate.Up(ctx, databaseURL, migrations.FS)
}

// healthcheck asks the server on LISTEN_ADDR's port, over loopback, whether it is SERVING.
func healthcheck(ctx context.Context) error {
	_, port, err := net.SplitHostPort(envcfg.String("LISTEN_ADDR", defaultListenAddr))
	if err != nil {
		return fmt.Errorf("LISTEN_ADDR: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, healthcheckTimeout)
	defer cancel()
	return grpcserver.Healthcheck(ctx, net.JoinHostPort("127.0.0.1", port))
}
