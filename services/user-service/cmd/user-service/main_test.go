package main

import (
	"encoding/base64"
	"log/slog"
	"strings"
	"testing"
)

func TestServeKafkaBrokersMissingOrMalformedNamesTheVariable(t *testing.T) {
	t.Setenv("JWT_SIGNING_KID", "test")
	t.Setenv("JWT_SIGNING_KEY", base64.StdEncoding.EncodeToString(make([]byte, 32)))
	// The broker list is checked before the database is opened, so this URL is never dialled.
	t.Setenv("DATABASE_URL", "postgres://unused@127.0.0.1:1/unused")
	for _, brokers := range []string{"", " , ", "redpanda:notaport"} {
		t.Setenv("KAFKA_BROKERS", brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), "KAFKA_BROKERS") {
			t.Errorf("KAFKA_BROKERS=%q: serve() = %v, want an error naming KAFKA_BROKERS", brokers, err)
		}
	}
}
