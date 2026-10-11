// Command video-service serves svp.video.v1.VideoService over gRPC and consumes the transcode
// results of media.transcodes.v1.
//
// Subcommands (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 7):
//
//	serve        run the service (default when no subcommand is given)
//	migrate      apply the database migrations, then exit
//	healthcheck  ask the running service for its health; exit 0 when SERVING, 1 otherwise
//
// Configuration comes from the environment: LISTEN_ADDR (default 127.0.0.1:9102) and
// DATABASE_URL (required for serve and migrate); serve also needs KAFKA_BROKERS and the S3_*
// variables of docs/adr/0008-async-upload-pipeline-stage2a.md, section 11. UPLOAD_ABANDON_AFTER
// (default 1h) and UPLOAD_SWEEP_INTERVAL (default 5m) set when an upload counts as abandoned and
// how often they are swept (docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 5).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"

	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/grpcserver"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/objstore"
	"github.com/anhnvcoder/short-video-platform/internal/outbox"
	"github.com/anhnvcoder/short-video-platform/services/video-service/internal/server"
	"github.com/anhnvcoder/short-video-platform/services/video-service/migrations"
)

const (
	serviceName        = "video-service"
	defaultListenAddr  = "127.0.0.1:9102"
	healthcheckTimeout = 3 * time.Second
	// consumerRestartDelay is the wait before a transcode consumer that stopped on an error is
	// replaced.
	consumerRestartDelay = 5 * time.Second
	defaultAbandonAfter  = "1h"
	defaultSweepInterval = "5m"
)

func main() {
	logger := logx.New(serviceName)
	// dbmigrate logs through the default logger.
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, logger, os.Args[1:])
	stop()
	if err != nil {
		logger.Error("video-service failed", slog.Any("error", err))
		os.Exit(1)
	}
}

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

func serve(ctx context.Context, logger *slog.Logger) error {
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	brokers, err := envcfg.Required("KAFKA_BROKERS")
	if err != nil {
		return err
	}
	storageCfg, err := storageConfig()
	if err != nil {
		return err
	}
	abandonAfter, err := positiveDuration("UPLOAD_ABANDON_AFTER", defaultAbandonAfter)
	if err != nil {
		return err
	}
	sweepInterval, err := positiveDuration("UPLOAD_SWEEP_INTERVAL", defaultSweepInterval)
	if err != nil {
		return err
	}
	storage, err := objstore.New(storageCfg)
	if err != nil {
		return err
	}
	kafka, err := kafkax.NewClient(brokers, serviceName)
	if err != nil {
		return fmt.Errorf("KAFKA_BROKERS: %w", err)
	}
	defer kafka.Close()

	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return fmt.Errorf("open database pool: %w", err)
	}
	defer pool.Close()
	// pgxpool connects lazily: check the database now so a bad URL fails at startup.
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}

	// The relay stops after the server has drained and the consumer has stopped. It does not
	// flush: rows the last RPCs wrote that it has not sent yet stay in the outbox and go out at
	// the next start.
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

	srv := server.New(pool, storage, logger)
	newConsumer := func() (runner, error) { return kafkax.NewConsumer(srv.TranscodeConsumerConfig(brokers)) }
	// The consumer stops with the server; a consumer that cannot be created stops the server
	// too. Either way the relay above stops after both.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	consumerErr := make(chan error, 1)
	go func() {
		err := runConsumer(ctx, logger, consumerRestartDelay, newConsumer)
		cancel()
		consumerErr <- err
	}()
	// The sweep of abandoned uploads stops with the server, before the pool closes.
	sweepDone := make(chan struct{})
	go func() {
		defer close(sweepDone)
		srv.NewUploadSweeper(abandonAfter, sweepInterval).Run(ctx)
	}()

	register := func(s *grpc.Server) { videov1.RegisterVideoServiceServer(s, srv) }
	err = grpcserver.Run(ctx, envcfg.String("LISTEN_ADDR", defaultListenAddr), logger, register,
		server.CallerInterceptor())
	cancel()
	<-sweepDone
	if cerr := <-consumerErr; cerr != nil {
		err = errors.Join(err, fmt.Errorf("transcode consumer: %w", cerr))
	}
	return err
}

// runner is what runConsumer needs of a kafkax.Consumer.
type runner interface {
	Run(ctx context.Context) error
}

// runConsumer runs consumers made by newConsumer, one after the other, until ctx is canceled.
// A consumer stops on an error when a record cannot be settled, as when Redpanda restarts
// during a commit; the record stays uncommitted, so the next consumer gets it again. Replacing
// the consumer here keeps the gRPC API serving meanwhile. It returns an error only when
// newConsumer fails.
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
		logger.ErrorContext(ctx, "transcode consumer stopped, restarting",
			slog.Duration("delay", delay), slog.Any("error", err))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay):
		}
	}
}

// storageConfig reads the S3_* variables. Errors name the variable, never its value.
func storageConfig() (objstore.Config, error) {
	endpoint, err := envcfg.Required("S3_ENDPOINT")
	if err != nil {
		return objstore.Config{}, err
	}
	if err := checkEndpoint("S3_ENDPOINT", endpoint); err != nil {
		return objstore.Config{}, err
	}
	public := envcfg.String("S3_PUBLIC_ENDPOINT", endpoint)
	if err := checkEndpoint("S3_PUBLIC_ENDPOINT", public); err != nil {
		return objstore.Config{}, err
	}
	accessKey, err := envcfg.Required("S3_ACCESS_KEY_ID")
	if err != nil {
		return objstore.Config{}, err
	}
	secretKey, err := envcfg.Required("S3_SECRET_ACCESS_KEY")
	if err != nil {
		return objstore.Config{}, err
	}
	return objstore.Config{
		Endpoint:        endpoint,
		PublicEndpoint:  public,
		Region:          envcfg.String("S3_REGION", "us-east-1"),
		AccessKeyID:     accessKey,
		SecretAccessKey: secretKey,
		UploadsBucket:   envcfg.String("S3_UPLOADS_BUCKET", "uploads"),
		MediaBucket:     envcfg.String("S3_MEDIA_BUCKET", "media"),
	}, nil
}

// positiveDuration reads the variable name as a time.Duration such as 90s or 1h, def when it is
// unset or empty. Errors name the variable.
func positiveDuration(name, def string) (time.Duration, error) {
	d, err := time.ParseDuration(envcfg.String(name, def))
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration such as 5m or 1h", name)
	}
	return d, nil
}

// checkEndpoint requires an absolute http or https URL with a host, such as http://minio:9000.
func checkEndpoint(name, value string) error {
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("%s must be an absolute http or https URL", name)
	}
	return nil
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
