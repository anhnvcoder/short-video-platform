// Command media-worker consumes video.uploaded, transcodes the source to HLS and publishes the
// result. It has no database, no listening port and no gRPC.
//
// Subcommands:
//
//	serve  run the worker (default when no subcommand is given)
//
// Configuration comes from the environment: KAFKA_BROKERS and S3_ENDPOINT (required), the
// credential (S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY by default) and S3_PATH_STYLE as
// objstore.Config.ReadAccessEnv reads them, S3_REGION (default us-east-1), S3_UPLOADS_BUCKET
// (default uploads), S3_MEDIA_BUCKET (default media) and WORK_DIR (default /work). The OTEL_*
// variables send traces, metrics and logs to the Collector; the worker has no profiler and no
// error tracker, since its network reaches only Redpanda, the object store and the Collector, and
// ffmpeg runs as a child process the profiler would not see.
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

	"github.com/anhnvcoder/svp-backend/internal/envcfg"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/internal/telemetry"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"
)

const serviceName = "media-worker"

func main() {
	logger := logx.New(serviceName)
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, logger, os.Args[1:])
	stop()
	if err != nil {
		if _, logged := errors.AsType[loggedError](err); !logged {
			logger.Error("media-worker failed", slog.Any("error", err))
		}
		os.Exit(1)
	}
}

// loggedError is an error serve has logged already, while the telemetry providers still took
// records, so main does not log it again.
type loggedError struct{ error }

func (e loggedError) Unwrap() error { return e.error }

func run(ctx context.Context, logger *slog.Logger, args []string) error {
	cmd := "serve"
	if len(args) > 0 {
		cmd = args[0]
	}
	if cmd != "serve" {
		return fmt.Errorf("unknown command %q, want serve", cmd)
	}
	return serve(ctx, logger)
}

type config struct {
	brokers string
	store   objstore.Config
	workDir string
}

func loadConfig() (config, error) {
	cfg := config{
		store: objstore.Config{
			Region:        envcfg.String("S3_REGION", "us-east-1"),
			UploadsBucket: envcfg.String("S3_UPLOADS_BUCKET", "uploads"),
			MediaBucket:   envcfg.String("S3_MEDIA_BUCKET", "media"),
		},
		workDir: envcfg.String("WORK_DIR", "/work"),
	}
	required := []struct {
		name string
		dst  *string
	}{
		{"KAFKA_BROKERS", &cfg.brokers},
		{"S3_ENDPOINT", &cfg.store.Endpoint},
	}
	for _, r := range required {
		v, err := envcfg.Required(r.name)
		if err != nil {
			return config{}, err
		}
		*r.dst = v
	}
	// A malformed endpoint would fail every request at run time, and after the retries every
	// video as RETRIES_EXHAUSTED: stop at startup instead.
	if err := checkEndpoint("S3_ENDPOINT", cfg.store.Endpoint); err != nil {
		return config{}, err
	}
	if err := cfg.store.ReadAccessEnv(); err != nil {
		return config{}, err
	}
	return cfg, nil
}

// checkEndpoint requires an absolute http or https URL with a host, such as http://s3:9000.
func checkEndpoint(name, value string) error {
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("%s must be an absolute http or https URL", name)
	}
	return nil
}

// serve runs the consumer until ctx is canceled (SIGINT, SIGTERM). The job in hand is then
// canceled: ffmpeg is killed, nothing is published or committed, and the record is delivered
// again to whichever worker takes the partition.
func serve(ctx context.Context, logger *slog.Logger) (err error) {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	// Providers first, so the clients below report to them. Export is asynchronous: a Collector
	// that cannot be reached loses telemetry, never a job.
	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName)
	if err != nil {
		return fmt.Errorf("set up telemetry: %w", err)
	}
	// Deferred first, so it runs last: after the consumer has stopped and the producer closed, a
	// failure is logged while the providers still take it, then they export what they recorded.
	defer func() {
		if err != nil {
			logger.Error("media-worker failed", slog.Any("error", err))
			err = loggedError{err}
		}
		if err := shutdownTelemetry(context.WithoutCancel(ctx)); err != nil {
			logger.Warn("telemetry shutdown failed", slog.Any("error", err))
		}
	}()
	store, err := objstore.New(cfg.store)
	if err != nil {
		return err
	}
	producer, err := kafkax.NewClient(cfg.brokers, serviceName)
	if err != nil {
		return fmt.Errorf("KAFKA_BROKERS: %w", err)
	}
	defer producer.Close()

	w := worker.New(store, producer, cfg.workDir, logger)
	if err := w.CleanWorkDir(); err != nil {
		return err
	}
	consumer, err := kafkax.NewConsumer(w.ConsumerConfig(cfg.brokers))
	if err != nil {
		return err
	}
	logger.Info("media-worker started", slog.String("topic", worker.InputTopic), slog.String("group", worker.Group))
	if err := consumer.Run(ctx); err != nil {
		return err
	}
	logger.Info("media-worker stopped")
	return nil
}
