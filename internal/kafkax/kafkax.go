// Package kafkax builds the franz-go clients every service uses, produces records carrying the
// request's traceparent, and runs group consumers with manual commits, in-process retries and a
// dead-letter topic. A record is committed only after its handler returns, and one that keeps
// failing goes to the dead-letter topic instead of blocking its partition, so none is lost or
// stuck.
package kafkax

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/sasl/scram"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
)

// The SASL credentials every client of the process authenticates with. Both unset or empty: no
// SASL, as on the compose stack, whose broker has no authentication.
const (
	saslUsernameVar = "KAFKA_SASL_USERNAME"
	saslPasswordVar = "KAFKA_SASL_PASSWORD" //nolint:gosec // the name of the variable, not a credential
)

// metadataMinAge is the shortest gap between two metadata requests of a client. franz-go waits
// that long between refreshes it triggers on errors (healthy clients refresh every
// MetadataMaxAge, 5 minutes), and a record whose connection died is failed only at such a
// refresh, so a produce can return up to this long after its deadline. With the franz-go default
// of 5 s the outbox relay could hold its lock ~15 s on a 10 s produce deadline and a view write
// take ~7 s on a 2 s one; 1 s brings those to ~11 s and ~3 s, for at most one extra metadata
// request per second per client while a broker is failing.
const metadataMinAge = time.Second

// NewClient returns a client for brokers, a comma-separated list of host:port such as the
// KAFKA_BROKERS variable, identified to the brokers as clientID (the service name). The
// producer is idempotent with acks=all, the franz-go defaults. opts are added after those, so a
// caller's option overrides a default set here.
//
// With KAFKA_SASL_USERNAME and KAFKA_SASL_PASSWORD set, the client authenticates with
// SCRAM-SHA-256; with only one of them set, NewClient fails. The variables are read here rather
// than in each main so that every client of a service, the dead-letter producer inside a
// consumer included, authenticates the same way: a client built without them would be refused
// by a broker with ACLs. SCRAM does not send the password, only a proof of it, but the
// connection itself is plain TCP: encrypting traffic inside the cluster (threat model IN-3) is a
// later step than authenticating it, and the local setups do without it.
//
// The client's warnings and errors, a refused password included, go to the default slog logger.
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
	sasl, err := saslOpts()
	if err != nil {
		return nil, err
	}
	all := []kgo.Opt{kgo.SeedBrokers(seeds...), kgo.ClientID(clientID), kgo.AllowIdempotentProduceCancellation(),
		kgo.MetadataMinAge(metadataMinAge), kgo.WithLogger(slogLogger{})}
	all = append(append(all, sasl...), opts...)
	cl, err := kgo.NewClient(all...)
	if err != nil {
		return nil, fmt.Errorf("create kafka client: %w", err)
	}
	return cl, nil
}

// saslOpts returns the SCRAM-SHA-256 option for the credentials in the environment, or none when
// neither variable is set. The error names the missing variable and never carries a value.
func saslOpts() ([]kgo.Opt, error) {
	user, pass := envcfg.String(saslUsernameVar, ""), envcfg.String(saslPasswordVar, "")
	switch {
	case user == "" && pass == "":
		return nil, nil
	case user == "":
		return nil, fmt.Errorf("%s is set but %s is not; set both for SASL or neither", saslPasswordVar, saslUsernameVar)
	case pass == "":
		return nil, fmt.Errorf("%s is set but %s is not; set both for SASL or neither", saslUsernameVar, saslPasswordVar)
	}
	return []kgo.Opt{kgo.SASL(scram.Auth{User: user, Pass: pass}.AsSha256Mechanism())}, nil
}

// slogLogger passes the warnings and errors of a franz-go client to the process's default slog
// logger. franz-go logs nothing without a logger, so a broker refusing the SASL credentials or
// not reachable at all showed only as produce deadline errors and consumer lag. Info and debug
// stay off: they log every request and every rebalance step. The lines carry the broker, its
// address, group or topic and the error, none of them a credential (SCRAM sends a proof, not the
// password). An ERROR also reaches the error tracker of a service that runs one, as an unlisted
// error without its text.
type slogLogger struct{}

func (slogLogger) Level() kgo.LogLevel { return kgo.LogLevelWarn }

// Log takes franz-go's key/value pairs as they are: slog reads the same alternating pairs.
func (slogLogger) Log(level kgo.LogLevel, msg string, keyvals ...any) {
	l := slog.LevelWarn
	if level == kgo.LogLevelError {
		l = slog.LevelError
	}
	slog.Default().Log(context.Background(), l, "kafka client: "+msg, keyvals...)
}

// Produce writes rs and waits until every record is acknowledged. Each record gets a producer
// span parented by its Context, or ctx when absent, and fresh trace headers for that span.
// The call's cancellation and deadline bound every record, one already sent included; a record
// whose connection was lost is failed at the client's next metadata refresh, which can come up to
// metadataMinAge (1 s) after the deadline. It returns the first produce error.
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
