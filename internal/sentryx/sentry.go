// Package sentryx sends allowlisted error metadata to a Sentry-compatible tracker.
package sentryx

import (
	"errors"
	"os"
	"sync/atomic"
	"time"

	"github.com/getsentry/sentry-go"
)

type reporter struct {
	client  *sentry.Client
	service string
	limits  limiter
	// after runs f once d has passed; tests replace it to run f themselves.
	after func(d time.Duration, f func())
}

var active atomic.Pointer[reporter]

// Init enables reporting only with an explicit SENTRY_DSN. Call it from serve.
// The returned function flushes the asynchronous transport for at most two seconds.
func Init(service string) (flush func(), err error) {
	return initClient(service, nil)
}

func initClient(service string, transport sentry.Transport) (func(), error) {
	active.Store(nil)
	dsn := os.Getenv("SENTRY_DSN")
	if dsn == "" {
		return func() {}, nil
	}
	environment := os.Getenv("SENTRY_ENVIRONMENT")
	if environment == "" {
		environment = "local"
	}
	client, err := sentry.NewClient(sentry.ClientOptions{
		// SendDefaultPII stays at its false zero value (deprecated in v0.50).
		Dsn: dsn, Environment: environment,
		AttachStacktrace: true, EnableTracing: false, BeforeSend: beforeSend,
		Transport: transport,
		// Default integrations add source text and machine metadata. Events here
		// are constructed explicitly and must contain neither.
		Integrations: func([]sentry.Integration) []sentry.Integration { return nil },
	})
	if err != nil {
		return nil, errors.New("invalid SENTRY_DSN")
	}
	r := &reporter{client: client, service: service, after: func(d time.Duration, f func()) { time.AfterFunc(d, f) }}
	active.Store(r)
	return func() {
		active.CompareAndSwap(r, nil)
		client.Flush(2 * time.Second)
	}, nil
}
