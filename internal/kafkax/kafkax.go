// Package kafkax builds the franz-go clients every service uses, produces records carrying the
// request's traceparent, and runs group consumers with manual commits, in-process retries and a
// dead-letter topic (ADR-0003, ADR-0008 section 8).
package kafkax

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// NewClient returns a client for brokers, a comma-separated list of host:port such as the
// KAFKA_BROKERS variable, identified to the brokers as clientID (the service name). The
// producer is idempotent with acks=all, the franz-go defaults. opts are added after those.
//
// NewClient does not connect; the first request does.
func NewClient(brokers, clientID string, opts ...kgo.Opt) (*kgo.Client, error) {
	var seeds []string
	for b := range strings.SplitSeq(brokers, ",") {
		if b = strings.TrimSpace(b); b != "" {
			seeds = append(seeds, b)
		}
	}
	if len(seeds) == 0 {
		return nil, errors.New("kafka broker list is empty")
	}
	all := append([]kgo.Opt{kgo.SeedBrokers(seeds...), kgo.ClientID(clientID), kgo.AllowIdempotentProduceCancellation()}, opts...)
	cl, err := kgo.NewClient(all...)
	if err != nil {
		return nil, fmt.Errorf("create kafka client: %w", err)
	}
	return cl, nil
}

// Produce writes rs and waits until every record is acknowledged. Each record gets a producer
// span parented by its Context, or ctx when absent, and fresh trace headers for that span.
// The call's cancellation and deadline bound every record, one already sent included; a record
// whose connection was lost is failed at the client's next metadata refresh, which can come up to
// MetadataMinAge (5 s) after the deadline. It returns the first produce error.
func Produce(ctx context.Context, cl *kgo.Client, rs ...*kgo.Record) error {
	for _, r := range rs {
		parent := ctx
		if r.Context != nil {
			parent = trace.ContextWithSpanContext(ctx, trace.SpanContextFromContext(r.Context))
		}
		r.Context, _ = otel.Tracer(tracerName).Start(parent, "send "+r.Topic,
			trace.WithSpanKind(trace.SpanKindProducer), trace.WithAttributes(
				semconv.MessagingSystemKafka, semconv.MessagingDestinationName(r.Topic),
				semconv.MessagingOperationName("send"), semconv.MessagingOperationTypeSend))
		carrier := recordCarrier{r}
		carrier.remove("traceparent")
		carrier.remove("tracestate")
		otel.GetTextMapPropagator().Inject(r.Context, carrier)
	}
	results := cl.ProduceSync(ctx, rs...)
	for _, result := range results {
		span := trace.SpanFromContext(result.Record.Context)
		if result.Err != nil {
			span.RecordError(result.Err)
			span.SetStatus(codes.Error, result.Err.Error())
		}
		span.End()
	}
	if err := results.FirstErr(); err != nil {
		return fmt.Errorf("produce: %w", err)
	}
	return nil
}

// header returns the value of the first header named key, and whether there is one.
func header(r *kgo.Record, key string) (string, bool) {
	for _, h := range r.Headers {
		if h.Key == key {
			return string(h.Value), true
		}
	}
	return "", false
}
