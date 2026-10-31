package server

import (
	"log/slog"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/logx"
)

const methodGetPublicVideo = "/svp.video.v1.VideoService/GetPublicVideo"

func getPublicVideo(t *testing.T, s *Server, caller, videoID string) (*videov1.GetPublicVideoResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodGetPublicVideo, &videov1.GetPublicVideoRequest{VideoId: videoID}, s.GetPublicVideo)
}

// wantSameAsMissing fails unless err is exactly the error GetVideo returns for a missing video:
// same code, reason and message.
func wantSameAsMissing(t *testing.T, what string, err error) {
	t.Helper()
	if status.Code(err) != codes.NotFound || grpcerr.Reason(err) != ReasonVideoNotFound ||
		status.Convert(err).Message() != "video not found" {
		t.Errorf("%s: err = %v, want NOT_FOUND %s with message %q", what, err, ReasonVideoNotFound, "video not found")
	}
}

// A READY video reaches anyone; x-user-id, valid or not, changes nothing.
func TestGetPublicVideoReturnsReadyVideo(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	id, author := ids.New(), ids.New()
	created := time.Date(2026, 10, 22, 8, 0, 0, 123456000, time.UTC)
	published := created.Add(90 * time.Second)
	insertVideo(t, id, author, "READY", true, published, created)

	for _, caller := range []string{"", ids.New(), author, "not-a-uuid"} {
		resp, err := getPublicVideo(t, s, caller, id)
		if err != nil {
			t.Fatalf("GetPublicVideo with x-user-id %q: %v", caller, err)
		}
		v := resp.GetVideo()
		if v.GetVideoId() != id || v.GetAuthorId() != author || v.GetStatus() != videov1.VideoStatus_VIDEO_STATUS_READY ||
			v.GetDuration().AsDuration() != 83250*time.Millisecond ||
			v.GetPlaylistKey() != "media/"+id+"/master.m3u8" || v.GetThumbnailKey() != "media/"+id+"/thumb.jpg" ||
			!v.GetCreatedAt().AsTime().Equal(created) || !v.GetPublishedAt().AsTime().Equal(published) {
			t.Errorf("GetPublicVideo with x-user-id %q = %v", caller, v)
		}
	}
}

// Every video that is not READY looks exactly like a missing one, even to its author: the answer
// is the same for everyone (UP-3).
func TestGetPublicVideoHidesUnpublished(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()

	_, err := getPublicVideo(t, s, "", ids.New())
	wantSameAsMissing(t, "missing video", err)

	uploaded, err := initUpload(t, s, author, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	hidden := map[string]string{"UPLOADING": uploaded.GetVideoId()}
	for _, st := range []string{"PROCESSING", "FAILED"} {
		hidden[st] = ids.New()
		insertVideo(t, hidden[st], author, st, false, time.Time{}, time.Now())
	}
	for st, id := range hidden {
		for _, caller := range []string{"", author} {
			_, err := getPublicVideo(t, s, caller, id)
			wantSameAsMissing(t, st+" video, x-user-id "+caller, err)
		}
	}
}

// A malformed id gets the same NOT_FOUND, not INVALID_ARGUMENT, and is rejected before the
// database is read: the server has no pool, so a query would panic.
func TestGetPublicVideoMalformedIDIsNotFound(t *testing.T) {
	s := New(nil, newFakeStorage(), slog.New(logx.NewHandler(slog.DiscardHandler)))
	for _, id := range []string{"", "not-a-uuid", strings.ToUpper(ids.New()), "{" + ids.New() + "}", "urn:uuid:" + ids.New()} {
		_, err := getPublicVideo(t, s, "", id)
		wantSameAsMissing(t, "id "+id, err)
	}
}
