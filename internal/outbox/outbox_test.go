package outbox

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"io/fs"
	"log/slog"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	eventv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/event/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
)

const (
	topic   = "video.lifecycle.v1"
	validTP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
)

//go:embed testdata/migrations/*.sql
var embedded embed.FS

// newDB returns a pool to a fresh database svp_outbox_<name>_test holding the outbox table.
func newDB(t *testing.T, name string) *pgxpool.Pool {
	t.Helper()
	sub, err := fs.Sub(embedded, "testdata/migrations")
	if err != nil {
		t.Fatal(err)
	}
	return pgtest.New(t, "svp_outbox_"+name+"_test", sub)
}

// lockedBuffer collects log output written from relay goroutines.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// records returns the decoded JSON log lines whose msg is msg.
func (b *lockedBuffer) records(t *testing.T, msg string) []map[string]any {
	t.Helper()
	b.mu.Lock()
	text := b.buf.String()
	b.mu.Unlock()
	var out []map[string]any
	for line := range strings.SplitSeq(strings.TrimSpace(text), "\n") {
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

// cluster starts an in-memory Kafka with topic split into partitions and returns its brokers.
func cluster(t *testing.T, partitions int32, opts ...kfake.Opt) string {
	t.Helper()
	c, err := kfake.NewCluster(append([]kfake.Opt{kfake.NumBrokers(1), kfake.SeedTopics(partitions, topic)}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return strings.Join(c.ListenAddrs(), ",")
}

func newClient(t *testing.T, brokers string, opts ...kgo.Opt) *kgo.Client {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "test-relay", opts...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	return cl
}

// newRelay returns a relay with short waits that logs to the returned buffer.
func newRelay(pool *pgxpool.Pool, cl *kgo.Client) (*Relay, *lockedBuffer) {
	logs := &lockedBuffer{}
	r := NewRelay(pool, cl, slog.New(slog.NewJSONHandler(logs, nil)))
	r.idleWait = 10 * time.Millisecond
	r.produceTimeout = 300 * time.Millisecond
	r.retryBase = 20 * time.Millisecond
	r.retryMax = 100 * time.Millisecond
	return r, logs
}

// start runs r in the background; the returned func stops it and waits for Run to return.
func start(t *testing.T, r *Relay) (stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	go func() {
		defer close(done)
		r.Run(ctx)
	}()
	stop = func() {
		cancel()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Fatal("relay did not stop")
		}
	}
	t.Cleanup(stop)
	return stop
}

// newEvent returns a video.uploaded event for video id.
func newEvent(id string) *videov1.VideoEvent {
	return &videov1.VideoEvent{
		Meta:  NewMeta(),
		Event: &videov1.VideoEvent_VideoUploaded{VideoUploaded: &videov1.VideoUploaded{VideoId: id}},
	}
}

// write commits one event for key in its own transaction and returns its event_id.
func write(ctx context.Context, t *testing.T, pool *pgxpool.Pool, key string) string {
	t.Helper()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	ev := newEvent(key)
	if err := Write(ctx, tx, topic, key, ev); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	return ev.GetMeta().GetEventId()
}

func countUnsent(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(t.Context(), "SELECT count(*) FROM outbox WHERE published_at IS NULL").Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// eventually fails the test unless cond holds within 10 seconds.
func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// consume reads topic from the start until it has want records, then keeps reading for extra
// to catch records beyond want (duplicates).
func consume(t *testing.T, brokers string, want int, extra time.Duration) []*kgo.Record {
	t.Helper()
	cl := newClient(t, brokers,
		kgo.ConsumeTopics(topic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	var out []*kgo.Record
	deadline := time.Now().Add(10 * time.Second)
	for len(out) < want && time.Now().Before(deadline) {
		out = append(out, poll(t, cl, time.Until(deadline))...)
	}
	if len(out) < want {
		t.Fatalf("consumed %d records, want %d", len(out), want)
	}
	if extra > 0 {
		out = append(out, poll(t, cl, extra)...)
	}
	return out
}

func poll(t *testing.T, cl *kgo.Client, d time.Duration) []*kgo.Record {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), d)
	defer cancel()
	fetches := cl.PollFetches(ctx)
	for _, fe := range fetches.Errors() {
		if ctx.Err() == nil {
			t.Fatalf("fetch %s/%d: %v", fe.Topic, fe.Partition, fe.Err)
		}
	}
	return fetches.Records()
}

// eventID returns the event_id in the envelope of a record's value.
func eventID(t *testing.T, r *kgo.Record) string {
	t.Helper()
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		t.Fatal(err)
	}
	return ev.GetMeta().GetEventId()
}

func eventIDs(t *testing.T, rs []*kgo.Record) []string {
	t.Helper()
	out := make([]string, len(rs))
	for i, r := range rs {
		out[i] = eventID(t, r)
	}
	return out
}

func headerValue(r *kgo.Record, key string) (string, bool) {
	for _, h := range r.Headers {
		if h.Key == key {
			return string(h.Value), true
		}
	}
	return "", false
}

func TestNewMeta(t *testing.T) {
	m := NewMeta()
	if _, err := ids.Parse(m.GetEventId()); err != nil {
		t.Errorf("event_id %q: %v", m.GetEventId(), err)
	}
	if age := time.Since(m.GetOccurredAt().AsTime()); age < 0 || age > time.Minute {
		t.Errorf("occurred_at is %v ago, want now", age)
	}
	if NewMeta().GetEventId() == m.GetEventId() {
		t.Error("two calls to NewMeta() returned the same event_id")
	}
}

func TestWriteRejectsIncompleteEvent(t *testing.T) {
	id := ids.New()
	tests := []struct {
		name       string
		topic, key string
		ev         Event
	}{
		{name: "no topic", key: id, ev: newEvent(id)},
		{name: "no key", topic: topic, ev: newEvent(id)},
		{name: "no meta", topic: topic, key: id, ev: &videov1.VideoEvent{}},
		{name: "no occurred_at", topic: topic, key: id, ev: &videov1.VideoEvent{Meta: &eventv1.EventMeta{EventId: ids.New()}}},
		{name: "bad event_id", topic: topic, key: id, ev: &videov1.VideoEvent{Meta: &eventv1.EventMeta{EventId: "nope", OccurredAt: NewMeta().GetOccurredAt()}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// The checks run before the transaction is used.
			if err := Write(t.Context(), nil, tt.topic, tt.key, tt.ev); err == nil {
				t.Error("Write() = nil, want an error")
			}
		})
	}
}

func TestWriteStoresEventInTransaction(t *testing.T) {
	pool := newDB(t, "write")
	key := ids.New()

	ctx := traceparent.NewContext(t.Context(), validTP)
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ev := newEvent(key)
	if err := Write(ctx, tx, topic, key, ev); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	plain := write(t.Context(), t, pool, key)

	type stored struct {
		eventID, topic, key string
		payload             []byte
		headers             map[string]string
	}
	rows, err := pool.Query(t.Context(), "SELECT event_id::text, topic, record_key, payload, headers FROM outbox ORDER BY id")
	if err != nil {
		t.Fatal(err)
	}
	var got []stored
	for rows.Next() {
		var s stored
		if err := rows.Scan(&s.eventID, &s.topic, &s.key, &s.payload, &s.headers); err != nil {
			t.Fatal(err)
		}
		got = append(got, s)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d rows, want 2", len(got))
	}

	first := got[0]
	if first.eventID != ev.GetMeta().GetEventId() || first.topic != topic || first.key != key {
		t.Errorf("row = (%s, %s, %s), want (%s, %s, %s)", first.eventID, first.topic, first.key, ev.GetMeta().GetEventId(), topic, key)
	}
	var decoded videov1.VideoEvent
	if err := proto.Unmarshal(first.payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(&decoded, ev) {
		t.Errorf("payload = %v, want %v", &decoded, ev)
	}
	if first.headers[traceparent.MetadataKey] != validTP || len(first.headers) != 1 {
		t.Errorf("headers = %v, want only traceparent %s", first.headers, validTP)
	}
	if got[1].eventID != plain || len(got[1].headers) != 0 {
		t.Errorf("second row = (%s, headers %v), want (%s, no headers)", got[1].eventID, got[1].headers, plain)
	}
}

func TestRolledBackWriteSendsNothing(t *testing.T) {
	pool := newDB(t, "rollback")
	brokers := cluster(t, 1)

	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if err := Write(t.Context(), tx, topic, ids.New(), newEvent(ids.New())); err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback(t.Context()); err != nil {
		t.Fatal(err)
	}
	committed := write(t.Context(), t, pool, ids.New())

	r, _ := newRelay(pool, newClient(t, brokers))
	start(t, r)
	got := consume(t, brokers, 1, 300*time.Millisecond)
	if sent := eventIDs(t, got); len(sent) != 1 || sent[0] != committed {
		t.Errorf("sent %v, want only the committed event %s", sent, committed)
	}
}

func TestRelaySendsInBatchesInOrder(t *testing.T) {
	pool := newDB(t, "batches")
	brokers := cluster(t, 3)
	key := ids.New()
	var want []string
	for range 250 {
		want = append(want, write(t.Context(), t, pool, key))
	}

	r, logs := newRelay(pool, newClient(t, brokers))
	stop := start(t, r)
	got := consume(t, brokers, 250, 300*time.Millisecond)
	stop()

	if gotIDs := eventIDs(t, got); strings.Join(gotIDs, ",") != strings.Join(want, ",") {
		t.Errorf("sent %d events in another order than written (or with duplicates)", len(gotIDs))
	}
	for _, rec := range got {
		if string(rec.Key) != key || rec.Partition != got[0].Partition {
			t.Fatalf("record key %q on partition %d, want key %q on partition %d", rec.Key, rec.Partition, key, got[0].Partition)
		}
	}
	var sizes []float64
	for _, rec := range logs.records(t, "outbox batch sent") {
		sizes = append(sizes, rec["rows"].(float64))
	}
	if len(sizes) != 3 || sizes[0] != 100 || sizes[1] != 100 || sizes[2] != 50 {
		t.Errorf("batch sizes = %v, want [100 100 50]", sizes)
	}
	if n := countUnsent(t, pool); n != 0 {
		t.Errorf("%d rows unsent, want 0", n)
	}
}

func TestRelayCarriesTraceparentHeader(t *testing.T) {
	pool := newDB(t, "traceparent")
	brokers := cluster(t, 1)
	key := ids.New()

	ctx := traceparent.NewContext(t.Context(), validTP)
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := Write(ctx, tx, topic, key, newEvent(key)); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	write(t.Context(), t, pool, key)

	r, _ := newRelay(pool, newClient(t, brokers))
	start(t, r)
	got := consume(t, brokers, 2, 0)
	if v, ok := headerValue(got[0], traceparent.MetadataKey); !ok || v != validTP {
		t.Errorf("traceparent header = (%q, %v), want %q", v, ok, validTP)
	}
	if v, ok := headerValue(got[1], traceparent.MetadataKey); ok {
		t.Errorf("event written without traceparent got header %q", v)
	}
}

func TestRelayWaitsWhileLockHeld(t *testing.T) {
	pool := newDB(t, "lockheld")
	brokers := cluster(t, 1)
	want := write(t.Context(), t, pool, ids.New())

	// Another relay is sending a batch.
	holder, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(t.Context(), "SELECT pg_advisory_xact_lock($1)", lockID); err != nil {
		t.Fatal(err)
	}

	r, _ := newRelay(pool, newClient(t, brokers))
	start(t, r)
	time.Sleep(20 * r.idleWait)
	if n := countUnsent(t, pool); n != 1 {
		t.Fatalf("%d rows unsent while another relay holds the lock, want 1", n)
	}

	if err := holder.Rollback(t.Context()); err != nil {
		t.Fatal(err)
	}
	got := consume(t, brokers, 1, 0)
	if id := eventID(t, got[0]); id != want {
		t.Errorf("sent %s, want %s", id, want)
	}
	eventually(t, "the row to be marked sent", func() bool { return countUnsent(t, pool) == 0 })
}

func TestTwoRelaysSendEachEventOnceInOrder(t *testing.T) {
	pool := newDB(t, "tworelays")
	// One partition: the topic's order is the order the relays produced in.
	brokers := cluster(t, 1)
	keys := []string{ids.New(), ids.New(), ids.New()}
	var want []string
	for i := range 150 {
		want = append(want, write(t.Context(), t, pool, keys[i%len(keys)]))
	}

	r1, _ := newRelay(pool, newClient(t, brokers))
	r2, _ := newRelay(pool, newClient(t, brokers))
	r1.idleWait, r2.idleWait = time.Millisecond, time.Millisecond
	start(t, r1)
	start(t, r2)
	// More events while both run.
	for i := range 150 {
		want = append(want, write(t.Context(), t, pool, keys[i%len(keys)]))
	}

	got := consume(t, brokers, len(want), 500*time.Millisecond)
	if gotIDs := eventIDs(t, got); strings.Join(gotIDs, ",") != strings.Join(want, ",") {
		t.Errorf("two relays sent %d events (want %d) in another order than written or with duplicates", len(gotIDs), len(want))
	}
}

func TestRelayRetriesUntilBrokerIsBack(t *testing.T) {
	pool := newDB(t, "brokerdown")
	// A port nothing listens on, for a broker that starts later.
	ln, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	brokers := ln.Addr().String()
	var want []string
	for range 3 {
		want = append(want, write(t.Context(), t, pool, ids.New()))
	}

	r, logs := newRelay(pool, newClient(t, brokers))
	start(t, r)
	eventually(t, "two failed attempts", func() bool { return len(logs.records(t, "outbox relay failed, retrying")) >= 2 })
	if n := countUnsent(t, pool); n != 3 {
		t.Fatalf("%d rows unsent while the broker is down, want 3", n)
	}

	cluster(t, 1, kfake.Ports(port))
	got := consume(t, brokers, 3, 0)
	if gotIDs := eventIDs(t, got[:3]); strings.Join(gotIDs, ",") != strings.Join(want, ",") {
		t.Errorf("sent %v after the broker came back, want %v", gotIDs, want)
	}
	eventually(t, "the rows to be marked sent", func() bool { return countUnsent(t, pool) == 0 })
}

// cancelOnAck cancels a context once the broker acknowledges a record, which is after the
// relay produced and before it marks the rows sent.
type cancelOnAck struct{ cancel context.CancelFunc }

func (h cancelOnAck) OnProduceRecordUnbuffered(_ *kgo.Record, err error) {
	if err == nil {
		h.cancel()
	}
}

func TestRelayStoppedAfterProduceSendsAgain(t *testing.T) {
	pool := newDB(t, "resend")
	brokers := cluster(t, 1)
	want := write(t.Context(), t, pool, ids.New())

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	r, _ := newRelay(pool, newClient(t, brokers, kgo.WithHooks(cancelOnAck{cancel})))
	done := make(chan struct{})
	go func() {
		defer close(done)
		r.Run(ctx)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("relay did not stop")
	}
	if n := countUnsent(t, pool); n != 1 {
		t.Fatalf("%d rows unsent after stopping between produce and commit, want 1", n)
	}

	// The next relay sends the event again: at-least-once, with the same event_id.
	r2, _ := newRelay(pool, newClient(t, brokers))
	start(t, r2)
	got := consume(t, brokers, 2, 300*time.Millisecond)
	if gotIDs := eventIDs(t, got); len(gotIDs) != 2 || gotIDs[0] != want || gotIDs[1] != want {
		t.Errorf("sent %v, want %s twice", gotIDs, want)
	}
	eventually(t, "the row to be marked sent", func() bool { return countUnsent(t, pool) == 0 })
}

func TestCleanupDeletesOnlyRowsSentOver24HoursAgo(t *testing.T) {
	pool := newDB(t, "cleanup")
	insert := func(n int, createdAgo, sentAgo string) {
		t.Helper()
		sent := "NULL"
		if sentAgo != "" {
			sent = "now() - interval '" + sentAgo + "'"
		}
		_, err := pool.Exec(t.Context(), `INSERT INTO outbox (event_id, topic, record_key, payload, created_at, published_at)
			SELECT gen_random_uuid(), 't', 'k', '\x00', now() - interval '`+createdAgo+`', `+sent+` FROM generate_series(1, $1)`, n)
		if err != nil {
			t.Fatal(err)
		}
	}
	insert(2, "30 days", "")             // never sent: kept however old
	insert(2500, "26 hours", "25 hours") // sent over 24 hours ago: deleted, over several batches
	insert(3, "24 hours", "23 hours")    // sent recently: kept

	r, logs := newRelay(pool, nil)
	r.cleanup(t.Context())

	var unsent, recent, total int
	err := pool.QueryRow(t.Context(), `SELECT
		count(*) FILTER (WHERE published_at IS NULL),
		count(*) FILTER (WHERE published_at > now() - interval '24 hours'),
		count(*) FROM outbox`).Scan(&unsent, &recent, &total)
	if err != nil {
		t.Fatal(err)
	}
	if unsent != 2 || recent != 3 || total != 5 {
		t.Errorf("left %d unsent, %d recent, %d total rows; want 2, 3, 5", unsent, recent, total)
	}
	if recs := logs.records(t, "outbox cleanup done"); len(recs) != 1 || recs[0]["deleted"] != float64(2500) {
		t.Errorf("cleanup logs = %v, want one with deleted 2500", recs)
	}
}

func TestRetryWait(t *testing.T) {
	r := NewRelay(nil, nil, nil)
	want := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 10 * time.Second, 10 * time.Second}
	for failures, w := range want {
		if got := r.retryWait(failures); got != w {
			t.Errorf("retryWait(%d) = %v, want %v", failures, got, w)
		}
	}
}

// concurrentWrites runs two transactions that change the same video and write its event. The
// first locks the row and holds it until the second waits for it, then writes and commits; the
// second commits after. When lockFirst is false the second inserts its event before it locks.
// It returns the event_ids in commit order and in outbox id order.
func concurrentWrites(t *testing.T, pool *pgxpool.Pool, lockFirst bool) (commitOrder, idOrder []string) {
	t.Helper()
	ctx := t.Context()
	video := ids.New()
	if _, err := pool.Exec(ctx, "INSERT INTO videos (id, status) VALUES ($1, 'UPLOADING')", video); err != nil {
		t.Fatal(err)
	}
	lock := func(tx pgx.Tx, status string) error {
		_, err := tx.Exec(ctx, "UPDATE videos SET status = $2 WHERE id = $1", video, status)
		return err
	}

	tx1, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx1.Rollback(context.Background()) }()
	if err := lock(tx1, "PROCESSING"); err != nil {
		t.Fatal(err)
	}

	ev2 := newEvent(video)
	second := make(chan error, 1)
	go func() {
		second <- func() error {
			tx2, err := pool.Begin(ctx)
			if err != nil {
				return err
			}
			defer func() { _ = tx2.Rollback(context.Background()) }()
			if !lockFirst {
				if err := Write(ctx, tx2, topic, video, ev2); err != nil {
					return err
				}
			}
			if err := lock(tx2, "READY"); err != nil {
				return err
			}
			if lockFirst {
				if err := Write(ctx, tx2, topic, video, ev2); err != nil {
					return err
				}
			}
			return tx2.Commit(ctx)
		}()
	}()
	eventually(t, "the second transaction to wait for the row lock", func() bool {
		var waiting int
		err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting == 1
	})

	ev1 := newEvent(video)
	if err := Write(ctx, tx1, topic, video, ev1); err != nil {
		t.Fatal(err)
	}
	if err := tx1.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-second; err != nil {
		t.Fatal(err)
	}

	rows, err := pool.Query(ctx, "SELECT event_id::text FROM outbox ORDER BY id")
	if err != nil {
		t.Fatal(err)
	}
	idOrder, err = pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return []string{ev1.GetMeta().GetEventId(), ev2.GetMeta().GetEventId()}, idOrder
}

func TestLockingEntityBeforeWriteKeepsCommitOrder(t *testing.T) {
	pool := newDB(t, "lockfirst")
	brokers := cluster(t, 1)

	commitOrder, idOrder := concurrentWrites(t, pool, true)
	if strings.Join(idOrder, ",") != strings.Join(commitOrder, ",") {
		t.Fatalf("outbox id order %v, want commit order %v", idOrder, commitOrder)
	}
	r, _ := newRelay(pool, newClient(t, brokers))
	start(t, r)
	if sent := eventIDs(t, consume(t, brokers, 2, 0)); strings.Join(sent, ",") != strings.Join(commitOrder, ",") {
		t.Errorf("sent %v, want commit order %v", sent, commitOrder)
	}
}

// Shows why Write must come after the lock: otherwise id order and commit order disagree, and
// the relay sends the video's events in the wrong order.
func TestWritingBeforeLockingBreaksCommitOrder(t *testing.T) {
	pool := newDB(t, "writefirst")
	commitOrder, idOrder := concurrentWrites(t, pool, false)
	if len(idOrder) != 2 || idOrder[0] != commitOrder[1] || idOrder[1] != commitOrder[0] {
		t.Errorf("outbox id order %v, want the reverse of commit order %v", idOrder, commitOrder)
	}
}
