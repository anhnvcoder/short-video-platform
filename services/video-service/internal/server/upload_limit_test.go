package server

import (
	"context"
	"errors"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/anhnvcoder/svp-backend/internal/ids"
)

// uploadingCount returns how many videos of author are UPLOADING.
func uploadingCount(t *testing.T, author string) int {
	t.Helper()
	var n int
	err := testPool.QueryRow(t.Context(),
		"SELECT count(*) FROM videos WHERE author_id = $1 AND status = 'UPLOADING'", author).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestInitUploadLimitsOpenUploads(t *testing.T) {
	needDB(t)
	s, logs := newServer()
	author := ids.New()
	for i := range MaxOpenUploads {
		if _, err := initUpload(t, s, author, validRequest()); err != nil {
			t.Fatalf("upload %d: %v", i+1, err)
		}
	}

	_, err := initUpload(t, s, author, validRequest())
	wantError(t, err, codes.ResourceExhausted, ReasonTooManyUploads)
	if n := uploadingCount(t, author); n != MaxOpenUploads {
		t.Errorf("author has %d videos UPLOADING, want %d", n, MaxOpenUploads)
	}
	// The refused video is never stored, so the log carries no video_id.
	if recs := logs.records(t, "too many uploads in progress"); len(recs) != 1 || recs[0]["user_id"] != author ||
		recs[0]["video_id"] != nil {
		t.Errorf("rejection log = %v, want one line with user_id %s and without video_id", recs, author)
	}

	if _, err := initUpload(t, s, ids.New(), validRequest()); err != nil {
		t.Errorf("InitUpload of another user: %v", err)
	}
}

// A form that cannot be signed (the credential endpoint is down) stores no video, so failed calls
// do not use up the caller's open uploads.
func TestInitUploadSigningFailureStoresNothing(t *testing.T) {
	needDB(t)
	s, storage, logs := newServerWithStorage()
	author := ids.New()
	storage.setPresignErr(errors.New("objstore: presign post: get credentials: agent unreachable"))
	for range MaxOpenUploads + 1 {
		_, err := initUpload(t, s, author, validRequest())
		if status.Code(err) != codes.Internal {
			t.Fatalf("InitUpload() with signing failing: %v, want INTERNAL", err)
		}
	}
	if n := uploadingCount(t, author); n != 0 {
		t.Errorf("author has %d videos UPLOADING after failed signing, want 0", n)
	}
	if recs := logs.records(t, "video created"); len(recs) != 0 {
		t.Errorf("logged %d \"video created\" lines for videos never stored", len(recs))
	}

	storage.setPresignErr(nil)
	for i := range MaxOpenUploads {
		if _, err := initUpload(t, s, author, validRequest()); err != nil {
			t.Fatalf("upload %d after signing recovered: %v", i+1, err)
		}
	}
}

// Only UPLOADING videos created within the form's lifetime count, and only the caller's own.
func TestInitUploadLimitCountsOnlyOpenForms(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author, other := ids.New(), ids.New()
	now := time.Now()
	for range MaxOpenUploads {
		insertVideo(t, ids.New(), author, "UPLOADING", false, time.Time{}, now.Add(-uploadFormTTL-time.Minute))
		insertVideo(t, ids.New(), author, "PROCESSING", false, time.Time{}, now)
		insertVideo(t, ids.New(), author, "READY", true, now, now)
		insertVideo(t, ids.New(), author, "FAILED", false, time.Time{}, now)
		insertVideo(t, ids.New(), other, "UPLOADING", false, time.Time{}, now)
	}

	for i := range MaxOpenUploads {
		if _, err := initUpload(t, s, author, validRequest()); err != nil {
			t.Fatalf("upload %d: %v", i+1, err)
		}
	}
	_, err := initUpload(t, s, author, validRequest())
	wantError(t, err, codes.ResourceExhausted, ReasonTooManyUploads)
}

func TestInitUploadLimitCountsFormsStillValid(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()
	for range MaxOpenUploads {
		insertVideo(t, ids.New(), author, "UPLOADING", false, time.Time{}, time.Now().Add(-uploadFormTTL+time.Minute))
	}
	_, err := initUpload(t, s, author, validRequest())
	wantError(t, err, codes.ResourceExhausted, ReasonTooManyUploads)
}

// Two calls of a user with one upload left: the per-author lock makes the second count after the
// first inserts, so exactly one succeeds.
func TestConcurrentInitUploadRespectsLimit(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()
	for range MaxOpenUploads - 1 {
		if _, err := initUpload(t, s, author, validRequest()); err != nil {
			t.Fatal(err)
		}
	}
	ctx := t.Context()

	// Hold the author's lock so both calls are waiting for it before either counts.
	holder, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(ctx,
		"SELECT pg_advisory_xact_lock(hashtextextended('video-upload-author:' || $1::uuid::text, 0))", author); err != nil {
		t.Fatal(err)
	}
	results := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := initUpload(t, s, author, validRequest())
			results <- err
		}()
	}
	eventually(t, "both calls to wait for the author lock", func() bool {
		var waiting int
		err := testPool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock' AND wait_event = 'advisory'`).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting == 2
	})
	if err := holder.Rollback(ctx); err != nil {
		t.Fatal(err)
	}

	var ok, rejected int
	for range 2 {
		if err := <-results; err != nil {
			wantError(t, err, codes.ResourceExhausted, ReasonTooManyUploads)
			rejected++
		} else {
			ok++
		}
	}
	if ok != 1 || rejected != 1 {
		t.Errorf("%d calls succeeded and %d were rejected, want 1 and 1", ok, rejected)
	}
	if n := uploadingCount(t, author); n != MaxOpenUploads {
		t.Errorf("author has %d videos UPLOADING, want %d", n, MaxOpenUploads)
	}
}
