package kafkax

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"strconv"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// Defaults for the zero fields of ConsumerConfig.
const (
	DefaultMaxAttempts = 5
	DefaultBackoffBase = 500 * time.Millisecond
	DefaultBackoffMax  = 10 * time.Second
	// DefaultSessionTimeout is how long the group waits without a heartbeat before it hands a
	// killed member's partitions to another member (Kafka's default). Heartbeats run in the
	// background, so a long handler does not count against it.
	DefaultSessionTimeout = 45 * time.Second
	// DefaultRebalanceTimeout is the franz-go default.
	DefaultRebalanceTimeout = 60 * time.Second
)

// Dead-letter header names and dlq-reason values.
const (
	HeaderDLQReason    = "dlq-reason"
	HeaderDLQError     = "dlq-error"
	HeaderDLQTopic     = "dlq-topic"
	HeaderDLQPartition = "dlq-partition"
	HeaderDLQOffset    = "dlq-offset"
	HeaderDLQGroup     = "dlq-group"

	ReasonPermanent        = "permanent"
	ReasonRetriesExhausted = "retries-exhausted"
)

// DLQSuffix is appended to a topic name to name its dead-letter topic.
const DLQSuffix = ".dlq"

// commitTimeout bounds an offset commit. Commits do not use the consumer's context, so a record
// the handler finished is still committed when shutdown starts at that moment.
const commitTimeout = 10 * time.Second

// deadLetterTimeout bounds the produce of one record to its dead-letter topic, so a broker that
// never answers cannot hold the consumer on one record for good. The source record is not
// committed until the dead-letter topic has acknowledged the copy
// (docs/adr/0011-observability-stage3.md, section 11).
const deadLetterTimeout = 10 * time.Second

// Attempt tells a handler which try this is.
type Attempt struct {
	// Number counts from 1.
	Number int
	// Last is true on the final try: a transient error now sends the record to the dead-letter
	// topic instead of being retried.
	Last bool
}

// Handler processes one record. Returning nil commits it, including when the handler chose to
// skip it. An error wrapped by Permanent sends it to the dead-letter topic at once; any other
// error is retried with backoff, and sent to the dead-letter topic after the last attempt.
//
// ctx is canceled when the consumer stops; a handler that returns an error after that leaves the
// record uncommitted, so it is delivered again. ctx carries a consumer span extracted from the
// record's trace headers; logs and Produce use that span's context.
type Handler func(ctx context.Context, r *kgo.Record, a Attempt) error

type permanentError struct{ err error }

func (e *permanentError) Error() string { return e.err.Error() }
func (e *permanentError) Unwrap() error { return e.err }

// Permanent marks err as not worth retrying: a malformed event, a missing required field, a
// business rule violation. It returns nil when err is nil. The mark survives further wrapping
// with %w.
func Permanent(err error) error {
	if err == nil {
		return nil
	}
	return &permanentError{err: err}
}

// ConsumerConfig configures a group consumer. Zero values take the defaults above.
type ConsumerConfig struct {
	Brokers  string // comma-separated host:port, as for NewClient
	ClientID string
	Group    string
	Topics   []string
	Handler  Handler
	Logger   *slog.Logger

	// MaxAttempts is the number of handler calls per record, the first included.
	MaxAttempts int
	// HandlerTimeout bounds each attempt; zero leaves the handler without a deadline.
	HandlerTimeout time.Duration
	// BackoffBase is the wait after the first failure; each later wait doubles, up to
	// BackoffMax. Each wait is randomized to between half and all of that value.
	BackoffBase time.Duration
	BackoffMax  time.Duration

	// MaxPollRecords bounds the records taken per poll; 0 takes everything buffered.
	MaxPollRecords int
	// BlockRebalance holds a rebalance until the records of the current poll are settled, so a
	// commit never lands on a partition this member no longer owns. RebalanceTimeout must then
	// cover the longest handler run times MaxAttempts plus every backoff, or the group drops
	// this member and its commits fail.
	BlockRebalance bool
	// SessionTimeout and RebalanceTimeout are the Kafka group settings of the same names.
	SessionTimeout   time.Duration
	RebalanceTimeout time.Duration

	// opts are extra client options for tests.
	opts []kgo.Opt
	// deadLetterTimeout replaces the package's deadLetterTimeout in tests when set.
	deadLetterTimeout time.Duration
}

// Consumer runs a Handler over the records of a consumer group. Records are handled one at a
// time, in offset order within a partition, and each is committed right after it is settled
// (handled, skipped or sent to the dead-letter topic): delivery is at-least-once.
type Consumer struct {
	cl  *kgo.Client
	cfg ConsumerConfig
	dlq metric.Int64Counter
}

// NewConsumer checks cfg, fills in defaults and creates the client. It does not connect.
func NewConsumer(cfg ConsumerConfig) (*Consumer, error) {
	if cfg.Group == "" || len(cfg.Topics) == 0 || cfg.Handler == nil || cfg.Logger == nil {
		return nil, errors.New("kafka consumer needs a group, topics, a handler and a logger")
	}
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = DefaultMaxAttempts
	}
	return newConsumer(cfg)
}

// newConsumer fills in the defaults NewConsumer and NewBatchConsumer share and creates the client.
func newConsumer(cfg ConsumerConfig) (*Consumer, error) {
	if cfg.BackoffBase <= 0 {
		cfg.BackoffBase = DefaultBackoffBase
	}
	if cfg.BackoffMax <= 0 {
		cfg.BackoffMax = DefaultBackoffMax
	}
	if cfg.SessionTimeout <= 0 {
		cfg.SessionTimeout = DefaultSessionTimeout
	}
	if cfg.RebalanceTimeout <= 0 {
		cfg.RebalanceTimeout = DefaultRebalanceTimeout
	}
	if cfg.deadLetterTimeout <= 0 {
		cfg.deadLetterTimeout = deadLetterTimeout
	}
	opts := []kgo.Opt{
		kgo.ConsumerGroup(cfg.Group),
		kgo.ConsumeTopics(cfg.Topics...),
		kgo.DisableAutoCommit(),
		kgo.SessionTimeout(cfg.SessionTimeout),
		kgo.RebalanceTimeout(cfg.RebalanceTimeout),
	}
	if cfg.BlockRebalance {
		opts = append(opts, kgo.BlockRebalanceOnPoll())
	}
	cl, err := NewClient(cfg.Brokers, cfg.ClientID, append(opts, cfg.opts...)...)
	if err != nil {
		return nil, err
	}
	dlq, err := otel.Meter(tracerName).Int64Counter("svp.kafka.dlq.records")
	if err != nil {
		cl.Close()
		return nil, fmt.Errorf("create kafka dead-letter counter: %w", err)
	}
	for _, topic := range cfg.Topics {
		dlq.Add(context.Background(), 0, metric.WithAttributes(attribute.String("topic", topic), attribute.String("group", cfg.Group)))
	}
	return &Consumer{cl: cl, cfg: cfg, dlq: dlq}, nil
}

// errStopped means ctx was canceled while a record was in progress; that record stays
// uncommitted.
var errStopped = errors.New("consumer stopped")

// Run consumes until ctx is canceled, then returns nil, or until a record cannot be settled
// (dead-letter produce or commit failed), then returns that error with the record uncommitted.
// Either way it leaves the group and closes the client; a Consumer runs once.
func (c *Consumer) Run(ctx context.Context) error {
	defer c.cl.CloseAllowingRebalance()
	for {
		fetches := c.cl.PollRecords(ctx, c.cfg.MaxPollRecords)
		if ctx.Err() != nil {
			return nil
		}
		for _, fe := range fetches.Errors() {
			// Injected errors are informational; the client keeps retrying underneath.
			c.cfg.Logger.LogAttrs(ctx, slog.LevelWarn, "kafka fetch error",
				slog.String("topic", fe.Topic), slog.Int("partition", int(fe.Partition)), slog.String("error", fe.Err.Error()))
		}
		err := c.settleAll(ctx, fetches)
		if c.cfg.BlockRebalance {
			c.cl.AllowRebalance()
		}
		if errors.Is(err, errStopped) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func (c *Consumer) settleAll(ctx context.Context, fetches kgo.Fetches) error {
	for iter := fetches.RecordIter(); !iter.Done(); {
		if err := c.settle(ctx, iter.Next()); err != nil {
			return err
		}
	}
	return nil
}

// settle runs the handler on r with retries, sends r to the dead-letter topic when it fails,
// and commits it.
func (c *Consumer) settle(ctx context.Context, r *kgo.Record) error {
	var hctx context.Context
	var (
		err    error
		reason string
	)
	for n := 1; ; n++ {
		a := Attempt{Number: n, Last: n >= c.cfg.MaxAttempts}
		hctx, err = c.handle(ctx, r, a)
		if err == nil {
			return c.commit(ctx, r)
		}
		if ctx.Err() != nil {
			return errStopped
		}
		if pe := (*permanentError)(nil); errors.As(err, &pe) {
			reason = ReasonPermanent
			break
		}
		if a.Last {
			reason = ReasonRetriesExhausted
			break
		}
		wait := c.backoff(n)
		c.cfg.Logger.LogAttrs(hctx, slog.LevelWarn, "kafka handler failed, retrying",
			recordAttrs(r, slog.Int("attempt", n), slog.Duration("backoff", wait), slog.String("error", err.Error()))...)
		if !sleep(ctx, wait) {
			return errStopped
		}
	}
	dctx := trace.ContextWithSpanContext(ctx, trace.SpanContextFromContext(hctx))
	if err := c.deadLetter(dctx, r, reason, err); err != nil {
		return err
	}
	c.cfg.Logger.LogAttrs(hctx, slog.LevelWarn, "kafka record sent to dead-letter topic",
		recordAttrs(r, slog.String("reason", reason), slog.String("error", err.Error()))...)
	return c.commit(ctx, r)
}

func (c *Consumer) handle(ctx context.Context, r *kgo.Record, a Attempt) (context.Context, error) {
	hctx, span := otel.Tracer(tracerName).Start(handlerContext(ctx, r), "process "+r.Topic,
		trace.WithSpanKind(trace.SpanKindConsumer), trace.WithAttributes(
			semconv.MessagingSystemKafka, semconv.MessagingDestinationName(r.Topic),
			semconv.MessagingConsumerGroupName(c.cfg.Group), semconv.MessagingOperationName("process"),
			semconv.MessagingOperationTypeProcess))
	hctx, cancel := attemptContext(hctx, c.cfg.HandlerTimeout)
	defer cancel()
	err := c.cfg.Handler(hctx, r, a)
	return hctx, endAttempt(span, err)
}

// deadLetter writes r, with its key, value and headers, to its dead-letter topic.
func (c *Consumer) deadLetter(ctx context.Context, r *kgo.Record, reason string, cause error) error {
	headers := make([]kgo.RecordHeader, 0, len(r.Headers)+6)
	headers = append(headers, r.Headers...)
	headers = append(headers,
		kgo.RecordHeader{Key: HeaderDLQReason, Value: []byte(reason)},
		kgo.RecordHeader{Key: HeaderDLQError, Value: []byte(cause.Error())},
		kgo.RecordHeader{Key: HeaderDLQTopic, Value: []byte(r.Topic)},
		kgo.RecordHeader{Key: HeaderDLQPartition, Value: []byte(strconv.Itoa(int(r.Partition)))},
		kgo.RecordHeader{Key: HeaderDLQOffset, Value: []byte(strconv.FormatInt(r.Offset, 10))},
		kgo.RecordHeader{Key: HeaderDLQGroup, Value: []byte(c.cfg.Group)},
	)
	dlq := &kgo.Record{Topic: r.Topic + DLQSuffix, Key: r.Key, Value: r.Value, Headers: headers}
	pctx, cancel := context.WithTimeout(ctx, c.cfg.deadLetterTimeout)
	defer cancel()
	if err := Produce(pctx, c.cl, dlq); err != nil {
		if ctx.Err() != nil {
			return errStopped
		}
		return fmt.Errorf("produce %s/%d@%d to dead-letter topic %s: %w", r.Topic, r.Partition, r.Offset, dlq.Topic, err)
	}
	c.dlq.Add(ctx, 1, metric.WithAttributes(attribute.String("topic", r.Topic), attribute.String("group", c.cfg.Group)))
	return nil
}

func (c *Consumer) commit(ctx context.Context, r *kgo.Record) error {
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), commitTimeout)
	defer cancel()
	if err := c.cl.CommitRecords(cctx, r); err != nil {
		return fmt.Errorf("commit %s/%d@%d: %w", r.Topic, r.Partition, r.Offset, err)
	}
	return nil
}

// backoff returns the wait after failed attempt n: BackoffBase doubled n-1 times, capped at
// BackoffMax, then randomized to between half and all of it so consumers do not retry in step.
func (c *Consumer) backoff(n int) time.Duration {
	d := c.cfg.BackoffBase
	for i := 1; i < n && d < c.cfg.BackoffMax; i++ {
		d *= 2
	}
	d = min(d, c.cfg.BackoffMax)
	return d/2 + rand.N(d/2+1) //nolint:gosec // jitter, not a secret
}

// sleep waits d and returns true, or returns false as soon as ctx is canceled.
func sleep(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

// recordAttrs locates r in a log line; the value is never logged.
func recordAttrs(r *kgo.Record, extra ...slog.Attr) []slog.Attr {
	return append([]slog.Attr{
		slog.String("topic", r.Topic),
		slog.Int("partition", int(r.Partition)),
		slog.Int64("offset", r.Offset),
	}, extra...)
}
