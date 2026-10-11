package main

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/anhnvcoder/short-video-platform/internal/objstore"
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
		"S3_ENDPOINT":          "http://minio:9000",
		"S3_ACCESS_KEY_ID":     "svp-video-service",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	})
	// The broker list is checked before the database is opened, so this URL is never dialled.
	t.Setenv("DATABASE_URL", "postgres://unused@127.0.0.1:1/unused")
	for _, brokers := range []string{" , ", "redpanda:notaport"} {
		t.Setenv("KAFKA_BROKERS", brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
			t.Errorf("KAFKA_BROKERS=%q: serve() = %v, want an error naming KAFKA_BROKERS", brokers, err)
		}
	}
}

func TestStorageConfigDefaults(t *testing.T) {
	setStorageEnv(t, map[string]string{
		"S3_ENDPOINT":          "http://minio:9000",
		"S3_ACCESS_KEY_ID":     "svp-video-service",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	})
	got, err := storageConfig()
	if err != nil {
		t.Fatal(err)
	}
	want := objstore.Config{
		Endpoint:        "http://minio:9000",
		PublicEndpoint:  "http://minio:9000",
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
		"S3_ENDPOINT":          "http://minio:9000",
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
		"S3_ENDPOINT":          "http://minio:9000",
		"S3_ACCESS_KEY_ID":     "key",
		"S3_SECRET_ACCESS_KEY": "secret-value",
	}
	for _, tc := range []struct{ name, variable, value string }{
		{"missing endpoint", "S3_ENDPOINT", ""},
		{"endpoint without scheme", "S3_ENDPOINT", "minio:9000"},
		{"endpoint with another scheme", "S3_ENDPOINT", "ftp://minio:9000"},
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
