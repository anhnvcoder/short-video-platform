package main

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestServeRequiresItsVariables(t *testing.T) {
	for _, tc := range []struct{ databaseURL, brokers, want string }{
		{"", "redpanda:9092", "DATABASE_URL"},
		{"postgres://unused@127.0.0.1:1/unused", "", "KAFKA_BROKERS"},
		// The broker list is checked before the database is opened, so this URL is never dialled.
		{"postgres://unused@127.0.0.1:1/unused", " , ", "KAFKA_BROKERS"},
		{"postgres://unused@127.0.0.1:1/unused", "redpanda:notaport", "KAFKA_BROKERS"},
	} {
		t.Setenv("DATABASE_URL", tc.databaseURL)
		t.Setenv("KAFKA_BROKERS", tc.brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("DATABASE_URL=%q KAFKA_BROKERS=%q: serve() = %v, want an error naming %s",
				tc.databaseURL, tc.brokers, err, tc.want)
		}
	}
}

func TestRunRejectsUnknownCommand(t *testing.T) {
	if err := run(t.Context(), slog.New(slog.DiscardHandler), []string{"serv"}); err == nil {
		t.Error("run(serv) = nil, want an error")
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
