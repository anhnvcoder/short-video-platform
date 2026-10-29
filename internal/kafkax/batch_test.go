package kafkax

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
)

// startBatch runs a batch consumer for cfg; the zero fields get fast test values.
func startBatch(t *testing.T, cfg BatchConsumerConfig) *running {
	t.Helper()
	if cfg.ClientID == "" {
		cfg.ClientID = "test-batch-consumer"
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.DiscardHandler)
	}
	if cfg.MaxBatchWait == 0 {
		cfg.MaxBatchWait = 200 * time.Millisecond
	}
	if cfg.BackoffBase == 0 {
		cfg.BackoffBase = time.Millisecond
	}
	if cfg.BackoffMax == 0 {
		cfg.BackoffMax = 5 * time.Millisecond
	}
	cfg.opts = append(cfg.opts, kgo.FetchMaxWait(100*time.Millisecond))
	c, err := NewBatchConsumer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &running{cancel: cancel, finished: make(chan struct{})}
	go func() {
		r.err = c.Run(ctx)
		close(r.finished)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-r.finished:
		case <-time.After(30 * time.Second):
			t.Error("batch consumer did not stop")
		}
	})
	return r
}

// manualProducer writes each record to the partition set on it.
func manualProducer(t *testing.T, brokers string) *kgo.Client {
	t.Helper()
	cl, err := NewClient(brokers, "test-producer", kgo.RecordPartitioner(kgo.ManualPartitioner()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	return cl
}

// batchCalls records what a BatchHandler is given, one entry per call.
type batchCalls struct {
	mu    sync.Mutex
	calls []*Batch
}

func (c *batchCalls) add(b *Batch) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls = append(c.calls, b)
	return len(c.calls)
}

func (c *batchCalls) get() []*Batch {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]*Batch(nil), c.calls...)
}

// positions lists the records of b as "partition/offset:value".
func positions(b *Batch) []string {
	out := make([]string, 0, len(b.Records))
	for _, r := range b.Records {
		out = append(out, fmt.Sprintf("%d/%d:%s", r.Partition, r.Offset, r.Value))
	}
	return out
}

// firstPolled records when the consumer first hands a record out of its buffer, then closes ch.
// franz-go runs this hook on the polling goroutine before PollRecords returns, so at is no later
// than the moment the consumer starts the MaxBatchWait timer for that record.
type firstPolled struct {
	once sync.Once
	at   time.Time
	ch   chan struct{}
}

func newFirstPolled() *firstPolled { return &firstPolled{ch: make(chan struct{})} }

func (h *firstPolled) OnFetchRecordUnbuffered(_ *kgo.Record, polled bool) {
	if polled {
		h.once.Do(func() {
			h.at = time.Now()
			close(h.ch)
		})
	}
}

// committed returns the offsets group has committed, by partition.
func committed(t *testing.T, brokers, group string) map[TopicPartition]int64 {
	t.Helper()
	cl, err := NewClient(brokers, "test-offsets")
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	req := kmsg.NewPtrOffsetFetchRequest()
	req.Group = group
	resp, err := req.RequestWith(ctx, cl)
	if err != nil {
		t.Fatal(err)
	}
	if err := kerr.ErrorForCode(resp.ErrorCode); err != nil {
		t.Fatal(err)
	}
	out := map[TopicPartition]int64{}
	for _, tp := range resp.Topics {
		for _, p := range tp.Partitions {
			if p.Offset >= 0 {
				out[TopicPartition{Topic: tp.Topic, Partition: p.Partition}] = p.Offset
			}
		}
	}
	return out
}

func TestNewBatchConsumerRequiresFields(t *testing.T) {
	ok := BatchConsumerConfig{Brokers: "127.0.0.1:1", Group: "g", Topics: []string{"t"},
		Handler: func(context.Context, *Batch) ([]Rejected, error) { return nil, nil }, Logger: slog.New(slog.DiscardHandler)}
	tests := map[string]func(*BatchConsumerConfig){
		"no group":   func(c *BatchConsumerConfig) { c.Group = "" },
		"no topics":  func(c *BatchConsumerConfig) { c.Topics = nil },
		"no handler": func(c *BatchConsumerConfig) { c.Handler = nil },
		"no logger":  func(c *BatchConsumerConfig) { c.Logger = nil },
		"no brokers": func(c *BatchConsumerConfig) { c.Brokers = "" },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			cfg := ok
			mutate(&cfg)
			if _, err := NewBatchConsumer(cfg); err == nil {
				t.Error("NewBatchConsumer() = nil error, want an error")
			}
		})
	}
}

// TestBatchSpansPartitionsAndPolls builds one batch from two polls over two of three partitions:
// the handler gets every record in offset order, and the commit covers the highest offset of those
// two partitions only.
func TestBatchSpansPartitionsAndPolls(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 3, "in", "in.dlq")
	prod := manualProducer(t, brokers)
	rec := func(p int32, v string) *kgo.Record { return &kgo.Record{Topic: "in", Partition: p, Value: []byte(v)} }
	produce(t, prod, rec(0, "a0"), rec(0, "a1"), rec(0, "a2"), rec(1, "b0"), rec(1, "b1"))

	var (
		calls   batchCalls
		handled = make(chan struct{})
		commits commitCounter
		polled  = newFirstPolled()
	)
	r := startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		MaxBatchWait: 2 * time.Second, opts: []kgo.Opt{kgo.WithHooks(&commits, polled)},
		Handler: func(_ context.Context, b *Batch) ([]Rejected, error) {
			if calls.add(b) == 1 {
				close(handled)
			}
			return nil, nil
		}})
	waitFor(t, polled.ch, "the first poll")
	produce(t, prod, rec(1, "b2"), rec(1, "b3"))
	waitFor(t, handled, "the batch")
	time.Sleep(300 * time.Millisecond)
	if err := r.stop(t); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}

	got := calls.get()
	if len(got) != 1 {
		t.Fatalf("handler calls = %d, want 1", len(got))
	}
	b := got[0]
	perPartition := map[int32][]string{}
	for _, r := range b.Records {
		perPartition[r.Partition] = append(perPartition[r.Partition], fmt.Sprintf("%d:%s", r.Offset, r.Value))
	}
	want := map[int32][]string{0: {"0:a0", "1:a1", "2:a2"}, 1: {"0:b0", "1:b1", "2:b2", "3:b3"}}
	if fmt.Sprint(perPartition) != fmt.Sprint(want) {
		t.Errorf("batch records by partition = %v, want %v", perPartition, want)
	}
	if n := commits.n.Load(); n != 1 {
		t.Errorf("offset commits = %d, want 1", n)
	}
	wantCommitted := map[TopicPartition]int64{{"in", 0}: 3, {"in", 1}: 4}
	if c := committed(t, brokers, "g"); fmt.Sprint(c) != fmt.Sprint(wantCommitted) {
		t.Errorf("committed offsets = %v, want %v (none for partition 2)", c, wantCommitted)
	}
}

func TestBatchClosesAtMaxBatchRecords(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	var rs []*kgo.Record
	for i := range 10 {
		rs = append(rs, &kgo.Record{Topic: "in", Value: fmt.Appendf(nil, "v%d", i)})
	}
	produce(t, producer(t, brokers), rs...)

	var (
		calls batchCalls
		done  = make(chan struct{})
	)
	startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		MaxBatchRecords: 4, MaxBatchWait: 300 * time.Millisecond,
		Handler: func(_ context.Context, b *Batch) ([]Rejected, error) {
			calls.add(b)
			if b.Records[len(b.Records)-1].Offset == 9 {
				close(done)
			}
			return nil, nil
		}})
	waitFor(t, done, "every record")

	var sizes []int
	for _, b := range calls.get() {
		sizes = append(sizes, len(b.Records))
	}
	if fmt.Sprint(sizes) != fmt.Sprint([]int{4, 4, 2}) {
		t.Errorf("batch sizes = %v, want [4 4 2]", sizes)
	}
}

// TestBatchClosesAfterMaxBatchWait checks a batch smaller than MaxBatchRecords is handled once
// MaxBatchWait has passed since its first record.
func TestBatchClosesAfterMaxBatchWait(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	const wait = 400 * time.Millisecond
	polled := newFirstPolled()
	var handledAt time.Time
	done := make(chan struct{})
	startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		MaxBatchWait: wait, opts: []kgo.Opt{kgo.WithHooks(polled)},
		Handler: func(_ context.Context, b *Batch) ([]Rejected, error) {
			if len(b.Records) != 1 {
				t.Errorf("batch has %d records, want 1", len(b.Records))
			}
			handledAt = time.Now()
			close(done)
			return nil, nil
		}})
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("only")})
	waitFor(t, polled.ch, "the first poll")
	waitFor(t, done, "the batch")

	// Measure from the hook, not from when this goroutine wakes up: under load the wake-up comes
	// after the consumer has already started the MaxBatchWait timer, which shortened the measured
	// wait below the lower bound.
	if d := handledAt.Sub(polled.at); d < wait-50*time.Millisecond || d > 5*time.Second {
		t.Errorf("handler ran %v after the first record was polled, want about %v", d, wait)
	}
}

// TestBatchRetryThenSuccess fails the handler twice: each attempt gets the same records, and the
// batch is committed once.
func TestBatchRetryThenSuccess(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 2, "in", "in.dlq")
	prod := manualProducer(t, brokers)
	produce(t, prod,
		&kgo.Record{Topic: "in", Partition: 0, Value: []byte("x")},
		&kgo.Record{Topic: "in", Partition: 1, Value: []byte("y")},
		&kgo.Record{Topic: "in", Partition: 1, Value: []byte("z")},
	)

	logger, logs := newLogger()
	var (
		calls   batchCalls
		done    = make(chan struct{})
		commits commitCounter
	)
	r := startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, Logger: logger,
		MaxBatchWait: 500 * time.Millisecond, opts: []kgo.Opt{kgo.WithHooks(&commits)},
		Handler: func(_ context.Context, b *Batch) ([]Rejected, error) {
			if calls.add(b) < 3 {
				return nil, errors.New("database unavailable")
			}
			close(done)
			return nil, nil
		}})
	waitFor(t, done, "the third attempt")
	time.Sleep(300 * time.Millisecond)
	if err := r.stop(t); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}

	got := calls.get()
	if len(got) != 3 {
		t.Fatalf("handler calls = %d, want 3", len(got))
	}
	first := positions(got[0])
	if len(first) != 3 {
		t.Fatalf("first attempt records = %v, want all 3", first)
	}
	for i, b := range got[1:] {
		if fmt.Sprint(positions(b)) != fmt.Sprint(first) {
			t.Errorf("attempt %d records = %v, want %v", i+2, positions(b), first)
		}
	}
	if n := commits.n.Load(); n != 1 {
		t.Errorf("offset commits = %d, want 1", n)
	}
	if n := len(logs.records(t, "kafka batch handler failed, retrying")); n != 2 {
		t.Errorf("retry log lines = %d, want 2", n)
	}
	want := map[TopicPartition]int64{{"in", 0}: 1, {"in", 1}: 2}
	if c := committed(t, brokers, "g"); fmt.Sprint(c) != fmt.Sprint(want) {
		t.Errorf("committed offsets = %v, want %v", c, want)
	}
	if rs := readTopic(t, brokers, "in.dlq", 1, 500*time.Millisecond); len(rs) != 0 {
		t.Errorf("dead-letter topic has %d records, want 0", len(rs))
	}
}

// TestBatchRejectedGoesToDLQ rejects one record of three: it alone goes to the dead-letter topic,
// and every offset is committed.
func TestBatchRejectedGoesToDLQ(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers),
		&kgo.Record{Topic: "in", Value: []byte("ok-1")},
		&kgo.Record{Topic: "in", Key: []byte("k"), Value: []byte("bad"), Headers: []kgo.RecordHeader{{Key: "event-type", Value: []byte("x")}}},
		&kgo.Record{Topic: "in", Value: []byte("ok-2")},
	)

	var calls batchCalls
	done := make(chan struct{})
	r := startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(_ context.Context, b *Batch) ([]Rejected, error) {
			calls.add(b)
			var rejected []Rejected
			for _, rec := range b.Records {
				if string(rec.Value) == "bad" {
					rejected = append(rejected, Rejected{Record: rec, Err: errors.New("missing video_id")})
				}
			}
			if b.Records[len(b.Records)-1].Offset == 2 {
				defer close(done)
			}
			return rejected, nil
		}})
	waitFor(t, done, "the last record")
	time.Sleep(300 * time.Millisecond)
	if err := r.stop(t); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}

	dlq := readTopic(t, brokers, "in.dlq", 2, time.Second)
	if len(dlq) != 1 {
		t.Fatalf("dead-letter topic has %d records, want 1", len(dlq))
	}
	d := dlq[0]
	if string(d.Key) != "k" || string(d.Value) != "bad" {
		t.Errorf("dead-letter record key/value = %q/%q, want the original", d.Key, d.Value)
	}
	h := headerMap(d)
	want := map[string]string{"event-type": "x", "dlq-reason": "permanent", "dlq-error": "missing video_id",
		"dlq-topic": "in", "dlq-partition": "0", "dlq-offset": "1", "dlq-group": "g"}
	for k, v := range want {
		if h[k] != v {
			t.Errorf("dead-letter header %s = %q, want %q", k, h[k], v)
		}
	}
	if c := committed(t, brokers, "g"); c[TopicPartition{"in", 0}] != 3 {
		t.Errorf("committed offsets = %v, want in/0 at 3", c)
	}
}

// TestBatchStopLeavesBatchUncommitted stops the consumer at each point before a batch is
// settled: Run returns at once, and a new member of the group gets the records again.
func TestBatchStopLeavesBatchUncommitted(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		backoff time.Duration
		wait    time.Duration
		handler func(started chan<- struct{}) BatchHandler
	}{
		{
			name: "during handler",
			handler: func(started chan<- struct{}) BatchHandler {
				return func(ctx context.Context, _ *Batch) ([]Rejected, error) {
					close(started)
					<-ctx.Done()
					return nil, ctx.Err()
				}
			},
		},
		{
			name:    "during backoff",
			backoff: time.Hour,
			handler: func(started chan<- struct{}) BatchHandler {
				return func(context.Context, *Batch) ([]Rejected, error) {
					close(started)
					return nil, errors.New("transient")
				}
			},
		},
		{
			name: "while collecting",
			wait: time.Hour,
			handler: func(started chan<- struct{}) BatchHandler {
				return func(context.Context, *Batch) ([]Rejected, error) {
					close(started) // the batch closed early
					return nil, nil
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			brokers := cluster(t, 1, "in", "in.dlq")
			produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job-0")}, &kgo.Record{Topic: "in", Value: []byte("job-1")})

			started := make(chan struct{})
			polled := newFirstPolled()
			r := startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
				BackoffBase: tt.backoff, BackoffMax: tt.backoff, MaxBatchWait: tt.wait,
				opts: []kgo.Opt{kgo.WithHooks(polled)}, Handler: tt.handler(started)})
			if tt.wait > 0 {
				waitFor(t, polled.ch, "the first poll")
			} else {
				waitFor(t, started, "the handler")
			}
			time.Sleep(100 * time.Millisecond)
			stopAt := time.Now()
			if err := r.stop(t); err != nil {
				t.Fatalf("Run() = %v, want nil on stop", err)
			}
			if d := time.Since(stopAt); d > 5*time.Second {
				t.Errorf("Run took %v to return after stop", d)
			}
			if tt.wait > 0 {
				select {
				case <-started:
					t.Error("handler ran before MaxBatchWait passed")
				default:
				}
			}

			if c := committed(t, brokers, "g"); len(c) != 0 {
				t.Errorf("committed offsets = %v, want none", c)
			}
			if next := nextInGroup(t, brokers, "g", "in"); string(next.Value) != "job-0" {
				t.Errorf("next record for the group = %q, want job-0 again", next.Value)
			}
		})
	}
}

func TestBatchDLQProduceFailureStopsWithoutCommit(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in") // no in.dlq
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})

	r := startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(_ context.Context, b *Batch) ([]Rejected, error) {
			return []Rejected{{Record: b.Records[0], Err: errors.New("bad")}}, nil
		}})
	err := r.wait(t)
	if err == nil || !strings.Contains(err.Error(), "dead-letter topic in.dlq") {
		t.Fatalf("Run() = %v, want a dead-letter produce error", err)
	}
	if c := committed(t, brokers, "g"); len(c) != 0 {
		t.Errorf("committed offsets = %v, want none", c)
	}
}

func TestEndOffsets(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 3, "a", "b")
	prod := manualProducer(t, brokers)
	produce(t, prod,
		&kgo.Record{Topic: "a", Partition: 0, Value: []byte("1")},
		&kgo.Record{Topic: "a", Partition: 0, Value: []byte("2")},
		&kgo.Record{Topic: "a", Partition: 2, Value: []byte("3")},
		&kgo.Record{Topic: "b", Partition: 1, Value: []byte("4")},
	)

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	got, err := EndOffsets(ctx, producer(t, brokers),
		TopicPartition{"a", 0}, TopicPartition{"a", 1}, TopicPartition{"a", 2}, TopicPartition{"b", 1})
	if err != nil {
		t.Fatal(err)
	}
	want := map[TopicPartition]int64{{"a", 0}: 2, {"a", 1}: 0, {"a", 2}: 1, {"b", 1}: 1}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("EndOffsets() = %v, want %v", got, want)
	}
}
