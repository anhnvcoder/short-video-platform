// Command engagement-service serves svp.engagement.v1.EngagementService over gRPC: likes, view
// events and the counters of each video (docs/adr/0009-engagement-feed-stage2b.md).
//
// Subcommands (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 7):
//
//	serve        run the service (default when no subcommand is given)
//	migrate      apply the database migrations, then exit
//	healthcheck  ask the running service for its health; exit 0 when SERVING, 1 otherwise
//
// serve also runs the consumer that adds view.recorded events to the view counters in batches
// (docs/adr/0009-engagement-feed-stage2b.md, section 4).
//
// Configuration comes from the environment: LISTEN_ADDR (default 127.0.0.1:9103) and
// DATABASE_URL (required for serve and migrate); serve also needs KAFKA_BROKERS
// (docs/adr/0009-engagement-feed-stage2b.md, section 12). serve exports telemetry when
// OTEL_EXPORTER_OTLP_ENDPOINT is set, profiles when PYROSCOPE_SERVER_ADDRESS is, and reports
// errors when SENTRY_DSN is (docs/adr/0011-observability-stage3.md).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/grpcserver"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/pgpool"
	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
	"github.com/anhnvcoder/short-video-platform/internal/telemetry"
	"github.com/anhnvcoder/short-video-platform/services/engagement-service/internal/server"
	"github.com/anhnvcoder/short-video-platform/services/engagement-service/migrations"
)

const (
	serviceName        = "engagement-service"
	defaultListenAddr  = "127.0.0.1:9103"
	healthcheckTimeout = 3 * time.Second
	// consumerRestartDelay is the wait before a views consumer that stopped on an error is
	// replaced.
	consumerRestartDelay = 5 * time.Second
)

func main() {
	logger := logx.New(serviceName)
	// dbmigrate logs through the default logger.
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, logger, os.Args[1:])
	stop()
	if err != nil {
		if _, logged := errors.AsType[loggedError](err); !logged {
			logger.Error("engagement-service failed", slog.Any("error", err))
		}
		os.Exit(1)
	}
}

// loggedError is a serve failure that serve has already logged, while the error tracker and the
// telemetry providers were still running, so that it reaches both (ADR-0011, sections 4 and 7).
type loggedError struct{ error }

func (e loggedError) Unwrap() error { return e.error }

func run(ctx context.Context, logger *slog.Logger, args []string) error {
	cmd := "serve"
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "serve":
		return serve(ctx, logger)
	case "migrate":
		return migrate(ctx)
	case "healthcheck":
		return healthcheck(ctx)
	}
	return fmt.Errorf("unknown command %q, want serve, migrate or healthcheck", cmd)
}

func serve(ctx context.Context, logger *slog.Logger) (err error) {
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
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
	// Runs once the server and the consumer have stopped: a failure is logged first, while the
	// error tracker and the providers still run, then telemetry is flushed while the pool still
	// exists, then the error reports, and the pool closes last.
	defer func() {
		if err != nil {
			logger.Error("engagement-service failed", slog.Any("error", err))
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
		return err
	}

	srv := server.New(pool, kafka, logger)
	newConsumer := func() (runner, error) { return kafkax.NewBatchConsumer(srv.ViewsConsumerConfig(brokers)) }
	// The consumer stops with the server; a consumer that cannot be created stops the server too.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	consumerErr := make(chan error, 1)
	go func() {
		err := runConsumer(ctx, logger, consumerRestartDelay, newConsumer)
		cancel()
		consumerErr <- err
	}()

	register := func(s *grpc.Server) { engagementv1.RegisterEngagementServiceServer(s, srv) }
	err = grpcserver.Run(ctx, envcfg.String("LISTEN_ADDR", defaultListenAddr), logger, register,
		server.CallerInterceptor())
	cancel()
	if cerr := <-consumerErr; cerr != nil {
		err = errors.Join(err, fmt.Errorf("views consumer: %w", cerr))
	}
	return err
}

// runner is what runConsumer needs of a kafkax.BatchConsumer.
type runner interface {
	Run(ctx context.Context) error
}

// runConsumer runs consumers made by newConsumer, one after the other, until ctx is canceled.
// A consumer stops on an error when a batch cannot be settled, as when Redpanda restarts during
// a commit; the batch stays uncommitted, so the next consumer gets it again and the offsets in
// consumer_offsets skip what was already counted. Replacing the consumer here keeps the gRPC API
// serving meanwhile. It returns an error only when newConsumer fails.
func runConsumer(ctx context.Context, logger *slog.Logger, delay time.Duration, newConsumer func() (runner, error)) error {
	for {
		c, err := newConsumer()
		if err != nil {
			return err
		}
		err = c.Run(ctx)
		if ctx.Err() != nil {
			return nil
		}
		logger.ErrorContext(ctx, "views consumer stopped, restarting",
			slog.Duration("delay", delay), slog.Any("error", err))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay):
		}
	}
}

func migrate(ctx context.Context) error {
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	return dbmigrate.Up(ctx, databaseURL, migrations.FS)
}

func healthcheck(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, healthcheckTimeout)
	defer cancel()
	return grpcserver.Healthcheck(ctx, envcfg.String("LISTEN_ADDR", defaultListenAddr))
}
