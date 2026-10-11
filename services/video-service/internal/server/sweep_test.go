package server

import (
	"context"
	"log/slog"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc/codes"

	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/services/video-service/migrations"
)

const testAbandonAfter = time.Hour

// sweepEnv is a server on a database of its own, so the sweep sees only the test's videos.
type sweepEnv struct {
	pool *pgxpool.Pool
	srv  *Server
	logs *logBuffer
}

func newSweepEnv(t *testing.T, name string, storage Storage) *sweepEnv {
	t.Helper()
	pool := pgtest.New(t, "svp_video_sweep_"+name+"_test", migrations.FS)
	logs := &logBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))
	return &sweepEnv{pool: pool, srv: New(pool, storage, logger), logs: logs}
}

func (e *sweepEnv) sweeper() *UploadSweeper {
	return e.srv.NewUploadSweeper(testAbandonAfter, time.Hour)
}

// insert stores a video of a new author in st, created age ago, and returns its id.
func (e *sweepEnv) insert(t *testing.T, st string, age time.Duration) string {
	t.Helper()
	id := ids.New()
	_, err := e.pool.Exec(t.Context(), `
		INSERT INTO videos (id, author_id, title, status, size_bytes, content_type, created_at)
		VALUES ($1, $2, 'Abandoned', $3, 1000, 'video/mp4', $4)`,
		id, ids.New(), st, time.Now().Add(-age))
	if err != nil {
		t.Fatalf("insert video: %v", err)
	}
	return id
}

func (e *sweepEnv) status(t *testing.T, id string) string {
	t.Helper()
	var st string
	if err := e.pool.QueryRow(t.Context(), "SELECT status FROM videos WHERE id = $1", id).Scan(&st); err != nil {
		t.Fatalf("read video %s: %v", id, err)
	}
	return st
}

func (e *sweepEnv) countStatus(t *testing.T, st string) int {
	t.Helper()
	var n int
	if err := e.pool.QueryRow(t.Context(), "SELECT count(*) FROM videos WHERE status = $1", st).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// lockWaiters returns how many sessions of the env's database wait for a row lock.
func (e *sweepEnv) lockWaiters(t *testing.T) int {
	t.Helper()
	var n int
	err := e.pool.QueryRow(t.Context(), `SELECT count(*) FROM pg_stat_activity
		WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// blockingStorage is a fakeStorage whose Delete announces itself on entered, then waits for
// release (or for its context to end) before deleting.
type blockingStorage struct {
	*fakeStorage
	entered chan string
	release chan struct{}
}

func newBlockingStorage() *blockingStorage {
	return &blockingStorage{fakeStorage: newFakeStorage(), entered: make(chan string, 1000), release: make(chan struct{})}
}

func (b *blockingStorage) Delete(ctx context.Context, key string) error {
	b.entered <- key
	select {
	case <-b.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	return b.fakeStorage.Delete(ctx, key)
}

// The sweep fails only UPLOADING videos older than the cutoff and deletes only their upload,
// whether or not the object is still there.
func TestSweepFailsAbandonedUploads(t *testing.T) {
	storage := newFakeStorage()
	e := newSweepEnv(t, "abandoned", storage)
	withObject := e.insert(t, "UPLOADING", 61*time.Minute)
	storage.put(withObject, 1000, "video/mp4")
	withoutObject := e.insert(t, "UPLOADING", 3*time.Hour)
	recent := e.insert(t, "UPLOADING", 59*time.Minute)
	others := map[string]string{}
	for _, st := range []string{"PROCESSING", "READY", "FAILED"} {
		others[st] = e.insert(t, st, 3*time.Hour)
	}

	if n := e.sweeper().sweep(t.Context()); n != 2 {
		t.Fatalf("sweep() = %d, want 2", n)
	}
	for _, id := range []string{withObject, withoutObject} {
		if st := e.status(t, id); st != "FAILED" {
			t.Errorf("abandoned video status = %s, want FAILED", st)
		}
	}
	if st := e.status(t, recent); st != "UPLOADING" {
		t.Errorf("59-minute-old upload status = %s, want UPLOADING", st)
	}
	for want, id := range others {
		if st := e.status(t, id); st != want {
			t.Errorf("old %s video status = %s, want %s", want, st, want)
		}
	}
	// Oldest first; no DeletePrefix on media/: an UPLOADING video has no HLS output.
	if got, want := storage.deletes(), []string{"uploads/" + withoutObject, "uploads/" + withObject}; !slices.Equal(got, want) {
		t.Errorf("deletes = %v, want %v", got, want)
	}

	recs := e.logs.records(t, "upload abandoned")
	if len(recs) != 2 {
		t.Fatalf("got %d \"upload abandoned\" log lines, want 2", len(recs))
	}
	for _, rec := range recs {
		if rec["video_id"] == nil || rec["user_id"] == nil {
			t.Errorf("log line %v lacks video_id or user_id", rec)
		}
	}
	if recs := e.logs.records(t, "abandoned uploads swept"); len(recs) != 1 || recs[0]["videos"] != float64(2) {
		t.Errorf("round log = %v, want one line with videos 2", recs)
	}

	// Nothing left: the next round does nothing and logs no round line.
	if n := e.sweeper().sweep(t.Context()); n != 0 {
		t.Errorf("second sweep() = %d, want 0", n)
	}
	if recs := e.logs.records(t, "abandoned uploads swept"); len(recs) != 1 {
		t.Errorf("got %d round log lines, want 1", len(recs))
	}
}

// A video whose delete fails stays UPLOADING, the others of the batch still fail, and the next
// round retries it.
func TestSweepKeepsVideoWhoseDeleteFails(t *testing.T) {
	storage := newFakeStorage()
	e := newSweepEnv(t, "deletefails", storage)
	first := e.insert(t, "UPLOADING", 3*time.Hour)
	second := e.insert(t, "UPLOADING", 2*time.Hour)

	storage.setFailDeletes(1)
	if n := e.sweeper().sweep(t.Context()); n != 1 {
		t.Fatalf("sweep() = %d, want 1", n)
	}
	if st := e.status(t, first); st != "UPLOADING" {
		t.Errorf("video whose delete failed: status %s, want UPLOADING", st)
	}
	if st := e.status(t, second); st != "FAILED" {
		t.Errorf("other video: status %s, want FAILED", st)
	}

	if n := e.sweeper().sweep(t.Context()); n != 1 {
		t.Fatalf("next sweep() = %d, want 1", n)
	}
	if st := e.status(t, first); st != "FAILED" {
		t.Errorf("after the next round: status %s, want FAILED", st)
	}
}

// A full batch that failed every video is followed by the next one in the same round.
func TestSweepCleansMoreThanOneBatch(t *testing.T) {
	storage := newFakeStorage()
	e := newSweepEnv(t, "batches", storage)
	const total = 2*sweepBatchSize + 50
	for range total {
		e.insert(t, "UPLOADING", 2*time.Hour)
	}

	if n := e.sweeper().sweep(t.Context()); n != total {
		t.Fatalf("sweep() = %d, want %d", n, total)
	}
	if n := e.countStatus(t, "UPLOADING"); n != 0 {
		t.Errorf("%d videos still UPLOADING, want 0", n)
	}
	if recs := e.logs.records(t, "abandoned uploads swept"); len(recs) != 1 || recs[0]["videos"] != float64(total) {
		t.Errorf("round log = %v, want one line with videos %d", recs, total)
	}
}

// With every delete failing and more than a batch of abandoned videos, the round ends after one
// batch instead of selecting the same videos again; the next round, with storage back, cleans
// them all.
func TestSweepEndsRoundWhenDeletesFail(t *testing.T) {
	storage := newFakeStorage()
	e := newSweepEnv(t, "storagedown", storage)
	const total = sweepBatchSize + 50
	for range total {
		e.insert(t, "UPLOADING", 2*time.Hour)
	}

	const failing = 10 * total
	storage.setFailDeletes(failing)
	done := make(chan int, 1)
	go func() { done <- e.sweeper().sweep(t.Context()) }()
	select {
	case n := <-done:
		if n != 0 {
			t.Fatalf("sweep() = %d, want 0", n)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("sweep() did not end with storage failing")
	}
	storage.mu.Lock()
	attempts := failing - storage.failDeletes
	storage.mu.Unlock()
	if attempts != sweepBatchSize {
		t.Errorf("%d delete attempts, want one batch of %d", attempts, sweepBatchSize)
	}
	if n := e.countStatus(t, "UPLOADING"); n != total {
		t.Errorf("%d videos UPLOADING, want %d", n, total)
	}

	storage.setFailDeletes(0)
	if n := e.sweeper().sweep(t.Context()); n != total {
		t.Errorf("next sweep() = %d, want %d", n, total)
	}
}

// A batch that runs out of time rolls back: the video stays UPLOADING.
func TestSweepBatchTimeoutRollsBack(t *testing.T) {
	storage := newBlockingStorage()
	e := newSweepEnv(t, "timeout", storage)
	id := e.insert(t, "UPLOADING", 2*time.Hour)

	w := e.sweeper()
	w.batchTimeout = 200 * time.Millisecond
	if n := w.sweep(t.Context()); n != 0 {
		t.Fatalf("sweep() = %d, want 0", n)
	}
	if st := e.status(t, id); st != "UPLOADING" {
		t.Errorf("status = %s, want UPLOADING", st)
	}
	if recs := e.logs.records(t, "upload sweep failed"); len(recs) != 1 {
		t.Errorf("got %d \"upload sweep failed\" log lines, want 1", len(recs))
	}
}

// Two instances sweeping at the same time: the one holding the sweep lock does the work, the
// other skips its round.
func TestSweepRunsOnOneInstanceAtATime(t *testing.T) {
	storage := newBlockingStorage()
	e := newSweepEnv(t, "oneinstance", storage)
	id := e.insert(t, "UPLOADING", 2*time.Hour)

	first := make(chan int, 1)
	go func() { first <- e.sweeper().sweep(t.Context()) }()
	<-storage.entered // the first instance holds the lock and the row

	// A second instance on its own server, as another replica would be.
	second := New(e.pool, storage, slog.New(slog.DiscardHandler)).NewUploadSweeper(testAbandonAfter, time.Hour)
	if n := second.sweep(t.Context()); n != 0 {
		t.Errorf("second instance sweep() = %d, want 0", n)
	}
	if len(storage.entered) != 0 {
		t.Error("the second instance called Delete")
	}

	close(storage.release)
	if n := <-first; n != 1 {
		t.Errorf("first instance sweep() = %d, want 1", n)
	}
	if st := e.status(t, id); st != "FAILED" {
		t.Errorf("status = %s, want FAILED", st)
	}
}

// CompleteUpload of a video the sweep holds waits for the sweep, then answers VIDEO_FAILED and
// emits nothing.
func TestCompleteUploadWaitsForSweep(t *testing.T) {
	storage := newBlockingStorage()
	e := newSweepEnv(t, "sweepfirst", storage)
	author := ids.New()
	id := ids.New()
	if _, err := e.pool.Exec(t.Context(), `
		INSERT INTO videos (id, author_id, title, status, size_bytes, content_type, created_at)
		VALUES ($1, $2, 'Late', 'UPLOADING', $3, 'video/mp4', $4)`,
		id, author, validRequest().GetSizeBytes(), time.Now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	storage.put(id, validRequest().GetSizeBytes(), "video/mp4")

	swept := make(chan int, 1)
	go func() { swept <- e.sweeper().sweep(t.Context()) }()
	<-storage.entered
	completed := make(chan error, 1)
	go func() {
		_, err := completeUpload(t.Context(), t, e.srv, author, id)
		completed <- err
	}()
	eventually(t, "CompleteUpload to wait for the row lock", func() bool { return e.lockWaiters(t) == 1 })
	close(storage.release)

	if n := <-swept; n != 1 {
		t.Errorf("sweep() = %d, want 1", n)
	}
	wantError(t, <-completed, codes.FailedPrecondition, ReasonVideoFailed)
	var events int
	if err := e.pool.QueryRow(t.Context(), "SELECT count(*) FROM outbox").Scan(&events); err != nil {
		t.Fatal(err)
	}
	if events != 0 {
		t.Errorf("got %d outbox rows, want 0", events)
	}
}

// A video CompleteUpload moves while the sweep waits for its row is re-checked after the lock is
// released and skipped: it stays PROCESSING and its upload is not deleted.
func TestSweepSkipsVideoCompletedMeanwhile(t *testing.T) {
	storage := newFakeStorage()
	e := newSweepEnv(t, "completefirst", storage)
	id := e.insert(t, "UPLOADING", 2*time.Hour)
	ctx := t.Context()

	// What CompleteUpload's transaction does before it commits.
	holder, err := e.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(ctx, "UPDATE videos SET status = 'PROCESSING' WHERE id = $1 AND status = 'UPLOADING'", id); err != nil {
		t.Fatal(err)
	}
	swept := make(chan int, 1)
	go func() { swept <- e.sweeper().sweep(ctx) }()
	eventually(t, "the sweep to wait for the row lock", func() bool { return e.lockWaiters(t) == 1 })
	if err := holder.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	if n := <-swept; n != 0 {
		t.Errorf("sweep() = %d, want 0", n)
	}
	if st := e.status(t, id); st != "PROCESSING" {
		t.Errorf("status = %s, want PROCESSING", st)
	}
	if d := storage.deletes(); len(d) != 0 {
		t.Errorf("deletes = %v, want none", d)
	}
}

// Run sweeps at start, without waiting for the first tick, and returns when ctx is canceled.
func TestSweeperRunSweepsAtStartAndStops(t *testing.T) {
	e := newSweepEnv(t, "run", newFakeStorage())
	id := e.insert(t, "UPLOADING", 2*time.Hour)

	ctx, cancel := context.WithCancel(t.Context())
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		e.sweeper().Run(ctx)
	}()
	eventually(t, "the video to fail", func() bool { return e.status(t, id) == "FAILED" })
	cancel()
	select {
	case <-stopped:
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
}
