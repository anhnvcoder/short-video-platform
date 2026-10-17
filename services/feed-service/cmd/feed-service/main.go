// Command feed-service serves svp.feed.v1.FeedService over gRPC from its read model, which it
// builds from user.follows.v1 and video.lifecycle.v1 (docs/adr/0009-engagement-feed-stage2b.md,
// sections 6 to 8).
//
// Subcommands, in the service binary because its distroless image has no shell, curl or migration
// tool (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 7):
//
//	serve        run the service (default when no subcommand is given)
//	migrate      apply the database migrations, then exit
//	healthcheck  ask the running service for its health; exit 0 when SERVING, 1 otherwise
//
// serve also runs the consumer of both topics and, every hour, deletes timeline rows older than
// 30 days.
//
// Configuration comes from the environment: LISTEN_ADDR (default 127.0.0.1:9104) and
// DATABASE_URL (required for serve and migrate); serve also needs KAFKA_BROKERS
// (docs/adr/0009-engagement-feed-stage2b.md, section 12) and reads REDIS_URL (default
// redis://127.0.0.1:6379/14) for the explore cache. Redis is not needed to start or to serve: a
// failed or slow cache read falls back to Postgres
// (docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 1). serve exports
// telemetry when OTEL_EXPORTER_OTLP_ENDPOINT is set, profiles when PYROSCOPE_SERVER_ADDRESS is,
// and reports errors when SENTRY_DSN is (docs/adr/0011-observability-stage3.md).
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

	feedv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/feed/v1"
	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/grpcserver"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/pgpool"
	"github.com/anhnvcoder/short-video-platform/internal/redisx"
	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
	"github.com/anhnvcoder/short-video-platform/internal/telemetry"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/internal/projector"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/internal/server"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/migrations"
)

const (
	serviceName       = "feed-service"
	defaultListenAddr = "127.0.0.1:9104"
	defaultRedisURL   = "redis://127.0.0.1:6379/14"
	// cacheKeyPrefix starts every Redis key of the service. A Redis db number is no access
	// boundary; a prefix per service is, once a cloud Redis grants access by key prefix
	// (ADR-0010, section 1).
	cacheKeyPrefix     = "svp:feed:"
	healthcheckTimeout = 3 * time.Second
	// consumerRestartDelay is the wait before a consumer that stopped on an error is replaced.
	consumerRestartDelay = 5 * time.Second
	// pruneInterval is how often timeline rows older than 30 days are deleted (ADR-0009,
	// section 6). Reads filter them out meanwhile.
	pruneInterval = time.Hour
	// pruneTimeout bounds one prune run, every batch included, so a run stuck on a lock or a slow
	// database gives up and leaves the rest to the next run (ADR-0011, section 11).
	pruneTimeout = 2 * time.Minute
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
			logger.Error("feed-service failed", slog.Any("error", err))
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
	// The consumers make their own clients later; this one only checks the broker list now, so
	// a malformed one fails at startup naming the variable. It never connects.
	probe, err := kafkax.NewClient(brokers, serviceName)
	if err != nil {
		return fmt.Errorf("KAFKA_BROKERS: %w", err)
	}
	probe.Close()
	// redisx.New does not connect, so the service starts while Redis is down; only a malformed
	// URL stops it.
	cache, err := redisx.New(envcfg.String("REDIS_URL", defaultRedisURL))
	if err != nil {
		return fmt.Errorf("REDIS_URL: %w", err)
	}
	defer func() { _ = cache.Close() }()

	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName)
	if err != nil {
		return fmt.Errorf("set up telemetry: %w", err)
	}
	flushErrors, err := sentryx.Init(serviceName)
	if err != nil {
		return errors.Join(err, shutdownTelemetry(context.WithoutCancel(ctx)))
	}
	var pool *pgxpool.Pool
	// Runs once the server, the consumer and the pruner have stopped: a failure is logged first,
	// while the error tracker and the providers still run, then telemetry is flushed while the
	// pool still exists, then the error reports, and the pool closes last.
	defer func() {
		if err != nil {
			logger.Error("feed-service failed", slog.Any("error", err))
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

	proj := projector.New(pool, logger)
	newConsumer := func() (runner, error) { return kafkax.NewConsumer(proj.ConsumerConfig(brokers)) }
	// The consumer and the pruner stop with the server; a consumer that cannot be created stops
	// the server too.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	consumerErr := make(chan error, 1)
	go func() {
		err := runConsumer(ctx, logger, consumerRestartDelay, newConsumer)
		cancel()
		consumerErr <- err
	}()
	pruneDone := make(chan struct{})
	pruneLoop := telemetry.NewLoop("timeline-prune")
	go func() {
		defer close(pruneDone)
		runPrune(ctx, logger, pruneInterval, pruneTimeout, pruneLoop, proj.PruneTimeline)
	}()

	srv := server.New(pool, cache, cacheKeyPrefix, logger)
	register := func(s *grpc.Server) { feedv1.RegisterFeedServiceServer(s, srv) }
	err = grpcserver.Run(ctx, envcfg.String("LISTEN_ADDR", defaultListenAddr), logger, register,
		server.CallerInterceptor())
	cancel()
	<-pruneDone
	if cerr := <-consumerErr; cerr != nil {
		err = errors.Join(err, fmt.Errorf("feed consumer: %w", cerr))
	}
	return err
}

// runner is what runConsumer needs of a kafkax.Consumer.
type runner interface {
	Run(ctx context.Context) error
}

// runConsumer runs consumers made by newConsumer, one after the other, until ctx is canceled.
// A consumer stops on an error when a record cannot be settled, as when Redpanda restarts
// during a commit; the record stays uncommitted, so the next consumer gets it again, and every
// handler is idempotent. Replacing the consumer here keeps the gRPC API serving meanwhile. It
// returns an error only when newConsumer fails.
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
		logger.ErrorContext(ctx, "feed consumer stopped, restarting",
			slog.Duration("delay", delay), slog.Any("error", err))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay):
		}
	}
}

// runPrune calls prune once at start and then every interval until ctx is canceled, each run
// within timeout. A failed run is logged and left to the next one: reads filter expired rows out
// whatever prune does. prune reports each batch it deletes to loop through onBatch, so a run that
// keeps working through a backlog past its timeout does not look stalled (ADR-0011, section 5).
func runPrune(ctx context.Context, logger *slog.Logger, interval, timeout time.Duration, loop *telemetry.Loop,
	prune func(ctx context.Context, onBatch func()) (int64, error),
) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		runCtx, cancel := context.WithTimeout(ctx, timeout)
		n, err := prune(runCtx, loop.Succeeded)
		timedOut := runCtx.Err() != nil
		cancel()
		switch {
		case ctx.Err() != nil:
			return
		case err != nil && timedOut:
			// The rows deleted so far stay deleted; the next run goes on from there.
			logger.WarnContext(ctx, "prune timeline timed out", slog.Int64("deleted", n),
				slog.Duration("timeout", timeout), slog.Any("error", err))
		case err != nil:
			logger.ErrorContext(ctx, "prune timeline", slog.Int64("deleted", n), slog.Any("error", err))
		default:
			logger.InfoContext(ctx, "timeline pruned", slog.Int64("deleted", n))
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
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
