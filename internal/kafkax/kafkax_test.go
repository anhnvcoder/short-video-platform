package kafkax

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
)

const (
	validTP      = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	validTraceID = "4bf92f3577b34da6a3ce929d0e0e4736"
	// offsetCommitKey is the Kafka API key of OffsetCommit (kmsg.OffsetCommit).
	offsetCommitKey = 8
	// joinGroupKey is the Kafka API key of JoinGroup (kmsg.JoinGroup).
	joinGroupKey = 11
)

// lockedBuffer collects log output written from consumer goroutines.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// records returns the decoded JSON log lines whose msg is msg.
func (b *lockedBuffer) records(t *testing.T, msg string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for line := range strings.SplitSeq(strings.TrimSpace(b.String()), "\n") {
		if line == "" {
			continue
		}
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("log line %q is not JSON: %v", line, err)
		}
		if rec["msg"] == msg {
			out = append(out, rec)
		}
	}
	return out
}

func newLogger() (*slog.Logger, *lockedBuffer) {
	logs := &lockedBuffer{}
	return slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil))), logs
}

// cluster starts an in-memory Kafka with topics of the given partition count and returns its
// broker list.
func cluster(t *testing.T, partitions int32, topics ...string) string {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(partitions, topics...))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return strings.Join(c.ListenAddrs(), ",")
}

func producer(t *testing.T, brokers string) *kgo.Client {
	t.Helper()
	cl, err := NewClient(brokers, "test-producer")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	return cl
}

func produce(t *testing.T, cl *kgo.Client, rs ...*kgo.Record) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	if err := Produce(ctx, cl, rs...); err != nil {
		t.Fatal(err)
	}
}

// running is a consumer started in the background.
type running struct {
	cancel context.CancelFunc
	// finished is closed when Run returns; err is its result.
	finished chan struct{}
	err      error
}

// stop cancels the consumer and returns Run's result.
func (r *running) stop(t *testing.T) error {
	t.Helper()
	r.cancel()
	return r.wait(t)
}

func (r *running) wait(t *testing.T) error {
	t.Helper()
	select {
	case <-r.finished:
		return r.err
	case <-time.After(30 * time.Second):
		t.Fatal("consumer did not return")
		return nil
	}
}

// start runs a consumer for cfg; the zero fields get fast test values.
func start(t *testing.T, cfg ConsumerConfig) *running {
	t.Helper()
	if cfg.ClientID == "" {
		cfg.ClientID = "test-consumer"
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.New(slog.DiscardHandler)
	}
	if cfg.BackoffBase == 0 {
		cfg.BackoffBase = time.Millisecond
	}
	if cfg.BackoffMax == 0 {
		cfg.BackoffMax = 5 * time.Millisecond
	}
	cfg.opts = append(cfg.opts, kgo.FetchMaxWait(100*time.Millisecond))
	c, err := NewConsumer(cfg)
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
			t.Error("consumer did not stop")
		}
	})
	return r
}

// nextInGroup joins group with a fresh client and returns the first record it is given: the
// record after the group's committed offset on a one-partition topic.
func nextInGroup(t *testing.T, brokers, group, topic string) *kgo.Record {
	t.Helper()
	cl, err := NewClient(brokers, "test-checker", kgo.ConsumerGroup(group), kgo.ConsumeTopics(topic),
		kgo.DisableAutoCommit(), kgo.FetchMaxWait(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	return pollOne(t, cl)
}

func pollOne(t *testing.T, cl *kgo.Client) *kgo.Record {
	t.Helper()
	rs := pollN(t, cl, 1, 15*time.Second)
	if len(rs) == 0 {
		t.Fatal("no record polled")
	}
	return rs[0]
}

// pollN polls cl until it has n records or wait passes, and returns what it got.
func pollN(t *testing.T, cl *kgo.Client, n int, wait time.Duration) []*kgo.Record {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), wait)
	defer cancel()
	var out []*kgo.Record
	for len(out) < n && ctx.Err() == nil {
		out = append(out, cl.PollFetches(ctx).Records()...)
	}
	return out
}

// readTopic reads a topic from the start without a group.
func readTopic(t *testing.T, brokers, topic string, n int, wait time.Duration) []*kgo.Record {
	t.Helper()
	cl, err := NewClient(brokers, "test-reader", kgo.ConsumeTopics(topic), kgo.FetchMaxWait(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	return pollN(t, cl, n, wait)
}

func headerMap(r *kgo.Record) map[string]string {
	m := make(map[string]string, len(r.Headers))
	for _, h := range r.Headers {
		m[h.Key] = string(h.Value)
	}
	return m
}

// commitCounter counts OffsetCommit requests the client writes.
type commitCounter struct{ n atomic.Int32 }

func (c *commitCounter) OnBrokerWrite(_ kgo.BrokerMetadata, key int16, _ int, _, _ time.Duration, err error) {
	if key == offsetCommitKey && err == nil {
		c.n.Add(1)
	}
}

// joinCounter counts JoinGroup requests the client writes.
type joinCounter struct{ n atomic.Int32 }

func (c *joinCounter) OnBrokerWrite(_ kgo.BrokerMetadata, key int16, _ int, _, _ time.Duration, err error) {
	if key == joinGroupKey && err == nil {
		c.n.Add(1)
	}
}

func waitFor(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(20 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

func TestNewClientEmptyBrokers(t *testing.T) {
	for _, brokers := range []string{"", " , ,"} {
		if _, err := NewClient(brokers, "svc"); err == nil {
			t.Errorf("NewClient(%q) = nil error, want an error", brokers)
		}
	}
}

func TestNewConsumerRequiresFields(t *testing.T) {
	ok := ConsumerConfig{Brokers: "127.0.0.1:1", Group: "g", Topics: []string{"t"},
		Handler: func(context.Context, *kgo.Record, Attempt) error { return nil }, Logger: slog.New(slog.DiscardHandler)}
	tests := map[string]func(*ConsumerConfig){
		"no group":   func(c *ConsumerConfig) { c.Group = "" },
		"no topics":  func(c *ConsumerConfig) { c.Topics = nil },
		"no handler": func(c *ConsumerConfig) { c.Handler = nil },
		"no logger":  func(c *ConsumerConfig) { c.Logger = nil },
		"no brokers": func(c *ConsumerConfig) { c.Brokers = "" },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			cfg := ok
			mutate(&cfg)
			if _, err := NewConsumer(cfg); err == nil {
				t.Error("NewConsumer() = nil error, want an error")
			}
		})
	}
}

func TestPermanent(t *testing.T) {
	if Permanent(nil) != nil {
		t.Error("Permanent(nil) != nil")
	}
	base := errors.New("bad event")
	err := fmt.Errorf("handle: %w", Permanent(base))
	var pe *permanentError
	if !errors.As(err, &pe) {
		t.Error("wrapped Permanent error is not found by errors.As")
	}
	if !errors.Is(err, base) {
		t.Error("Permanent hides the wrapped error from errors.Is")
	}
	if err.Error() != "handle: bad event" {
		t.Errorf("Error() = %q", err.Error())
	}
}

func TestBackoff(t *testing.T) {
	c := &Consumer{cfg: ConsumerConfig{BackoffBase: DefaultBackoffBase, BackoffMax: DefaultBackoffMax}}
	want := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 10 * time.Second, 10 * time.Second}
	for i, ceil := range want {
		n := i + 1
		for range 200 {
			got := c.backoff(n)
			if got < ceil/2 || got > ceil {
				t.Fatalf("backoff(%d) = %v, want within [%v, %v]", n, got, ceil/2, ceil)
			}
		}
	}
}

func TestProduceTraceparent(t *testing.T) {
	brokers := cluster(t, 1, "out")
	cl := producer(t, brokers)
	ctx := traceparent.NewContext(t.Context(), validTP)
	const other = "00-11111111111111111111111111111111-2222222222222222-01"

	produce(t, cl, &kgo.Record{Topic: "out", Value: []byte("plain")})
	if err := Produce(ctx, cl,
		&kgo.Record{Topic: "out", Value: []byte("from ctx")},
		&kgo.Record{Topic: "out", Value: []byte("own"), Headers: []kgo.RecordHeader{{Key: "traceparent", Value: []byte(other)}}},
	); err != nil {
		t.Fatal(err)
	}

	rs := readTopic(t, brokers, "out", 3, 15*time.Second)
	if len(rs) != 3 {
		t.Fatalf("read %d records, want 3", len(rs))
	}
	want := map[string][]string{"plain": nil, "from ctx": {validTP}, "own": {other}}
	for _, r := range rs {
		var got []string
		for _, h := range r.Headers {
			if h.Key == "traceparent" {
				got = append(got, string(h.Value))
			}
		}
		if fmt.Sprint(got) != fmt.Sprint(want[string(r.Value)]) {
			t.Errorf("record %q traceparent headers = %v, want %v", r.Value, got, want[string(r.Value)])
		}
	}
}

func TestProduceError(t *testing.T) {
	brokers := cluster(t, 1, "out")
	cl := producer(t, brokers)
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	err := Produce(ctx, cl, &kgo.Record{Topic: "out", Value: []byte("ok")}, &kgo.Record{Topic: "missing", Value: []byte("x")})
	if err == nil {
		t.Fatal("Produce() to a missing topic = nil, want an error")
	}
}

func TestRetryThenSuccess(t *testing.T) {
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("v")})

	var (
		attempts []Attempt
		mu       sync.Mutex
		done     = make(chan struct{})
		commits  commitCounter
	)
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		opts: []kgo.Opt{kgo.WithHooks(&commits)},
		Handler: func(_ context.Context, _ *kgo.Record, a Attempt) error {
			mu.Lock()
			defer mu.Unlock()
			attempts = append(attempts, a)
			if a.Number < 3 {
				return errors.New("transient")
			}
			close(done)
			return nil
		}})
	waitFor(t, done, "third attempt")
	// The commit follows the handler; give it a moment before stopping.
	time.Sleep(500 * time.Millisecond)
	if err := r.stop(t); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}

	mu.Lock()
	got := fmt.Sprint(attempts)
	mu.Unlock()
	if want := fmt.Sprint([]Attempt{{1, false}, {2, false}, {3, false}}); got != want {
		t.Errorf("attempts = %s, want %s", got, want)
	}
	if n := commits.n.Load(); n != 1 {
		t.Errorf("offset commits = %d, want 1", n)
	}
	if rs := readTopic(t, brokers, "in.dlq", 1, time.Second); len(rs) != 0 {
		t.Errorf("dead-letter topic has %d records, want 0", len(rs))
	}
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("sentinel")})
	if next := nextInGroup(t, brokers, "g", "in"); string(next.Value) != "sentinel" {
		t.Errorf("next record for the group = %q, want the sentinel (handled record committed)", next.Value)
	}
}

func TestRetriesExhaustedGoesToDLQ(t *testing.T) {
	brokers := cluster(t, 1, "in", "in.dlq")
	logger, logs := newLogger()
	produce(t, producer(t, brokers),
		&kgo.Record{Topic: "in", Key: []byte("k1"), Value: []byte("secret-value"), Headers: []kgo.RecordHeader{{Key: "event-type", Value: []byte("x")}}},
		&kgo.Record{Topic: "in", Key: []byte("k2"), Value: []byte("next")},
	)

	var (
		calls    []Attempt
		mu       sync.Mutex
		nextDone = make(chan struct{})
	)
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, Logger: logger,
		Handler: func(_ context.Context, rec *kgo.Record, a Attempt) error {
			if string(rec.Value) == "next" {
				close(nextDone)
				return nil
			}
			mu.Lock()
			defer mu.Unlock()
			calls = append(calls, a)
			return errors.New("storage timeout")
		}})
	waitFor(t, nextDone, "the next record")
	time.Sleep(500 * time.Millisecond)
	if err := r.stop(t); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}

	mu.Lock()
	got := fmt.Sprint(calls)
	mu.Unlock()
	if want := fmt.Sprint([]Attempt{{1, false}, {2, false}, {3, false}, {4, false}, {5, true}}); got != want {
		t.Errorf("attempts = %s, want %s", got, want)
	}

	dlq := readTopic(t, brokers, "in.dlq", 2, 3*time.Second)
	if len(dlq) != 1 {
		t.Fatalf("dead-letter topic has %d records, want 1", len(dlq))
	}
	d := dlq[0]
	if string(d.Key) != "k1" || string(d.Value) != "secret-value" {
		t.Errorf("dead-letter record key/value = %q/%q, want the original", d.Key, d.Value)
	}
	h := headerMap(d)
	want := map[string]string{"event-type": "x", "dlq-reason": "retries-exhausted", "dlq-error": "storage timeout",
		"dlq-topic": "in", "dlq-partition": "0", "dlq-offset": "0"}
	for k, v := range want {
		if h[k] != v {
			t.Errorf("dead-letter header %s = %q, want %q", k, h[k], v)
		}
	}

	recs := logs.records(t, "kafka record sent to dead-letter topic")
	if len(recs) != 1 {
		t.Fatalf("got %d dead-letter log lines, want 1", len(recs))
	}
	rec := recs[0]
	if rec["level"] != "WARN" || rec["topic"] != "in" || rec["partition"] != 0.0 || rec["offset"] != 0.0 || rec["reason"] != "retries-exhausted" {
		t.Errorf("dead-letter log = %v", rec)
	}
	if strings.Contains(logs.String(), "secret-value") {
		t.Error("log contains the record value")
	}

	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("sentinel")})
	if next := nextInGroup(t, brokers, "g", "in"); string(next.Value) != "sentinel" {
		t.Errorf("next record for the group = %q, want the sentinel (both records committed)", next.Value)
	}
}

func TestPermanentGoesToDLQAtOnce(t *testing.T) {
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})

	var calls atomic.Int32
	start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(context.Context, *kgo.Record, Attempt) error {
			calls.Add(1)
			return fmt.Errorf("decode: %w", Permanent(errors.New("missing video_id")))
		}})

	dlq := readTopic(t, brokers, "in.dlq", 1, 15*time.Second)
	if len(dlq) != 1 {
		t.Fatalf("dead-letter topic has %d records, want 1", len(dlq))
	}
	if h := headerMap(dlq[0]); h["dlq-reason"] != "permanent" || h["dlq-error"] != "decode: missing video_id" {
		t.Errorf("dead-letter headers = %v, want reason permanent and the error", h)
	}
	if n := calls.Load(); n != 1 {
		t.Errorf("handler calls = %d, want 1", n)
	}
}

func TestStopLeavesInFlightRecordUncommitted(t *testing.T) {
	tests := []struct {
		name    string
		backoff time.Duration
		handler func(started chan<- struct{}) Handler
	}{
		{
			name: "during handler",
			handler: func(started chan<- struct{}) Handler {
				return func(ctx context.Context, _ *kgo.Record, _ Attempt) error {
					close(started)
					<-ctx.Done()
					return ctx.Err()
				}
			},
		},
		{
			name:    "during backoff",
			backoff: time.Hour,
			handler: func(started chan<- struct{}) Handler {
				return func(context.Context, *kgo.Record, Attempt) error {
					close(started)
					return errors.New("transient")
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			brokers := cluster(t, 1, "in", "in.dlq")
			produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job")})

			started := make(chan struct{})
			r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
				BackoffBase: tt.backoff, BackoffMax: tt.backoff, Handler: tt.handler(started)})
			waitFor(t, started, "the handler")
			time.Sleep(100 * time.Millisecond)
			if err := r.stop(t); err != nil {
				t.Fatalf("Run() = %v, want nil on stop", err)
			}

			if next := nextInGroup(t, brokers, "g", "in"); string(next.Value) != "job" {
				t.Errorf("next record for the group = %q, want the interrupted job again", next.Value)
			}
			if rs := readTopic(t, brokers, "in.dlq", 1, time.Second); len(rs) != 0 {
				t.Errorf("dead-letter topic has %d records, want 0", len(rs))
			}
		})
	}
}

func TestDLQProduceFailureStopsWithoutCommit(t *testing.T) {
	brokers := cluster(t, 1, "in") // no in.dlq
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})

	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(context.Context, *kgo.Record, Attempt) error { return Permanent(errors.New("bad")) }})
	err := r.wait(t)
	if err == nil || !strings.Contains(err.Error(), "dead-letter topic in.dlq") {
		t.Fatalf("Run() = %v, want a dead-letter produce error", err)
	}
	if next := nextInGroup(t, brokers, "g", "in"); string(next.Value) != "bad" {
		t.Errorf("next record for the group = %q, want the record that failed to dead-letter", next.Value)
	}
}

func TestTraceparentHeader(t *testing.T) {
	brokers := cluster(t, 1, "in", "in.dlq", "out")
	logger, logs := newLogger()
	prod := producer(t, brokers)
	produce(t, prod,
		&kgo.Record{Topic: "in", Value: []byte("bad"), Headers: []kgo.RecordHeader{{Key: "traceparent", Value: []byte("00-zzzz-00f067aa0ba902b7-01")}}},
		&kgo.Record{Topic: "in", Value: []byte("good"), Headers: []kgo.RecordHeader{{Key: "traceparent", Value: []byte(validTP)}}},
	)

	done := make(chan struct{})
	start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"}, Logger: logger,
		Handler: func(ctx context.Context, r *kgo.Record, _ Attempt) error {
			logger.InfoContext(ctx, "probe", slog.String("value", string(r.Value)))
			if string(r.Value) == "bad" {
				if v, ok := traceparent.FromContext(ctx); ok {
					t.Errorf("malformed header put traceparent %q in ctx", v)
				}
				return nil
			}
			defer close(done)
			return Produce(ctx, prod, &kgo.Record{Topic: "out", Value: []byte("follow-up")})
		}})
	waitFor(t, done, "the valid record")

	for _, rec := range logs.records(t, "probe") {
		id, has := rec["trace_id"]
		switch rec["value"] {
		case "bad":
			if has {
				t.Errorf("malformed header: trace_id = %v, want none", id)
			}
		case "good":
			if id != validTraceID {
				t.Errorf("valid header: trace_id = %v, want %s", id, validTraceID)
			}
		}
	}
	out := readTopic(t, brokers, "out", 1, 15*time.Second)
	if len(out) != 1 || headerMap(out[0])["traceparent"] != validTP {
		t.Fatalf("follow-up record = %v, want traceparent %s", out, validTP)
	}
}

func TestOrderWithinPartition(t *testing.T) {
	brokers := cluster(t, 3, "in", "in.dlq")
	const perKey = 30
	keys := []string{"a", "b", "c", "d"}
	var rs []*kgo.Record
	for i := range perKey {
		for _, k := range keys {
			rs = append(rs, &kgo.Record{Topic: "in", Key: []byte(k), Value: []byte(fmt.Sprintf("%s-%03d", k, i))})
		}
	}
	produce(t, producer(t, brokers), rs...)

	var (
		mu      sync.Mutex
		seen    = map[string][]string{}
		offsets = map[int32][]int64{}
		total   int
		done    = make(chan struct{})
		failed  = map[string]bool{}
	)
	start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(_ context.Context, r *kgo.Record, _ Attempt) error {
			mu.Lock()
			defer mu.Unlock()
			// Every fifth record fails once; the retry must not reorder anything.
			if v := string(r.Value); strings.HasSuffix(v, "5") && !failed[v] {
				failed[v] = true
				return errors.New("transient")
			}
			seen[string(r.Key)] = append(seen[string(r.Key)], string(r.Value))
			offsets[r.Partition] = append(offsets[r.Partition], r.Offset)
			if total++; total == len(rs) {
				close(done)
			}
			return nil
		}})
	waitFor(t, done, "every record")

	mu.Lock()
	defer mu.Unlock()
	for p, offs := range offsets {
		for i := 1; i < len(offs); i++ {
			if offs[i] != offs[i-1]+1 {
				t.Fatalf("partition %d offsets out of order: %v", p, offs)
			}
		}
	}
	for _, k := range keys {
		for i, v := range seen[k] {
			if want := fmt.Sprintf("%s-%03d", k, i); v != want {
				t.Fatalf("key %s record %d = %s, want %s", k, i, v, want)
			}
		}
	}
}

// TestLongHandlerKeepsCommit runs a handler for longer than the default session and rebalance
// timeouts, with rebalances blocked during the poll as media-worker runs: background heartbeats
// keep the member in the group, so the commit after the handler succeeds.
func TestLongHandlerKeepsCommit(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("long job")}, &kgo.Record{Topic: "in", Value: []byte("next")})

	const jobTime = 65 * time.Second
	var commits commitCounter
	nextDone := make(chan struct{})
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		MaxPollRecords: 1, BlockRebalance: true, opts: []kgo.Opt{kgo.WithHooks(&commits)},
		Handler: func(ctx context.Context, rec *kgo.Record, _ Attempt) error {
			if string(rec.Value) == "next" {
				close(nextDone)
				return nil
			}
			if !sleep(ctx, jobTime) {
				return ctx.Err()
			}
			return nil
		}})
	select {
	case <-nextDone:
	case <-time.After(jobTime + 30*time.Second):
		t.Fatal("the record after the long job was not handled")
	}
	time.Sleep(500 * time.Millisecond)
	if err := r.stop(t); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if n := commits.n.Load(); n != 2 {
		t.Errorf("offset commits = %d, want 2", n)
	}
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("sentinel")})
	if next := nextInGroup(t, brokers, "g", "in"); string(next.Value) != "sentinel" {
		t.Errorf("next record for the group = %q, want the sentinel (long job committed)", next.Value)
	}
}

// TestRebalanceWaitsForBlockedHandler has a second member join the group while a handler runs
// with rebalances blocked, as media-worker runs (default cooperative-sticky balancer): the first
// member gives a partition up only after the handler returned and its commit landed, so the
// record is handled once and the second member is assigned only afterwards.
func TestRebalanceWaitsForBlockedHandler(t *testing.T) {
	t.Parallel()
	brokers := cluster(t, 2, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job")})

	var (
		mu     sync.Mutex
		events []string
	)
	note := func(e string) {
		mu.Lock()
		defer mu.Unlock()
		events = append(events, e)
	}
	noted := func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), events...)
	}
	handler := func(member string, started, release chan struct{}) Handler {
		return func(ctx context.Context, rec *kgo.Record, _ Attempt) error {
			note(member + " handles " + string(rec.Value))
			if started != nil {
				close(started)
				select {
				case <-release:
				case <-ctx.Done():
					return ctx.Err()
				}
				note(member + " done " + string(rec.Value))
			}
			return nil
		}
	}

	var commitsA commitCounter
	commitsAtRevoke := make(chan int32, 1)
	started, release := make(chan struct{}), make(chan struct{})
	a := start(t, ConsumerConfig{Brokers: brokers, ClientID: "member-a", Group: "g", Topics: []string{"in"},
		MaxPollRecords: 1, BlockRebalance: true, Handler: handler("a", started, release),
		opts: []kgo.Opt{
			kgo.HeartbeatInterval(100 * time.Millisecond),
			kgo.WithHooks(&commitsA),
			kgo.OnPartitionsRevoked(func(_ context.Context, _ *kgo.Client, revoked map[string][]int32) {
				if len(revoked["in"]) > 0 {
					note("a revoked")
					select {
					case commitsAtRevoke <- commitsA.n.Load():
					default:
					}
				}
			}),
		}})
	waitFor(t, started, "member a's handler")

	var joinsB joinCounter
	assignedB := make(chan struct{})
	b := start(t, ConsumerConfig{Brokers: brokers, ClientID: "member-b", Group: "g", Topics: []string{"in"},
		MaxPollRecords: 1, BlockRebalance: true, Handler: handler("b", nil, nil),
		opts: []kgo.Opt{
			kgo.HeartbeatInterval(100 * time.Millisecond),
			kgo.WithHooks(&joinsB),
			kgo.OnPartitionsAssigned(func(_ context.Context, _ *kgo.Client, assigned map[string][]int32) {
				if len(assigned["in"]) > 0 {
					note("b assigned")
					close(assignedB)
				}
			}),
		}})

	// Member b has asked to join; give member a many heartbeats to see the rebalance.
	deadline := time.Now().Add(15 * time.Second)
	for joinsB.n.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if joinsB.n.Load() == 0 {
		t.Fatal("member b never sent JoinGroup")
	}
	time.Sleep(time.Second)
	if got := noted(); fmt.Sprint(got) != fmt.Sprint([]string{"a handles job"}) {
		t.Fatalf("events while the handler runs = %q, want only the handler start (rebalance held)", got)
	}

	close(release)
	waitFor(t, assignedB, "member b's assignment")
	select {
	case n := <-commitsAtRevoke:
		if n < 1 {
			t.Errorf("offset commits when member a gave a partition up = %d, want the job committed first", n)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("member a never gave a partition up")
	}
	got := noted()
	if fmt.Sprint(got[:3]) != fmt.Sprint([]string{"a handles job", "a done job", "a revoked"}) {
		t.Errorf("events = %q, want the handler to finish before member a gives a partition up", got)
	}
	time.Sleep(500 * time.Millisecond)
	if err := a.stop(t); err != nil {
		t.Fatalf("member a Run() = %v, want nil", err)
	}
	if err := b.stop(t); err != nil {
		t.Fatalf("member b Run() = %v, want nil", err)
	}
	for _, e := range noted() {
		if e == "b handles job" {
			t.Errorf("events = %q: the job was delivered again", noted())
		}
	}

	cl, err := NewClient(brokers, "test-checker", kgo.ConsumerGroup("g"), kgo.ConsumeTopics("in"),
		kgo.DisableAutoCommit(), kgo.FetchMaxWait(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	if rs := pollN(t, cl, 1, 3*time.Second); len(rs) != 0 {
		t.Errorf("group still has %q to deliver, want the job committed", rs[0].Value)
	}
}
