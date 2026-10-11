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

	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
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
	all := append([]kgo.Opt{kgo.SeedBrokers(seeds...), kgo.ClientID(clientID)}, opts...)
	cl, err := kgo.NewClient(all...)
	if err != nil {
		return nil, fmt.Errorf("create kafka client: %w", err)
	}
	return cl, nil
}

// Produce writes rs and waits until every record is acknowledged. A record without a
// traceparent header gets the one stored in ctx by traceparent.NewContext, if any; the header is
// appended to the record itself. It returns the first error when any record fails.
func Produce(ctx context.Context, cl *kgo.Client, rs ...*kgo.Record) error {
	if tp, ok := traceparent.FromContext(ctx); ok {
		for _, r := range rs {
			if !hasHeader(r, traceparent.MetadataKey) {
				r.Headers = append(r.Headers, kgo.RecordHeader{Key: traceparent.MetadataKey, Value: []byte(tp)})
			}
		}
	}
	if err := cl.ProduceSync(ctx, rs...).FirstErr(); err != nil {
		return fmt.Errorf("produce: %w", err)
	}
	return nil
}

func hasHeader(r *kgo.Record, key string) bool {
	for _, h := range r.Headers {
		if h.Key == key {
			return true
		}
	}
	return false
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
