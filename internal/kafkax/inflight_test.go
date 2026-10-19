package kafkax

// Records already in flight when the broker stops answering (docs/adr/0011-observability-stage3.md,
// section 11): every produce returns at its deadline, its callbacks done, and a dead-letter
// produce that does not get its ack leaves the source record uncommitted.

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// fakeCluster starts an in-memory Kafka with one-partition topics and returns it with its broker
// list.
func fakeCluster(t *testing.T, topics ...string) (*kfake.Cluster, string) {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(1, topics...))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c, strings.Join(c.ListenAddrs(), ",")
}

// holdProduce makes c take every produce request from now on and never acknowledge it. The
// returned channel receives each request as it arrives.
func holdProduce(c *kfake.Cluster) <-chan *kmsg.ProduceRequest {
	got := make(chan *kmsg.ProduceRequest, 100)
	c.ControlKey(int16(kmsg.Produce), func(req kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		select {
		case got <- req.(*kmsg.ProduceRequest):
		default:
		}
		return nil, nil, true
	})
	return got
}

// recordsIn counts the records of the batches req carries.
func recordsIn(t *testing.T, req *kmsg.ProduceRequest) int {
	t.Helper()
	n := 0
	for _, topic := range req.Topics {
		for _, p := range topic.Partitions {
			var batch kmsg.RecordBatch
			if err := batch.ReadFrom(p.Records); err != nil {
				t.Fatal(err)
			}
			n += int(batch.NumRecords)
		}
	}
	return n
}

// requestTimedOut is the answer of a broker that took req but did not get it replicated in time:
// REQUEST_TIMED_OUT for every partition, so whether the records were written is unknown.
func requestTimedOut(req *kmsg.ProduceRequest) *kmsg.ProduceResponse {
	resp := req.ResponseKind().(*kmsg.ProduceResponse)
	for _, rt := range req.Topics {
		st := kmsg.NewProduceResponseTopic()
		st.Topic, st.TopicID = rt.Topic, rt.TopicID
		for _, rp := range rt.Partitions {
			sp := kmsg.NewProduceResponseTopicPartition()
			sp.Partition = rp.Partition
			sp.ErrorCode = kerr.RequestTimedOut.Code
			st.Partitions = append(st.Partitions, sp)
		}
		resp.Topics = append(resp.Topics, st)
	}
	return resp
}

// produceWithin runs Produce in the background and returns its error, failing the test when it
// has not returned after wait.
func produceWithin(t *testing.T, wait time.Duration, ctx context.Context, cl *kgo.Client, rs ...*kgo.Record) error {
	t.Helper()
	result := make(chan error, 1)
	go func() { result <- Produce(ctx, cl, rs...) }()
	select {
	case err := <-result:
		return err
	case <-time.After(wait):
		t.Fatal("produce of a record in flight did not return at its deadline")
		return nil
	}
}

// The broker answers REQUEST_TIMED_OUT, then every retry loses its connection: Produce returns
// the deadline error, within a bound, and the record's span is ended. The bound is past the
// deadline: the client fails a record whose connection died only at its next metadata refresh,
// which franz-go spaces by MetadataMinAge, set to 1 s by NewClient (the franz-go default is 5 s).
func TestProduceRequestTimedOutThenConnectionLost(t *testing.T) {
	recorder, _ := traceTelemetry(t)
	c, brokers := fakeCluster(t, "out")
	var requests atomic.Int32
	lost := make(chan struct{})
	var once sync.Once
	c.ControlKey(int16(kmsg.Produce), func(req kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		if requests.Add(1) == 1 {
			return requestTimedOut(req.(*kmsg.ProduceRequest)), nil, true
		}
		once.Do(func() { close(lost) })
		return nil, errors.New("connection lost"), true // kfake closes the connection
	})
	cl := producer(t, brokers)
	const deadline = time.Second
	ctx, cancel := context.WithTimeout(t.Context(), deadline)
	defer cancel()

	started := time.Now()
	err := produceWithin(t, 30*time.Second, ctx, cl, &kgo.Record{Topic: "out", Value: []byte("v")})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Produce() = %v, want the call's deadline", err)
	}
	if elapsed, limit := time.Since(started), deadline+metadataMinAge+2*time.Second; elapsed > limit {
		t.Errorf("Produce() returned after %v, want at most %v", elapsed, limit)
	}
	select {
	case <-lost:
	default:
		t.Fatalf("the broker got %d produce requests, want a retry after REQUEST_TIMED_OUT", requests.Load())
	}
	if started, ended := len(recorder.Started()), recorder.Ended(); started != 1 || len(ended) != 1 || ended[0].Status().Code != codes.Error {
		t.Errorf("producer spans: %d started, ended %v; want one, ended with an error", started, ended)
	}
}

// A batch of records from three traces is in flight, in one produce request, when its deadline
// passes without an ack: Produce returns the deadline error, every record kept the call's
// deadline, and every record's span ended with the error in its own trace.
func TestProduceBatchOfTracesExpiresInFlight(t *testing.T) {
	recorder, _ := traceTelemetry(t)
	c, brokers := fakeCluster(t, "out")
	// Manual flushing keeps the records buffered until the test flushes, so the three share one
	// request whatever the scheduler does in between.
	cl, err := NewClient(brokers, "test-producer", kgo.ManualFlushing())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	// Once a topic's partitions are known, Produce buffers a record on its partition synchronously.
	// A first produce, acknowledged before the broker starts holding requests, loads them.
	primeCtx, primeCancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer primeCancel()
	var primed sync.WaitGroup
	primed.Add(1)
	var primeErr error
	cl.Produce(primeCtx, &kgo.Record{Topic: "out", Value: []byte("v")}, func(_ *kgo.Record, err error) {
		primeErr = err
		primed.Done()
	})
	if err := cl.Flush(primeCtx); err != nil {
		t.Fatal(err)
	}
	primed.Wait()
	if primeErr != nil {
		t.Fatal(primeErr)
	}
	held := holdProduce(c)
	parents := []string{
		"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
		"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
		"00-5b8aa5a2d2c872e8321cf37308d69df2-051581bf3cb55c13-01",
	}
	rs := make([]*kgo.Record, len(parents))
	for i, tp := range parents {
		rs[i] = &kgo.Record{Topic: "out", Value: []byte("v"),
			Context: propagation.TraceContext{}.Extract(context.Background(), propagation.MapCarrier{"traceparent": tp})}
	}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()

	// Flush only once all three records are buffered; it blocks until they are acknowledged or
	// failed, so it runs in the background and stops with the test.
	go func() {
		for deadline := time.Now().Add(5 * time.Second); cl.BufferedProduceRecords() < int64(len(rs)); {
			if time.Now().After(deadline) {
				return // nothing is flushed, so the test fails below on the missing request
			}
			time.Sleep(time.Millisecond)
		}
		_ = cl.Flush(t.Context())
	}()

	err = produceWithin(t, 10*time.Second, ctx, cl, rs...)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Produce() = %v, want the call's deadline", err)
	}
	select {
	case req := <-held:
		if n := recordsIn(t, req); n != len(rs) {
			t.Errorf("the request held in flight carried %d records, want %d", n, len(rs))
		}
	default:
		t.Fatal("no produce request reached the broker before the deadline")
	}
	want, _ := ctx.Deadline()
	ended := map[trace.SpanID]bool{}
	for _, s := range recorder.Ended() {
		if s.Status().Code == codes.Error {
			ended[s.SpanContext().SpanID()] = true
		}
	}
	for i, r := range rs {
		if d, ok := r.Context.Deadline(); !ok || !d.Equal(want) {
			t.Errorf("record %d deadline = %v (set %v), want the call's %v", i, d, ok, want)
		}
		sc := trace.SpanContextFromContext(r.Context)
		if !ended[sc.SpanID()] || !strings.Contains(parents[i], sc.TraceID().String()) {
			t.Errorf("record %d: span %s in trace %s, want it ended with an error in trace of %s", i, sc.SpanID(), sc.TraceID(), parents[i])
		}
	}
	if started := len(recorder.Started()); started != len(rs) || len(recorder.Ended()) != len(rs) {
		t.Errorf("producer spans: %d started, %d ended, want %d each", started, len(recorder.Ended()), len(rs))
	}
}

// The dead-letter produce is in flight and never acknowledged: the consumer stops with that error
// once the dead-letter deadline passes, counts nothing and commits nothing, so the source record
// is delivered again; record and batch consumers alike.
func TestDeadLetterProduceWithoutAckLeavesSourceUncommitted(t *testing.T) {
	for _, batch := range []bool{false, true} {
		t.Run(map[bool]string{false: "record", true: "batch"}[batch], func(t *testing.T) {
			recorder, reader := traceTelemetry(t)
			c, brokers := fakeCluster(t, "in", "in.dlq")
			produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})
			held := holdProduce(c)
			const dlqTimeout = 300 * time.Millisecond
			var r *running
			if batch {
				r = startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
					MaxBatchRecords: 1, deadLetterTimeout: dlqTimeout,
					Handler: func(_ context.Context, b *Batch) ([]Rejected, error) {
						return []Rejected{{Record: b.Records[0], Err: errors.New("bad event")}}, nil
					}})
			} else {
				r = start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
					deadLetterTimeout: dlqTimeout,
					Handler: func(context.Context, *kgo.Record, Attempt) error {
						return Permanent(errors.New("bad event"))
					}})
			}
			err := r.wait(t)
			if err == nil || !strings.Contains(err.Error(), "dead-letter topic in.dlq") || !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("Run() = %v, want the dead-letter produce's deadline", err)
			}
			select {
			case <-held:
			default:
				t.Fatal("the dead-letter produce never reached the broker")
			}
			if got := dlqCount(t, reader, "in", "g"); got != 0 {
				t.Errorf("unacknowledged dead-letter produce counted: %d", got)
			}
			if c := committed(t, brokers, "g"); len(c) != 0 {
				t.Errorf("committed offsets = %v, want none", c)
			}
			if started, ended := len(recorder.Started()), len(recorder.Ended()); started != ended {
				t.Errorf("%d spans started, %d ended", started, ended)
			}
		})
	}
}
