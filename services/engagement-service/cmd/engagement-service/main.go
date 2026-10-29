// Command engagement-service serves svp.engagement.v1.EngagementService over gRPC: likes, view
// events and the counters of each video.
//
// Subcommands, in the service binary because its distroless image has no shell, curl or migration
// tool:
//
//	serve        run the service (default when no subcommand is given)
//	migrate      apply the database migrations, then exit
//	healthcheck  ask the running service for its health; exit 0 when SERVING, 1 otherwise
//
// serve also runs the consumer that adds view.recorded events to the view counters in batches.
//
// Configuration comes from the environment: LISTEN_ADDR (default 127.0.0.1:9103) and
// DATABASE_URL (required for serve and migrate); serve also needs KAFKA_BROKERS.
// DATABASE_MAX_CONNS (default 10, at least 2) is the most Postgres connections serve opens, those
// still being dialed included, split between two pools on DATABASE_URL: floor(n/2) for the read
// pool, which serves GetStats only, and the rest for the write pool, which serves Like, Unlike and
// the views consumer. A GetStats canceled by its caller can leave a connection dialing; in a pool
// of its own that never takes a connection a like needs. serve exports
// telemetry when OTEL_EXPORTER_OTLP_ENDPOINT is set, profiles when PYROSCOPE_SERVER_ADDRESS is,
// and reports errors when SENTRY_DSN is.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
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
	// defaultMaxConns is DATABASE_MAX_CONNS when unset: a fixed total, where pgx's own default,
	// max(4, NumCPU) per pool, would change with the node the pod runs on.
	defaultMaxConns = 10
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
// telemetry providers were still running, so that it reaches both.
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
	readConns, writeConns, err := poolSizes()
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
	var readPool, writePool *pgxpool.Pool
	// Runs once the server and the consumer have stopped: a failure is logged first, while the
	// error tracker and the providers still run, then telemetry is flushed while the pools still
	// exist, then the error reports, and the pools close last.
	defer func() {
		if err != nil {
			logger.Error("engagement-service failed", slog.Any("error", err))
			err = loggedError{err}
		}
		if err := shutdownTelemetry(context.WithoutCancel(ctx)); err != nil {
			logger.Warn("telemetry shutdown failed", slog.Any("error", err))
		}
		flushErrors()
		if readPool != nil {
			readPool.Close()
		}
		if writePool != nil {
			writePool.Close()
		}
	}()
	// One after the other: once the first has connected, the second's startup check connects at
	// once.
	writePool, err = pgpool.New(ctx, databaseURL, pgpool.WithMaxConns(writeConns), pgpool.WithName("write"))
	if err != nil {
		return err
	}
	readPool, err = pgpool.New(ctx, databaseURL, pgpool.WithMaxConns(readConns), pgpool.WithName("read"))
	if err != nil {
		return err
	}

	srv := server.New(readPool, writePool, kafka, logger)
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

// poolSizes reads DATABASE_MAX_CONNS, n, and returns the sizes of the read pool, floor(n/2), and
// of the write pool, the rest. Unset or empty is defaultMaxConns; anything but an integer of at
// least 2, which gives each pool a connection, is an error naming the variable.
func poolSizes() (read, write int32, err error) {
	n := int64(defaultMaxConns)
	if v := envcfg.String("DATABASE_MAX_CONNS", ""); v != "" {
		n, err = strconv.ParseInt(v, 10, 32)
		if err != nil || n < 2 {
			return 0, 0, errors.New("DATABASE_MAX_CONNS: want an integer of at least 2")
		}
	}
	total := int32(n) //nolint:gosec // n fits in int32: ParseInt was given bitSize 32
	return total / 2, total - total/2, nil
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
