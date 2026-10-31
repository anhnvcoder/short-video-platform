package server

import (
	"context"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	engagementv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
)

// Without a caller GetStats returns the same counters as with one, and liked_by_me is false for
// every video, also the ones that have likes.
func TestGetStatsWithoutCaller(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	liker := ids.New()
	a, b, unknown := ids.New(), ids.New(), ids.New()
	for _, v := range []string{a, b} {
		if err := like(t, s, liker, v); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := testPool.Exec(t.Context(), "INSERT INTO view_counts (video_id, view_count) VALUES ($1, 5)", a); err != nil {
		t.Fatal(err)
	}

	request := []string{b, unknown, a, b}
	resp, err := getStats(t, s, "", request...)
	if err != nil {
		t.Fatal(err)
	}
	want := []*engagementv1.VideoStats{
		{VideoId: b, LikeCount: 1},
		{VideoId: unknown},
		{VideoId: a, ViewCount: 5, LikeCount: 1},
		{VideoId: b, LikeCount: 1},
	}
	wantStats(t, resp.GetStats(), want)

	// The liker still sees its likes.
	resp, err = getStats(t, s, liker, request...)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range want {
		w.LikedByMe = w.GetVideoId() != unknown
	}
	wantStats(t, resp.GetStats(), want)
}

// Without a caller the likes table is not read: GetStats answers while another transaction holds
// an exclusive lock on it, which blocks the same call made with a caller.
func TestGetStatsWithoutCallerDoesNotReadLikes(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	videoID := ids.New()
	if err := like(t, s, ids.New(), videoID); err != nil {
		t.Fatal(err)
	}

	tx, err := testPool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(t.Context())) }()
	if _, err := tx.Exec(t.Context(), "LOCK TABLE likes IN ACCESS EXCLUSIVE MODE"); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	resp, err := call(ctx, "", methodGetStats, &engagementv1.GetStatsRequest{VideoIds: []string{videoID}}, s.GetStats)
	if err != nil {
		t.Fatalf("GetStats without caller while likes is locked: %v", err)
	}
	if got := resp.GetStats(); len(got) != 1 || got[0].GetLikeCount() != 1 || got[0].GetLikedByMe() {
		t.Errorf("stats = %v, want like_count 1 and liked_by_me false", got)
	}

	// The control: with a caller the call waits on the lock until its deadline.
	ctx, cancel = context.WithTimeout(t.Context(), 300*time.Millisecond)
	defer cancel()
	_, err = call(ctx, ids.New(), methodGetStats, &engagementv1.GetStatsRequest{VideoIds: []string{videoID}}, s.GetStats)
	if status.Code(err) != codes.Internal {
		t.Errorf("GetStats with caller while likes is locked = %v, want it to wait and fail", err)
	}
}
