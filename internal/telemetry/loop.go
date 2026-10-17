package telemetry

import (
	"context"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// Loop reports the last successful iteration, including a successful no-op. Until the first
// success, it reports zero. The current value is observed on every collection, even unchanged.
type Loop struct{ last atomic.Int64 }

// NewLoop creates the last-success gauge for a fixed background loop name.
func NewLoop(name string) *Loop {
	l := &Loop{}
	meter := otel.Meter("github.com/anhnvcoder/short-video-platform/internal/telemetry")
	gauge, err := meter.Int64ObservableGauge("svp.loop.last_success", metric.WithUnit("s"))
	if err != nil {
		otel.Handle(err)
		return l
	}
	// Each loop needs its own registration: callbacks on duplicate instrument creation are ignored.
	_, err = meter.RegisterCallback(func(_ context.Context, o metric.Observer) error {
		o.ObserveInt64(gauge, l.last.Load(), metric.WithAttributes(attribute.String("loop", name)))
		return nil
	}, gauge)
	if err != nil {
		otel.Handle(err)
	}
	return l
}

// Succeeded records the current Unix timestamp in seconds.
func (l *Loop) Succeeded() { l.last.Store(time.Now().Unix()) }
