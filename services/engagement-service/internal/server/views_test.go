package server

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
	"google.golang.org/protobuf/proto"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	eventv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/event/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/services/engagement-service/migrations"
)

const recreatedMsg = "stored offset is beyond the end of the partition, topic was recreated: counting from the batch"

// viewsEnv is a Server on a database of its own, since consumer_offsets rows are per group and
// partition, not per test, and the cluster its records are produced to.
type viewsEnv struct {
	s       *Server
	logs    *logBuffer
	pool    *pgxpool.Pool
	brokers string
	// cl produces to the partition set on each record; the Server also asks it for end offsets.
	cl *kgo.Client
}

func newViewsEnv(t *testing.T, name string) *viewsEnv {
	t.Helper()
	pool := pgtest.New(t, "svp_engagement_views_"+name+"_test", migrations.FS)
	_, brokers := newCluster(t)
	cl, err := kafkax.NewClient(brokers, "engagement-service-test", kgo.RecordPartitioner(kgo.ManualPartitioner()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	logs := &logBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))
	return &viewsEnv{s: New(pool, cl, logger), logs: logs, pool: pool, brokers: brokers, cl: cl}
}

func viewValue(videoID, viewerID string) []byte {
	value, err := proto.Marshal(&engagementv1.ViewEvent{
		Meta: &eventv1.EventMeta{EventId: ids.New()},
		Event: &engagementv1.ViewEvent_ViewRecorded{ViewRecorded: &engagementv1.ViewRecorded{
			VideoId:  videoID,
			ViewerId: viewerID,
		}},
	})
	if err != nil {
		panic(err)
	}
	return value
}

// produce writes values to partition of TopicViews and returns the records with their offsets.
func (e *viewsEnv) produce(t *testing.T, partition int32, values ...[]byte) []*kgo.Record {
	t.Helper()
	rs := make([]*kgo.Record, len(values))
	for i, v := range values {
		rs[i] = &kgo.Record{Topic: TopicViews, Partition: partition, Value: v}
	}
	if err := e.cl.ProduceSync(t.Context(), rs...).FirstErr(); err != nil {
		t.Fatal(err)
	}
	return rs
}

// produceViews writes one view of each video id to partition.
func (e *viewsEnv) produceViews(t *testing.T, partition int32, videoIDs ...string) []*kgo.Record {
	t.Helper()
	values := make([][]byte, len(videoIDs))
	for i, id := range videoIDs {
		values[i] = viewValue(id, ids.New())
	}
	return e.produce(t, partition, values...)
}

func (e *viewsEnv) handle(t *testing.T, rs ...*kgo.Record) []kafkax.Rejected {
	t.Helper()
	rejected, err := e.s.HandleViews(t.Context(), &kafkax.Batch{Records: rs})
	if err != nil {
		t.Fatalf("HandleViews() = %v", err)
	}
	return rejected
}

// viewCount returns the stored view_count of videoID, 0 without a row.
func (e *viewsEnv) viewCount(t *testing.T, videoID string) int64 {
	t.Helper()
	var n int64
	err := e.pool.QueryRow(t.Context(),
		`SELECT COALESCE((SELECT view_count FROM view_counts WHERE video_id = $1), 0)`, videoID).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// nextOffset returns the stored next_offset of partition, -1 without a row.
func (e *viewsEnv) nextOffset(t *testing.T, partition int32) int64 {
	t.Helper()
	var n int64
	err := e.pool.QueryRow(t.Context(), `
		SELECT COALESCE((SELECT next_offset FROM consumer_offsets
		                 WHERE consumer_group = $1 AND topic = $2 AND partition = $3), -1)`,
		ViewsGroup, TopicViews, partition).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func (e *viewsEnv) wantCounts(t *testing.T, want map[string]int64) {
	t.Helper()
	for id, n := range want {
		if got := e.viewCount(t, id); got != n {
			t.Errorf("view_count of %s = %d, want %d", id, got, n)
		}
	}
}

func (e *viewsEnv) wantNextOffset(t *testing.T, partition int32, want int64) {
	t.Helper()
	if got := e.nextOffset(t, partition); got != want {
		t.Errorf("next_offset of partition %d = %d, want %d", partition, got, want)
	}
}

// repeat returns n copies of id.
func repeat(id string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = id
	}
	return out
}

func TestRedeliveredBatchCountsOnce(t *testing.T) {
	e := newViewsEnv(t, "redeliver")
	a, b := ids.New(), ids.New()
	rs := e.produceViews(t, 0, append(repeat(a, 6), repeat(b, 4)...)...)

	for range 3 {
		if rejected := e.handle(t, rs...); len(rejected) != 0 {
			t.Fatalf("rejected %v, want none", rejected)
		}
		e.wantCounts(t, map[string]int64{a: 6, b: 4})
		e.wantNextOffset(t, 0, 10)
	}
	if got := e.logs.records(t, recreatedMsg); len(got) != 0 {
		t.Errorf("logged %d topic-recreated warnings, want none", len(got))
	}
}

// A redelivery can be shorter than the batch counted before (a batch closes after 1 s): it must
// not lower next_offset, or the records between would be counted again (ADR-0009, section 4,
// step 6).
func TestShorterRedeliveryKeepsNextOffset(t *testing.T) {
	e := newViewsEnv(t, "shorter")
	id := ids.New()
	rs := e.produceViews(t, 0, repeat(id, 10)...)
	e.handle(t, rs...)
	e.handle(t, rs[:5]...)
	e.wantNextOffset(t, 0, 10)
	e.wantCounts(t, map[string]int64{id: 10})

	rs = append(rs, e.produceViews(t, 0, repeat(id, 5)...)...)
	e.handle(t, rs[5:]...)
	e.wantNextOffset(t, 0, 15)
	e.wantCounts(t, map[string]int64{id: 15})
}

// A consumer whose batch kept failing past RebalanceTimeout retries it after another member took
// the partition over and counted further. Its batch, fetched when the partition ended at offset 8,
// lies below the stored next_offset; the end offset asked after locking does not, so this is not a
// recreated topic and nothing is counted again (ADR-0009, section 4, step 3).
func TestStaleRetryAfterAnotherConsumerCountedFurther(t *testing.T) {
	e := newViewsEnv(t, "stale_retry")
	id := ids.New()
	rs := e.produceViews(t, 0, repeat(id, 15)...)
	// The other member counts offsets 0..12.
	e.handle(t, rs[:13]...)

	stale := &kafkax.Batch{Records: rs[3:8]}
	if _, err := e.s.HandleViews(t.Context(), stale); err != nil {
		t.Fatal(err)
	}
	e.wantNextOffset(t, 0, 13)
	e.wantCounts(t, map[string]int64{id: 13})
	if got := e.logs.records(t, recreatedMsg); len(got) != 0 {
		t.Errorf("logged %d topic-recreated warnings, want none", len(got))
	}
}

// After make clean-data the topic starts again at offset 0 while consumer_offsets keeps the old
// topic's offsets.
func TestRecreatedTopicCountsFromTheBatch(t *testing.T) {
	e := newViewsEnv(t, "recreated")
	_, err := e.pool.Exec(t.Context(),
		`INSERT INTO consumer_offsets (consumer_group, topic, partition, next_offset) VALUES ($1, $2, 1, 10000)`,
		ViewsGroup, TopicViews)
	if err != nil {
		t.Fatal(err)
	}
	id := ids.New()
	rs := e.produceViews(t, 1, repeat(id, 5)...)

	e.handle(t, rs...)
	e.wantCounts(t, map[string]int64{id: 5})
	e.wantNextOffset(t, 1, 5)
	warns := e.logs.records(t, recreatedMsg)
	if len(warns) != 1 {
		t.Fatalf("logged %d topic-recreated warnings, want 1", len(warns))
	}
	w := warns[0]
	if w["level"] != "WARN" || w["partition"] != float64(1) || w["stored_next_offset"] != float64(10000) ||
		w["end_offset"] != float64(5) || w["reset_to"] != float64(0) {
		t.Errorf("warning = %v, want WARN for partition 1, stored 10000, end 5, reset to 0", w)
	}

	// Counted from the new topic now: a redelivery is skipped as usual.
	e.handle(t, rs...)
	e.wantCounts(t, map[string]int64{id: 5})
	if got := e.logs.records(t, recreatedMsg); len(got) != 1 {
		t.Errorf("logged %d topic-recreated warnings, want still 1", len(got))
	}
}

// The end offset lookup fails (the broker cannot be reached) for a partition whose stored
// next_offset lies beyond the batch: the batch fails whole so kafkax retries it, with nothing
// counted and next_offset neither reset nor moved. The retry, once the broker answers, counts it.
func TestFailedEndOffsetLookupRetriesTheBatch(t *testing.T) {
	e := newViewsEnv(t, "end_offsets_error")
	_, err := e.pool.Exec(t.Context(),
		`INSERT INTO consumer_offsets (consumer_group, topic, partition, next_offset) VALUES ($1, $2, 1, 10000)`,
		ViewsGroup, TopicViews)
	if err != nil {
		t.Fatal(err)
	}
	id := ids.New()
	rs := e.produceViews(t, 1, repeat(id, 5)...)

	closed, err := kafkax.NewClient(e.brokers, "engagement-service-test-closed")
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	broken := New(e.pool, closed, e.s.logger)
	for range 2 {
		if rejected, err := broken.HandleViews(t.Context(), &kafkax.Batch{Records: rs}); err == nil {
			t.Fatalf("HandleViews() with no broker = %v, nil; want an error", rejected)
		}
		e.wantCounts(t, map[string]int64{id: 0})
		e.wantNextOffset(t, 1, 10000)
	}
	if got := e.logs.records(t, recreatedMsg); len(got) != 0 {
		t.Errorf("logged %d topic-recreated warnings, want none", len(got))
	}

	e.handle(t, rs...)
	e.wantCounts(t, map[string]int64{id: 5})
	e.wantNextOffset(t, 1, 5)
}

// Members that both believe they own the partitions, during a rebalance, each read from the
// offset Kafka last committed and handle overlapping batches at the same time. Each batch spans
// two partitions, in a different order per member, so the fixed lock order is exercised too.
func TestOverlappingConcurrentBatchesCountEachOffsetOnce(t *testing.T) {
	e := newViewsEnv(t, "concurrent")
	videos := []string{ids.New(), ids.New(), ids.New()}
	var p0, p1 []string
	want := map[string]int64{}
	for i := range 200 {
		p0 = append(p0, videos[i%3])
		p1 = append(p1, videos[(i+1)%3])
		want[videos[i%3]]++
		want[videos[(i+1)%3]]++
	}
	r0, r1 := e.produceViews(t, 0, p0...), e.produceViews(t, 1, p1...)

	// Where each member's batches end; every member starts at offset 0 and reads on from there.
	members := [][]int{{50, 120, 200}, {80, 160, 200}, {200}, {30, 60, 90, 130, 170, 200}}
	var wg sync.WaitGroup
	start := make(chan struct{})
	errs := make(chan error, len(members))
	for m, ends := range members {
		wg.Go(func() {
			<-start
			from := 0
			for _, to := range ends {
				recs := slices.Concat(r0[from:to], r1[from:to])
				if m%2 == 1 {
					recs = slices.Concat(r1[from:to], r0[from:to])
				}
				if _, err := e.s.HandleViews(t.Context(), &kafkax.Batch{Records: recs}); err != nil {
					errs <- err
					return
				}
				from = to
			}
		})
	}
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("HandleViews() = %v", err)
	}

	e.wantCounts(t, want)
	e.wantNextOffset(t, 0, 200)
	e.wantNextOffset(t, 1, 200)
}

// A viral video takes most of a batch spread over every partition. The batch still upserts one
// row per video: a repeated id in the arrays would fail with "ON CONFLICT DO UPDATE command
// cannot affect row a second time".
func TestHotVideoBatchAcrossPartitions(t *testing.T) {
	e := newViewsEnv(t, "hot")
	hot := ids.New()
	cold := []string{ids.New(), ids.New(), ids.New(), ids.New()}
	want := map[string]int64{hot: 0}
	var batch []*kgo.Record
	for p := range int32(3) {
		var vs []string
		for i := range 300 {
			id := hot
			if i%10 == 0 {
				id = cold[(i/10)%len(cold)]
			}
			vs = append(vs, id)
			want[id]++
		}
		batch = append(batch, e.produceViews(t, p, vs...)...)
	}
	// Records of each partition keep their order, partitions interleaved as fetches arrive.
	slices.SortStableFunc(batch, func(a, b *kgo.Record) int { return int(a.Offset - b.Offset) })

	e.handle(t, batch...)
	e.wantCounts(t, want)
	if want[hot] != 810 {
		t.Fatalf("test setup: hot video has %d views, want 810", want[hot])
	}
	for p := range int32(3) {
		e.wantNextOffset(t, p, 300)
	}
	var rows int
	if err := e.pool.QueryRow(t.Context(), `SELECT count(*) FROM view_counts`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 5 {
		t.Errorf("view_counts has %d rows, want 5", rows)
	}
}

func TestMalformedRecordsAreRejectedOnEveryDelivery(t *testing.T) {
	e := newViewsEnv(t, "malformed")
	id := ids.New()
	noBranch, err := proto.Marshal(&engagementv1.ViewEvent{Meta: &eventv1.EventMeta{EventId: ids.New()}})
	if err != nil {
		t.Fatal(err)
	}
	rs := e.produce(t, 2,
		viewValue(id, ids.New()),
		[]byte("not a protobuf \xff\xff"),
		viewValue(id, ids.New()),
		noBranch,
		viewValue("not-a-uuid", ids.New()),
		viewValue(strings.ToUpper(ids.New()), ids.New()),
		viewValue(id, ""),
		viewValue(id, ids.New()),
	)
	bad := []*kgo.Record{rs[1], rs[3], rs[4], rs[5], rs[6]}

	for range 2 {
		rejected := e.handle(t, rs...)
		var got []*kgo.Record
		for _, rj := range rejected {
			if rj.Err == nil {
				t.Errorf("record at offset %d rejected without a reason", rj.Record.Offset)
			}
			got = append(got, rj.Record)
		}
		if !slices.Equal(got, bad) {
			t.Errorf("rejected offsets %v, want %v", offsets(got), offsets(bad))
		}
		e.wantCounts(t, map[string]int64{id: 3})
		// Rejected records move the offset too: the last record of the batch decides it.
		e.wantNextOffset(t, 2, 8)
	}
}

func offsets(rs []*kgo.Record) []int64 {
	out := make([]int64, len(rs))
	for i, r := range rs {
		out[i] = r.Offset
	}
	return out
}

// A batch of rejected records only still moves next_offset, and an empty batch is a no-op.
func TestBatchOfOnlyRejectedRecords(t *testing.T) {
	e := newViewsEnv(t, "only_rejected")
	rs := e.produce(t, 0, []byte("garbage"), []byte("more garbage"))
	if rejected := e.handle(t, rs...); len(rejected) != 2 {
		t.Fatalf("rejected %d records, want 2", len(rejected))
	}
	e.wantNextOffset(t, 0, 2)
	if rejected := e.handle(t); len(rejected) != 0 {
		t.Fatalf("empty batch rejected %d records", len(rejected))
	}
}

// runViews runs a batch consumer of the Server's config, with handler wrapping HandleViews and
// small batches, until stop is called; stop waits for it to leave the group.
func (e *viewsEnv) runViews(t *testing.T, handler kafkax.BatchHandler) (stop func()) {
	t.Helper()
	cfg := e.s.ViewsConsumerConfig(e.brokers)
	cfg.Handler = handler
	cfg.MaxBatchRecords = 128
	cfg.MaxBatchWait = 100 * time.Millisecond
	cfg.BackoffBase = time.Millisecond
	cfg.BackoffMax = 10 * time.Millisecond
	c, err := kafkax.NewBatchConsumer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	var once sync.Once
	stop = func() {
		once.Do(func() {
			cancel()
			select {
			case err := <-done:
				if err != nil {
					t.Errorf("consumer Run() = %v", err)
				}
			case <-time.After(30 * time.Second):
				t.Error("consumer did not stop")
			}
		})
	}
	t.Cleanup(stop)
	return stop
}

// eventually fails t unless cond holds within 30 s.
func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// rewindGroup commits offset 0 for every partition of TopicViews in ViewsGroup, as
// `rpk group seek --to start` does, from a client of its own: kafkax hides the consumer's.
func rewindGroup(t *testing.T, brokers string) {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "test-rewind",
		kgo.ConsumerGroup(ViewsGroup), kgo.ConsumeTopics(TopicViews), kgo.DisableAutoCommit())
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	start := map[int32]kgo.EpochOffset{}
	for p := range int32(3) {
		start[p] = kgo.EpochOffset{Epoch: -1, Offset: 0}
	}
	var commitErr error
	cl.CommitOffsetsSync(ctx, map[string]map[int32]kgo.EpochOffset{TopicViews: start},
		func(_ *kgo.Client, _ *kmsg.OffsetCommitRequest, resp *kmsg.OffsetCommitResponse, err error) {
			if err != nil {
				commitErr = err
				return
			}
			for _, tp := range resp.Topics {
				for _, p := range tp.Partitions {
					if err := kerr.ErrorForCode(p.ErrorCode); err != nil {
						commitErr = fmt.Errorf("partition %d: %w", p.Partition, err)
					}
				}
			}
		})
	if commitErr != nil {
		t.Fatalf("rewind %s: %v", ViewsGroup, commitErr)
	}
}

// readTopic reads n records of topic from the start.
func readTopic(t *testing.T, brokers, topic string, n int) []*kgo.Record {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "test-reader",
		kgo.ConsumeTopics(topic), kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	var out []*kgo.Record
	for len(out) < n {
		fetches := cl.PollFetches(ctx)
		if err := ctx.Err(); err != nil {
			t.Fatalf("read %d of %d records of %s: %v", len(out), n, topic, err)
		}
		out = append(out, fetches.Records()...)
	}
	return out
}

// endOffsets returns the end offset of every partition of TopicViews and of its dead-letter
// topic.
func (e *viewsEnv) endOffsets(t *testing.T) (views [3]int64, dlq int64) {
	t.Helper()
	tps := []kafkax.TopicPartition{{Topic: TopicViews + kafkax.DLQSuffix, Partition: 0}}
	for p := range int32(3) {
		tps = append(tps, kafkax.TopicPartition{Topic: TopicViews, Partition: p})
	}
	ends, err := kafkax.EndOffsets(t.Context(), e.cl, tps...)
	if err != nil {
		t.Fatal(err)
	}
	for p := range int32(3) {
		views[p] = ends[kafkax.TopicPartition{Topic: TopicViews, Partition: p}]
	}
	return views, ends[tps[0]]
}

// countedThrough reports whether next_offset of every partition has reached ends.
func (e *viewsEnv) countedThrough(t *testing.T, ends [3]int64) bool {
	t.Helper()
	for p := range int32(3) {
		// A partition without records has no offset row.
		if max(e.nextOffset(t, p), 0) != ends[p] {
			return false
		}
	}
	return true
}

// End to end through kafkax: 1,000 views of a few videos over 3 partitions, with malformed
// records between them, are counted exactly; after the group is rewound to the start, a new
// consumer reads everything again and no count changes.
func TestConsumerCountsThousandViewsOnceAfterRewind(t *testing.T) {
	e := newViewsEnv(t, "consumer")
	videos := []string{ids.New(), ids.New(), ids.New(), ids.New(), ids.New()}
	want := map[string]int64{}
	perPartition := map[int32][][]byte{}
	for i := range 1000 {
		// Uneven counts per video, the first one hot.
		id := videos[0]
		if i%4 != 0 {
			id = videos[1+i%len(videos[1:])]
		}
		want[id]++
		p := int32(i % 3)
		perPartition[p] = append(perPartition[p], viewValue(id, ids.New()))
		if i%250 == 0 {
			perPartition[p] = append(perPartition[p], []byte("malformed view"))
		}
	}
	for p := range int32(3) {
		e.produce(t, p, perPartition[p]...)
	}
	ends, dlqStart := e.endOffsets(t)
	if dlqStart != 0 {
		t.Fatalf("dead-letter topic starts with %d records, want 0", dlqStart)
	}

	var seen atomic.Int64
	handler := func(ctx context.Context, b *kafkax.Batch) ([]kafkax.Rejected, error) {
		rejected, err := e.s.HandleViews(ctx, b)
		if err == nil {
			seen.Add(int64(len(b.Records)))
		}
		return rejected, err
	}
	total := ends[0] + ends[1] + ends[2]
	stop := e.runViews(t, handler)
	// The dead-letter records of a batch are produced after its transaction commits.
	eventually(t, "the first consumer to count every record", func() bool {
		_, dlq := e.endOffsets(t)
		return e.countedThrough(t, ends) && dlq == 4
	})
	stop()
	e.wantCounts(t, want)

	rewindGroup(t, e.brokers)
	seen.Store(0)
	stop = e.runViews(t, handler)
	eventually(t, "the second consumer to read every record again", func() bool {
		_, dlq := e.endOffsets(t)
		return seen.Load() >= total && dlq == 8
	})
	stop()
	e.wantCounts(t, want)
	if !e.countedThrough(t, ends) {
		t.Errorf("next_offset moved past the end offsets %v", ends)
	}

	// The 4 malformed records went to the dead-letter topic once per delivery.
	dlq := readTopic(t, e.brokers, TopicViews+kafkax.DLQSuffix, 8)
	for _, r := range dlq {
		if string(r.Value) != "malformed view" || headerValue(r, kafkax.HeaderDLQGroup) != ViewsGroup ||
			headerValue(r, kafkax.HeaderDLQReason) != kafkax.ReasonPermanent {
			t.Errorf("dead-letter record %q with dlq-group %q, dlq-reason %q; want the malformed view from %s, permanent",
				r.Value, headerValue(r, kafkax.HeaderDLQGroup), headerValue(r, kafkax.HeaderDLQReason), ViewsGroup)
		}
	}
}

// Postgres fails the batch's transaction after the offset rows are locked: the transaction rolls
// back whole, kafkax retries the batch, and the views are counted once with nothing sent to the
// dead-letter topic.
func TestPostgresErrorRetriesTheBatch(t *testing.T) {
	e := newViewsEnv(t, "pg_error")
	// The sequence is not transactional, so the first two upserts fail and later ones pass.
	_, err := e.pool.Exec(t.Context(), `
		CREATE SEQUENCE fail_upserts;
		CREATE FUNCTION fail_first_upserts() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN
			IF nextval('fail_upserts') <= 2 THEN
				RAISE EXCEPTION 'injected failure';
			END IF;
			RETURN NULL;
		END $$;
		CREATE TRIGGER fail_first_upserts BEFORE INSERT ON view_counts
			FOR EACH STATEMENT EXECUTE FUNCTION fail_first_upserts();`)
	if err != nil {
		t.Fatal(err)
	}
	id := ids.New()
	e.produceViews(t, 0, repeat(id, 30)...)
	e.produceViews(t, 2, repeat(id, 20)...)

	e.runViews(t, e.s.HandleViews)
	eventually(t, "every view to be counted", func() bool { return e.viewCount(t, id) == 50 })
	ends, dlq := e.endOffsets(t)
	eventually(t, "next_offset to reach the end offsets", func() bool { return e.countedThrough(t, ends) })
	e.wantCounts(t, map[string]int64{id: 50})
	if dlq != 0 {
		t.Errorf("dead-letter topic has %d records, want 0", dlq)
	}
	if got := e.logs.records(t, "kafka batch handler failed, retrying"); len(got) < 2 {
		t.Errorf("logged %d retries, want at least 2", len(got))
	}
}

// Each batch attempt has a deadline of its own, so a stuck lock or a slow broker fails it and the
// batch is retried (ADR-0011, section 11).
func TestViewsConsumerConfigBoundsEachAttempt(t *testing.T) {
	s, _ := newServerWithoutDB(nil)
	if cfg := s.ViewsConsumerConfig("127.0.0.1:19092"); cfg.HandlerTimeout != 30*time.Second {
		t.Errorf("HandlerTimeout = %s, want 30s", cfg.HandlerTimeout)
	}
}

// A batch attempt waiting on the offset row that another transaction locks ends at the
// attempt's deadline, its transaction rolled back: nothing is counted, and the batch counts once
// when retried after the lock is free.
func TestBatchWaitingOnOffsetLockEndsAtDeadline(t *testing.T) {
	e := newViewsEnv(t, "lock_wait")
	id := ids.New()
	rs := e.produceViews(t, 0, repeat(id, 5)...)

	holder, err := e.pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(t.Context(),
		"INSERT INTO consumer_offsets (consumer_group, topic, partition, next_offset) VALUES ($1, $2, 0, 0)",
		ViewsGroup, TopicViews); err != nil {
		t.Fatal(err)
	}

	const deadline = 200 * time.Millisecond
	ctx, cancel := context.WithTimeout(t.Context(), deadline)
	defer cancel()
	start := time.Now()
	_, err = e.s.HandleViews(ctx, &kafkax.Batch{Records: rs})
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("HandleViews returned nil while the offset row was locked")
	}
	if elapsed > deadline+rollbackTimeout {
		t.Errorf("HandleViews returned after %s, want within the deadline %s and the rollback bound %s", elapsed, deadline, rollbackTimeout)
	}
	t.Logf("batch attempt on a locked offset row returned after %s: %v", elapsed, err)

	if err := holder.Rollback(t.Context()); err != nil {
		t.Fatal(err)
	}
	e.wantCounts(t, map[string]int64{id: 0})
	e.handle(t, rs...)
	e.handle(t, rs...)
	e.wantCounts(t, map[string]int64{id: 5})
	e.wantNextOffset(t, 0, 5)
}
