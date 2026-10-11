package main

import (
	"log/slog"
	"strings"
	"testing"
)

func setRequired(t *testing.T) {
	t.Helper()
	t.Setenv("KAFKA_BROKERS", "redpanda:9092")
	t.Setenv("S3_ENDPOINT", "http://minio:9000")
	t.Setenv("S3_ACCESS_KEY_ID", "svp-media-worker")
	t.Setenv("S3_SECRET_ACCESS_KEY", "test-secret-value")
	for _, name := range []string{"S3_REGION", "S3_UPLOADS_BUCKET", "S3_MEDIA_BUCKET", "WORK_DIR"} {
		t.Setenv(name, "")
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	setRequired(t)
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s := cfg.store
	if cfg.brokers != "redpanda:9092" || s.Endpoint != "http://minio:9000" || s.AccessKeyID != "svp-media-worker" ||
		s.SecretAccessKey != "test-secret-value" {
		t.Errorf("required values not read: %+v", cfg)
	}
	if s.Region != "us-east-1" || s.UploadsBucket != "uploads" || s.MediaBucket != "media" || cfg.workDir != "/work" {
		t.Errorf("defaults = %q %q %q %q", s.Region, s.UploadsBucket, s.MediaBucket, cfg.workDir)
	}
}

func TestLoadConfigMissingNamesVariable(t *testing.T) {
	for _, name := range []string{"KAFKA_BROKERS", "S3_ENDPOINT", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"} {
		t.Run(name, func(t *testing.T) {
			setRequired(t)
			t.Setenv(name, "")
			_, err := loadConfig()
			if err == nil || !strings.Contains(err.Error(), name) {
				t.Errorf("err = %v, want one naming %s", err, name)
			}
		})
	}
}

func TestLoadConfigRejectsMalformedEndpoint(t *testing.T) {
	for _, value := range []string{"minio:9000", "127.0.0.1:9000", "ftp://minio:9000", "http://", "/minio"} {
		t.Run(value, func(t *testing.T) {
			setRequired(t)
			t.Setenv("S3_ENDPOINT", value)
			_, err := loadConfig()
			if err == nil || !strings.Contains(err.Error(), "S3_ENDPOINT") {
				t.Fatalf("err = %v, want one naming S3_ENDPOINT", err)
			}
			if strings.Contains(err.Error(), value) {
				t.Errorf("err %q prints the value", err)
			}
		})
	}
}

func TestLoadConfigAcceptsHTTPSEndpoint(t *testing.T) {
	setRequired(t)
	t.Setenv("S3_ENDPOINT", "https://s3.us-east-1.amazonaws.com")
	if _, err := loadConfig(); err != nil {
		t.Fatal(err)
	}
}

func TestRunRejectsOtherCommands(t *testing.T) {
	for _, cmd := range []string{"migrate", "healthcheck"} {
		if err := run(t.Context(), nil, []string{cmd}); err == nil {
			t.Errorf("run(%q) = nil, want an error", cmd)
		}
	}
}

func TestServeMalformedKafkaBrokersNamesTheVariable(t *testing.T) {
	setRequired(t)
	t.Setenv("WORK_DIR", t.TempDir())
	for _, brokers := range []string{" , ", "redpanda:notaport"} {
		t.Setenv("KAFKA_BROKERS", brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
			t.Errorf("KAFKA_BROKERS=%q: serve() = %v, want an error naming KAFKA_BROKERS", brokers, err)
		}
	}
}
