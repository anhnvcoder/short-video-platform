package kafkax

import (
	"context"
	"slices"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
)

const tracerName = "github.com/anhnvcoder/short-video-platform/internal/kafkax"

type recordCarrier struct{ r *kgo.Record }

func (c recordCarrier) Get(key string) string {
	v, _ := header(c.r, key)
	return v
}

func (c recordCarrier) Set(key, value string) {
	c.remove(key)
	c.r.Headers = append(c.r.Headers, kgo.RecordHeader{Key: key, Value: []byte(value)})
}

func (c recordCarrier) Keys() []string {
	keys := make([]string, 0, len(c.r.Headers))
	for _, h := range c.r.Headers {
		keys = append(keys, h.Key)
	}
	return keys
}

func (c recordCarrier) remove(key string) {
	c.r.Headers = slices.DeleteFunc(c.r.Headers, func(h kgo.RecordHeader) bool { return h.Key == key })
}

// handlerContext keeps lifetime and values from ctx, but only accepts a trace parent from r.
// Clearing the ambient span makes missing or malformed headers start a new trace.
func handlerContext(ctx context.Context, r *kgo.Record) context.Context {
	ctx = trace.ContextWithSpanContext(ctx, trace.SpanContext{})
	return otel.GetTextMapPropagator().Extract(ctx, recordCarrier{r})
}

func attemptContext(ctx context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if timeout > 0 {
		return context.WithTimeout(ctx, timeout)
	}
	return ctx, func() {}
}

// endAttempt ends the span of one handler attempt and returns err, the handler's own result: a
// Permanent error returned after the attempt's deadline still goes to the dead-letter topic at
// once, and nil returned as the consumer stops still commits. The span gets the error's type and
// safe code only, as the error tracker does: a handler's error can wrap a Postgres message quoting
// a parameter, or a value of the record (docs/adr/0011-observability-stage3.md, section 7).
func endAttempt(span trace.Span, err error) error {
	if err != nil {
		kind, code := sentryx.DescribeError(err)
		attrs := []attribute.KeyValue{semconv.ExceptionType(kind)}
		if code != "" {
			attrs = append(attrs, semconv.ExceptionMessage(code))
		}
		span.AddEvent(semconv.ExceptionEventName, trace.WithAttributes(attrs...))
		span.SetStatus(codes.Error, kind)
	}
	span.End()
	return err
}
