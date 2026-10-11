package kafkax

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
)

// Defaults for the zero fields of BatchConsumerConfig (ADR-0009 section 4).
const (
	DefaultMaxBatchRecords = 5000
	DefaultMaxBatchWait    = time.Second
)

// TopicPartition names one partition of a topic.
type TopicPartition struct {
	Topic     string
	Partition int32
}

// Batch is the records a BatchHandler settles together. It carries no end offsets: a handler
// that needs the current end of a partition asks EndOffsets.
type Batch struct {
	// Records holds the records of every partition in the batch, in offset order within each
	// partition.
	Records []*kgo.Record
}

// add appends the records of fetches.
func (b *Batch) add(fetches kgo.Fetches) {
	fetches.EachPartition(func(p kgo.FetchTopicPartition) {
		b.Records = append(b.Records, p.Records...)
	})
}

// Rejected is a record a BatchHandler will not process, and why.
type Rejected struct {
	Record *kgo.Record
	Err    error
}

// BatchHandler processes a batch. Returning a nil error settles the whole batch: the rejected
// records go to their dead-letter topic with dlq-reason=permanent, then the highest offset of
// every partition in the batch is committed. Any error retries the whole batch, unchanged, with
// backoff and no limit on attempts.
//
// ctx is canceled when the consumer stops; a handler that returns an error after that leaves the
// batch uncommitted, so it is delivered again.
type BatchHandler func(ctx context.Context, b *Batch) ([]Rejected, error)

// BatchConsumerConfig configures a group consumer that handles records in batches. Zero values
// take the defaults above and those of ConsumerConfig.
type BatchConsumerConfig struct {
	Brokers  string // comma-separated host:port, as for NewClient
	ClientID string
	Group    string
	Topics   []string
	Handler  BatchHandler
	Logger   *slog.Logger

	// A batch ends when it holds MaxBatchRecords records or MaxBatchWait has passed since its
	// first record, whichever comes first.
	MaxBatchRecords int
	MaxBatchWait    time.Duration

	// BackoffBase and BackoffMax shape the waits between attempts, as in ConsumerConfig.
	BackoffBase time.Duration
	BackoffMax  time.Duration

	// SessionTimeout and RebalanceTimeout are the Kafka group settings of the same names.
	// Rebalances wait while a batch is collected and handled, so RebalanceTimeout should cover
	// MaxBatchWait plus one handler run. The default RebalanceTimeout is a fixed 60 s whatever
	// MaxBatchWait is: enough while MaxBatchWait keeps its 1 s default; a longer MaxBatchWait
	// needs a RebalanceTimeout set to match.
	SessionTimeout   time.Duration
	RebalanceTimeout time.Duration

	// opts are extra client options for tests.
	opts []kgo.Opt
}

// BatchConsumer runs a BatchHandler over the records of a consumer group and commits each batch
// once it is settled: delivery is at-least-once, and a batch can be delivered again in part or
// whole.
//
// Rebalances are held from the poll that starts a batch until the batch is settled, so the commit
// usually lands while this member still owns the partitions. Exact counting must not rely on it:
// a handler that keeps failing for longer than RebalanceTimeout gets this member dropped from the
// group, another member takes the partitions over, and the commit here fails. A handler that must
// apply each record once keeps its own offsets in the same transaction as its writes.
type BatchConsumer struct {
	// c holds the client, group, logger and backoff settings; its Handler is unused.
	c   *Consumer
	cfg BatchConsumerConfig
}

// NewBatchConsumer checks cfg, fills in defaults and creates the client. It does not connect.
func NewBatchConsumer(cfg BatchConsumerConfig) (*BatchConsumer, error) {
	if cfg.Group == "" || len(cfg.Topics) == 0 || cfg.Handler == nil || cfg.Logger == nil {
		return nil, errors.New("kafka batch consumer needs a group, topics, a handler and a logger")
	}
	if cfg.MaxBatchRecords <= 0 {
		cfg.MaxBatchRecords = DefaultMaxBatchRecords
	}
	if cfg.MaxBatchWait <= 0 {
		cfg.MaxBatchWait = DefaultMaxBatchWait
	}
	c, err := newConsumer(ConsumerConfig{
		Brokers:          cfg.Brokers,
		ClientID:         cfg.ClientID,
		Group:            cfg.Group,
		Topics:           cfg.Topics,
		Logger:           cfg.Logger,
		BackoffBase:      cfg.BackoffBase,
		BackoffMax:       cfg.BackoffMax,
		BlockRebalance:   true,
		SessionTimeout:   cfg.SessionTimeout,
		RebalanceTimeout: cfg.RebalanceTimeout,
		opts:             cfg.opts,
	})
	if err != nil {
		return nil, err
	}
	return &BatchConsumer{c: c, cfg: cfg}, nil
}

// Run consumes until ctx is canceled, then returns nil, or until a batch cannot be settled
// (dead-letter produce or commit failed), then returns that error with the batch uncommitted.
// Either way it leaves the group and closes the client; a BatchConsumer runs once.
func (b *BatchConsumer) Run(ctx context.Context) error {
	defer b.c.cl.CloseAllowingRebalance()
	for {
		batch := b.collect(ctx)
		if batch == nil {
			return nil
		}
		err := b.settle(ctx, batch)
		b.c.cl.AllowRebalance()
		if errors.Is(err, errStopped) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// collect polls until the batch is full or MaxBatchWait has passed since its first record. It
// returns nil when ctx is canceled.
func (b *BatchConsumer) collect(ctx context.Context) *Batch {
	batch := &Batch{}
	pctx := ctx
	for len(batch.Records) < b.cfg.MaxBatchRecords {
		fetches := b.c.cl.PollRecords(pctx, b.cfg.MaxBatchRecords-len(batch.Records))
		if ctx.Err() != nil {
			return nil
		}
		for _, fe := range fetches.Errors() {
			if errors.Is(fe.Err, context.DeadlineExceeded) {
				continue // MaxBatchWait passed
			}
			// Injected errors are informational; the client keeps retrying underneath.
			b.c.cfg.Logger.LogAttrs(ctx, slog.LevelWarn, "kafka fetch error",
				slog.String("topic", fe.Topic), slog.Int("partition", int(fe.Partition)), slog.String("error", fe.Err.Error()))
		}
		batch.add(fetches)
		if len(batch.Records) == 0 {
			// Nothing to settle: let a waiting rebalance through before polling again.
			b.c.cl.AllowRebalance()
			continue
		}
		if pctx.Err() != nil {
			break
		}
		if pctx == ctx {
			var cancel context.CancelFunc
			pctx, cancel = context.WithTimeout(ctx, b.cfg.MaxBatchWait)
			defer cancel()
		}
	}
	return batch
}

// settle runs the handler on batch until it succeeds, sends the records it rejected to the
// dead-letter topic, and commits the batch.
func (b *BatchConsumer) settle(ctx context.Context, batch *Batch) error {
	for n := 1; ; n++ {
		rejected, err := b.cfg.Handler(ctx, batch)
		if err == nil {
			for _, rj := range rejected {
				cause := rj.Err
				if cause == nil {
					cause = errors.New("rejected by handler")
				}
				if err := b.c.deadLetter(ctx, rj.Record, ReasonPermanent, cause); err != nil {
					return err
				}
				b.c.cfg.Logger.LogAttrs(ctx, slog.LevelWarn, "kafka record sent to dead-letter topic",
					recordAttrs(rj.Record, slog.String("reason", ReasonPermanent), slog.String("error", cause.Error()))...)
			}
			return b.commit(ctx, batch)
		}
		if ctx.Err() != nil {
			return errStopped
		}
		wait := b.c.backoff(n)
		b.c.cfg.Logger.LogAttrs(ctx, slog.LevelWarn, "kafka batch handler failed, retrying",
			slog.Int("records", len(batch.Records)), slog.Int("attempt", n), slog.Duration("backoff", wait),
			slog.String("error", err.Error()))
		if !sleep(ctx, wait) {
			return errStopped
		}
	}
}

// commit commits the highest offset of every partition in batch, and no other partition.
func (b *BatchConsumer) commit(ctx context.Context, batch *Batch) error {
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), commitTimeout)
	defer cancel()
	if err := b.c.cl.CommitRecords(cctx, batch.Records...); err != nil {
		return fmt.Errorf("commit batch of %d records: %w", len(batch.Records), err)
	}
	return nil
}

// EndOffsets asks the leaders of tps for their current end offsets: the offset the next record
// written to each partition will get (Kafka ListOffsets, timestamp -1). Unlike a fetch's high
// watermark the answer is current, so an offset already read that lies beyond it means the topic
// was recreated.
func EndOffsets(ctx context.Context, cl *kgo.Client, tps ...TopicPartition) (map[TopicPartition]int64, error) {
	req := kmsg.NewPtrListOffsetsRequest()
	topicIdx := make(map[string]int)
	for _, tp := range tps {
		i, ok := topicIdx[tp.Topic]
		if !ok {
			t := kmsg.NewListOffsetsRequestTopic()
			t.Topic = tp.Topic
			req.Topics = append(req.Topics, t)
			i = len(req.Topics) - 1
			topicIdx[tp.Topic] = i
		}
		p := kmsg.NewListOffsetsRequestTopicPartition()
		p.Partition = tp.Partition
		p.Timestamp = -1 // latest
		req.Topics[i].Partitions = append(req.Topics[i].Partitions, p)
	}
	resp, err := req.RequestWith(ctx, cl)
	if err != nil {
		return nil, fmt.Errorf("list end offsets: %w", err)
	}
	out := make(map[TopicPartition]int64, len(tps))
	for _, t := range resp.Topics {
		for _, p := range t.Partitions {
			if err := kerr.ErrorForCode(p.ErrorCode); err != nil {
				return nil, fmt.Errorf("list end offset of %s/%d: %w", t.Topic, p.Partition, err)
			}
			out[TopicPartition{Topic: t.Topic, Partition: p.Partition}] = p.Offset
		}
	}
	for _, tp := range tps {
		if _, ok := out[tp]; !ok {
			return nil, fmt.Errorf("list end offset of %s/%d: partition missing from the response", tp.Topic, tp.Partition)
		}
	}
	return out, nil
}
