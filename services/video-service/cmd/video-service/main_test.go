package main

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel"

	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/internal/sentryx"
)

func setStorageEnv(t *testing.T, env map[string]string) {
	t.Helper()
	for _, name := range []string{"S3_ENDPOINT", "S3_PUBLIC_ENDPOINT", "S3_REGION", "S3_ACCESS_KEY_ID",
		"S3_SECRET_ACCESS_KEY", "S3_UPLOADS_BUCKET", "S3_MEDIA_BUCKET"} {
		t.Setenv(name, env[name])
	}
}

func TestServeMalformedKafkaBrokersNamesTheVariable(t *testing.T) {
	setStorageEnv(t, map[string]string{
		"S3_ENDPOINT":          "http://s3:9000",
		"S3_ACCESS_KEY_ID":     "svp-video-service",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	})
	// The broker list is checked before the database is opened, so this URL is never dialled.
	t.Setenv("DATABASE_URL", "postgres://unused@127.0.0.1:1/unused")
	// Telemetry and error reporting off, as without the obs profile: serve gets past both.
	for _, name := range []string{"SENTRY_DSN", "OTEL_EXPORTER_OTLP_ENDPOINT", "PYROSCOPE_SERVER_ADDRESS"} {
		t.Setenv(name, "")
	}
	for _, brokers := range []string{" , ", "redpanda:notaport"} {
		t.Setenv("KAFKA_BROKERS", brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
			t.Errorf("KAFKA_BROKERS=%q: serve() = %v, want an error naming KAFKA_BROKERS", brokers, err)
		}
	}
}

// probedError is an ERROR record and what was still open when it was logged.
type probedError struct {
	message string
	// tracker reports whether the error tracker took ERROR records.
	tracker bool
	// telemetry reports whether the tracer provider of telemetry.Setup was still open. It shuts
	// down together with the logger and meter providers, so this stands for all three.
	telemetry bool
}

// failureProbe is a slog handler noting, for each ERROR record, whether the error tracker and the
// telemetry providers still took records. It forwards nothing, so no event is ever sent.
type failureProbe struct {
	mu     sync.Mutex
	errors []probedError
}

func (*failureProbe) Enabled(context.Context, slog.Level) bool { return true }

func (p *failureProbe) Handle(ctx context.Context, r slog.Record) error {
	if r.Level < slog.LevelError {
		return nil
	}
	_, span := otel.Tracer("probe").Start(ctx, "probe")
	e := probedError{message: r.Message, tracker: (&sentryx.Handler{}).Enabled(ctx, slog.LevelError), telemetry: span.IsRecording()}
	span.End()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.errors = append(p.errors, e)
	return nil
}

func (p *failureProbe) WithAttrs([]slog.Attr) slog.Handler { return p }
func (p *failureProbe) WithGroup(string) slog.Handler      { return p }

func (p *failureProbe) logged() []probedError {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]probedError(nil), p.errors...)
}

// serveEnv sets what serve needs to get past its configuration, with the error tracker on and
// telemetry recording but exporting nowhere.
func serveEnv(t *testing.T) {
	t.Helper()
	setStorageEnv(t, map[string]string{
		"S3_ENDPOINT":          "http://s3:9000",
		"S3_ACCESS_KEY_ID":     "svp-video-service",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	})
	t.Setenv("DATABASE_URL", "postgres://unused@127.0.0.1:1/unused")
	t.Setenv("UPLOAD_ABANDON_AFTER", "")
	t.Setenv("UPLOAD_SWEEP_INTERVAL", "")
	// A valid DSN whose host never resolves: the probe sends no event.
	t.Setenv("SENTRY_DSN", "http://public@glitchtip.invalid/1")
	for _, name := range []string{"OTEL_SDK_DISABLED", "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_TRACES_SAMPLER",
		"PYROSCOPE_SERVER_ADDRESS"} {
		t.Setenv(name, "")
	}
}

// A failure once the error tracker and the providers are set up is logged while both still take
// records, so it reaches GlitchTip and the Collector, and is marked so main does not log it again.
func TestServeLogsFailureBeforeClosingReporters(t *testing.T) {
	serveEnv(t)
	// Checked after the error tracker is set up, before the database is opened.
	t.Setenv("KAFKA_BROKERS", "redpanda:notaport")
	probe := &failureProbe{}
	err := serve(t.Context(), slog.New(probe))
	if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
		t.Fatalf("serve() = %v, want an error naming KAFKA_BROKERS", err)
	}
	if _, ok := errors.AsType[loggedError](err); !ok {
		t.Error("serve() error is not marked as logged: main would log it a second time")
	}
	want := probedError{message: "video-service failed", tracker: true, telemetry: true}
	if got := probe.logged(); len(got) != 1 || got[0] != want {
		t.Errorf("ERROR records = %+v, want [%+v]", got, want)
	}
	if (&sentryx.Handler{}).Enabled(t.Context(), slog.LevelError) {
		t.Error("error tracker still open after serve returned")
	}
}

// A configuration error comes before there is anything to report to: serve leaves it to main.
func TestServeLeavesEarlyFailureToMain(t *testing.T) {
	serveEnv(t)
	t.Setenv("DATABASE_URL", "")
	probe := &failureProbe{}
	err := serve(t.Context(), slog.New(probe))
	if err == nil || !strings.Contains(err.Error(), "DATABASE_URL") {
		t.Fatalf("serve() = %v, want an error naming DATABASE_URL", err)
	}
	if _, ok := errors.AsType[loggedError](err); ok {
		t.Error("serve() marked an error it did not log")
	}
	if got := probe.logged(); len(got) != 0 {
		t.Errorf("ERROR records = %+v, want none", got)
	}
}

func TestStorageConfigDefaults(t *testing.T) {
	setStorageEnv(t, map[string]string{
		"S3_ENDPOINT":          "http://s3:9000",
		"S3_ACCESS_KEY_ID":     "svp-video-service",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	})
	got, err := storageConfig()
	if err != nil {
		t.Fatal(err)
	}
	want := objstore.Config{
		Endpoint:        "http://s3:9000",
		PublicEndpoint:  "http://s3:9000",
		Region:          "us-east-1",
		AccessKeyID:     "svp-video-service",
		SecretAccessKey: "secret-value",
		UploadsBucket:   "uploads",
		MediaBucket:     "media",
	}
	if got != want {
		t.Errorf("storageConfig() = %+v, want %+v", got, want)
	}
}

func TestStorageConfigSetValues(t *testing.T) {
	setStorageEnv(t, map[string]string{
		"S3_ENDPOINT":          "http://s3:9000",
		"S3_PUBLIC_ENDPOINT":   "http://127.0.0.1:9000",
		"S3_REGION":            "ap-southeast-1",
		"S3_ACCESS_KEY_ID":     "key",
		"S3_SECRET_ACCESS_KEY": "secret-value",
		"S3_UPLOADS_BUCKET":    "up",
		"S3_MEDIA_BUCKET":      "md",
	})
	got, err := storageConfig()
	if err != nil {
		t.Fatal(err)
	}
	if got.PublicEndpoint != "http://127.0.0.1:9000" || got.Region != "ap-southeast-1" ||
		got.UploadsBucket != "up" || got.MediaBucket != "md" {
		t.Errorf("storageConfig() = %+v", got)
	}
}

func TestStorageConfigErrorsNameTheVariable(t *testing.T) {
	valid := map[string]string{
		"S3_ENDPOINT":          "http://s3:9000",
		"S3_ACCESS_KEY_ID":     "key",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	}
	for _, tc := range []struct{ name, variable, value string }{
		{"missing endpoint", "S3_ENDPOINT", ""},
		{"endpoint without scheme", "S3_ENDPOINT", "s3:9000"},
		{"endpoint with another scheme", "S3_ENDPOINT", "ftp://s3:9000"},
		{"endpoint without host", "S3_ENDPOINT", "http:///x"},
		{"bad public endpoint", "S3_PUBLIC_ENDPOINT", "127.0.0.1:9000"},
		{"missing access key", "S3_ACCESS_KEY_ID", ""},
		{"missing secret key", "S3_SECRET_ACCESS_KEY", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := map[string]string{}
			for k, v := range valid {
				env[k] = v
			}
			env[tc.variable] = tc.value
			setStorageEnv(t, env)
			_, err := storageConfig()
			if err == nil || !strings.Contains(err.Error(), tc.variable) {
				t.Fatalf("storageConfig() error = %v, want one naming %s", err, tc.variable)
			}
			if strings.Contains(err.Error(), "secret-value") {
				t.Errorf("error leaks the secret: %v", err)
			}
		})
	}
}

type fakeConsumer func(ctx context.Context) error

func (f fakeConsumer) Run(ctx context.Context) error { return f(ctx) }

// A consumer that stops on an error is replaced, and the loop ends without error once ctx is
// canceled.
func TestRunConsumerReplacesAFailedConsumer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	made := 0
	newConsumer := func() (runner, error) {
		made++
		if made == 1 {
			return fakeConsumer(func(context.Context) error { return errors.New("commit failed") }), nil
		}
		return fakeConsumer(func(ctx context.Context) error {
			cancel()
			<-ctx.Done()
			return nil
		}), nil
	}
	if err := runConsumer(ctx, slog.New(slog.DiscardHandler), time.Millisecond, newConsumer); err != nil {
		t.Fatalf("runConsumer() = %v, want nil", err)
	}
	if made != 2 {
		t.Errorf("made %d consumers, want 2", made)
	}
}

func TestRunConsumerStopsWhileWaitingToRestart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	made := 0
	newConsumer := func() (runner, error) {
		made++
		return fakeConsumer(func(context.Context) error {
			time.AfterFunc(10*time.Millisecond, cancel)
			return errors.New("commit failed")
		}), nil
	}
	if err := runConsumer(ctx, slog.New(slog.DiscardHandler), time.Hour, newConsumer); err != nil {
		t.Fatalf("runConsumer() = %v, want nil", err)
	}
	if made != 1 {
		t.Errorf("made %d consumers, want 1", made)
	}
}

func TestRunConsumerReturnsCreateError(t *testing.T) {
	want := errors.New("bad config")
	newConsumer := func() (runner, error) { return nil, want }
	err := runConsumer(context.Background(), slog.New(slog.DiscardHandler), time.Millisecond, newConsumer)
	if !errors.Is(err, want) {
		t.Fatalf("runConsumer() = %v, want %v", err, want)
	}
}

func TestPositiveDuration(t *testing.T) {
	const name = "UPLOAD_SWEEP_INTERVAL"
	t.Setenv(name, "")
	if got, err := positiveDuration(name, defaultSweepInterval); err != nil || got != 5*time.Minute {
		t.Errorf("unset: positiveDuration() = (%s, %v), want 5m", got, err)
	}
	t.Setenv(name, "90s")
	if got, err := positiveDuration(name, defaultSweepInterval); err != nil || got != 90*time.Second {
		t.Errorf("90s: positiveDuration() = (%s, %v), want 1m30s", got, err)
	}
	for _, value := range []string{"0", "0s", "-5m", "5", "abc", "1 h"} {
		t.Setenv(name, value)
		_, err := positiveDuration(name, defaultSweepInterval)
		if err == nil || !strings.Contains(err.Error(), name) {
			t.Errorf("%s=%q: positiveDuration() error = %v, want an error naming %s", name, value, err, name)
		}
	}
}

func TestServeRejectsInvalidSweepSettings(t *testing.T) {
	setStorageEnv(t, map[string]string{
		"S3_ENDPOINT":          "http://s3:9000",
		"S3_ACCESS_KEY_ID":     "svp-video-service",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	})
	// Both settings are checked before Kafka or the database is reached.
	t.Setenv("DATABASE_URL", "postgres://unused@127.0.0.1:1/unused")
	t.Setenv("KAFKA_BROKERS", "127.0.0.1:1")
	for _, name := range []string{"UPLOAD_ABANDON_AFTER", "UPLOAD_SWEEP_INTERVAL"} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("UPLOAD_ABANDON_AFTER", "")
			t.Setenv("UPLOAD_SWEEP_INTERVAL", "")
			t.Setenv(name, "-1m")
			err := serve(t.Context(), slog.New(slog.DiscardHandler))
			if err == nil || !strings.Contains(err.Error(), name) {
				t.Errorf("serve() = %v, want an error naming %s", err, name)
			}
		})
	}
}
