package server

import (
	"cmp"
	"slices"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"

	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/pagetoken"
)

const methodListAuthorVideos = "/svp.video.v1.VideoService/ListAuthorVideos"

func listAuthorVideos(t *testing.T, s *Server, caller string, req *videov1.ListAuthorVideosRequest) (*videov1.ListAuthorVideosResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodListAuthorVideos, req, s.ListAuthorVideos)
}

// listed is a video a test inserted, with what decides its place in the list.
type listed struct {
	id, status string
	createdAt  time.Time
}

// insertListed inserts videos of author and returns them newest first by (created_at, id), the
// order ListAuthorVideos must follow.
func insertListed(t *testing.T, author string, videos ...listed) []listed {
	t.Helper()
	for _, v := range videos {
		insertVideo(t, v.id, author, v.status, v.status == "READY", v.createdAt.Add(time.Minute), v.createdAt)
	}
	out := slices.Clone(videos)
	slices.SortFunc(out, func(a, b listed) int {
		// Canonical lowercase UUIDs compare as text the way Postgres compares uuid.
		return cmp.Or(b.createdAt.Compare(a.createdAt), strings.Compare(b.id, a.id))
	})
	return out
}

// idsOf returns the ids of videos, keeping only READY ones when readyOnly.
func idsOf(videos []listed, readyOnly bool) []string {
	var out []string
	for _, v := range videos {
		if !readyOnly || v.status == "READY" {
			out = append(out, v.id)
		}
	}
	return out
}

// walk reads every page of author's list as caller, pageSize videos at a time, and returns the ids
// in the order received; it fails on a page larger than pageSize or a token on an empty page.
func walk(t *testing.T, s *Server, caller, author string, pageSize int32) []string {
	t.Helper()
	var got []string
	token := ""
	for page := 0; ; page++ {
		if page > 100 {
			t.Fatal("more than 100 pages: the token does not advance")
		}
		resp, err := listAuthorVideos(t, s, caller, &videov1.ListAuthorVideosRequest{
			AuthorId: author, PageSize: pageSize, PageToken: token,
		})
		if err != nil {
			t.Fatalf("page %d: %v", page, err)
		}
		if n := len(resp.GetVideos()); n > int(pageSize) || (n == 0 && resp.GetNextPageToken() != "") {
			t.Fatalf("page %d: %d videos with next_page_token %q, page size %d", page, n, resp.GetNextPageToken(), pageSize)
		}
		for _, v := range resp.GetVideos() {
			got = append(got, v.GetVideoId())
		}
		token = resp.GetNextPageToken()
		if token == "" {
			return got
		}
	}
}

// mixedVideos is a list of every status where several videos share a created_at, at the start,
// in the middle and at the end, so page boundaries fall between equal times.
func mixedVideos() []listed {
	base := time.Date(2026, 10, 22, 9, 0, 0, 123456000, time.UTC)
	statuses := []string{"READY", "UPLOADING", "READY", "FAILED", "READY", "PROCESSING", "READY", "READY", "UPLOADING", "READY", "READY"}
	offsets := []time.Duration{0, 0, 0, time.Second, 2 * time.Second, 2 * time.Second, 2 * time.Second, 2 * time.Second, 3 * time.Second, 4 * time.Second, 4 * time.Second}
	out := make([]listed, len(statuses))
	for i := range statuses {
		out[i] = listed{id: ids.New(), status: statuses[i], createdAt: base.Add(offsets[i])}
	}
	return out
}

// Paged through at every size, the list holds each video once, newest first, with no gap where
// created_at repeats across a page boundary: every status for the author, only READY for others.
func TestListAuthorVideosPagesAcrossEqualCreatedAt(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author, other := ids.New(), ids.New()
	want := insertListed(t, author, mixedVideos()...)
	// Videos of another author never show up.
	insertListed(t, other, listed{id: ids.New(), status: "READY", createdAt: want[0].createdAt})

	for _, size := range []int32{1, 2, 3, 4, 50} {
		if got, w := walk(t, s, author, author, size), idsOf(want, false); !slices.Equal(got, w) {
			t.Errorf("author, page size %d:\n got %v\nwant %v", size, got, w)
		}
		if got, w := walk(t, s, other, author, size), idsOf(want, true); !slices.Equal(got, w) {
			t.Errorf("other user, page size %d:\n got %v\nwant %v", size, got, w)
		}
	}
}

func TestListAuthorVideosAuthorSeesEveryStatus(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()
	uploaded, err := initUpload(t, s, author, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	readyID := ids.New()
	insertVideo(t, readyID, author, "READY", true, time.Now(), time.Now().Add(-time.Hour))

	resp, err := listAuthorVideos(t, s, author, &videov1.ListAuthorVideosRequest{AuthorId: author})
	if err != nil {
		t.Fatal(err)
	}
	got := resp.GetVideos()
	if len(got) != 2 || resp.GetNextPageToken() != "" {
		t.Fatalf("got %d videos, next_page_token %q; want 2 and none", len(got), resp.GetNextPageToken())
	}
	// The UPLOADING video was created after the READY one, so it comes first.
	if got[0].GetVideoId() != uploaded.GetVideoId() || got[0].GetStatus() != videov1.VideoStatus_VIDEO_STATUS_UPLOADING ||
		got[0].GetPublishedAt() != nil || got[0].GetPlaylistKey() != "" {
		t.Errorf("first video = %v, want the UPLOADING one without media", got[0])
	}
	if got[1].GetVideoId() != readyID || got[1].GetStatus() != videov1.VideoStatus_VIDEO_STATUS_READY ||
		got[1].GetPlaylistKey() != "media/"+readyID+"/master.m3u8" {
		t.Errorf("second video = %v, want the READY one with its media", got[1])
	}
}

// The token holds a position only: a token the author got, used by someone else, lists only the
// READY videos after that position (PG-1, UP-3).
func TestListAuthorVideosBorrowedTokenShowsNoHiddenVideo(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()
	want := insertListed(t, author, mixedVideos()...)

	resp, err := listAuthorVideos(t, s, author, &videov1.ListAuthorVideosRequest{AuthorId: author, PageSize: 2})
	if err != nil {
		t.Fatal(err)
	}
	token := resp.GetNextPageToken()
	if token == "" {
		t.Fatal("no next_page_token after the author's first page")
	}
	resp, err = listAuthorVideos(t, s, ids.New(), &videov1.ListAuthorVideosRequest{AuthorId: author, PageSize: 50, PageToken: token})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, v := range resp.GetVideos() {
		got = append(got, v.GetVideoId())
	}
	if w := idsOf(want[2:], true); !slices.Equal(got, w) {
		t.Errorf("other user with the author's token:\n got %v\nwant %v", got, w)
	}

	// A token made by hand at a position before every video still lists only READY ones.
	forged := pagetoken.Encode(pagetoken.Cursor{Time: time.Date(9999, 1, 1, 0, 0, 0, 0, time.UTC)})
	resp, err = listAuthorVideos(t, s, ids.New(), &videov1.ListAuthorVideosRequest{AuthorId: author, PageSize: 50, PageToken: forged})
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range resp.GetVideos() {
		if v.GetStatus() != videov1.VideoStatus_VIDEO_STATUS_READY {
			t.Errorf("forged token listed %s video %s to another user", v.GetStatus(), v.GetVideoId())
		}
	}
	if len(resp.GetVideos()) != len(idsOf(want, true)) {
		t.Errorf("forged token listed %d videos, want the %d READY ones", len(resp.GetVideos()), len(idsOf(want, true)))
	}
}

func TestListAuthorVideosPageSize(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()
	base := time.Date(2026, 10, 22, 10, 0, 0, 0, time.UTC)
	for i := range MaxPageSize + 2 {
		insertVideo(t, ids.New(), author, "READY", true, base, base.Add(time.Duration(i)*time.Second))
	}
	for _, tc := range []struct {
		size int32
		want int
	}{{0, DefaultPageSize}, {1, 1}, {MaxPageSize, MaxPageSize}, {MaxPageSize + 1, MaxPageSize}, {1 << 30, MaxPageSize}} {
		resp, err := listAuthorVideos(t, s, author, &videov1.ListAuthorVideosRequest{AuthorId: author, PageSize: tc.size})
		if err != nil {
			t.Fatalf("page_size %d: %v", tc.size, err)
		}
		if len(resp.GetVideos()) != tc.want || resp.GetNextPageToken() == "" {
			t.Errorf("page_size %d: %d videos, next_page_token %q; want %d and a token", tc.size, len(resp.GetVideos()), resp.GetNextPageToken(), tc.want)
		}
	}
}

func TestListAuthorVideosWithoutVideosIsEmpty(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()
	for _, caller := range []string{author, ids.New()} {
		resp, err := listAuthorVideos(t, s, caller, &videov1.ListAuthorVideosRequest{AuthorId: author})
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.GetVideos()) != 0 || resp.GetNextPageToken() != "" {
			t.Errorf("caller %s: %v, want an empty page without token", caller, resp)
		}
	}
}

// Invalid requests are rejected before the database is read: the server has no pool.
func TestListAuthorVideosInvalidRequest(t *testing.T) {
	s, _ := newServer()
	s.queries = nil
	caller := ids.New()
	valid := pagetoken.Encode(pagetoken.Cursor{Time: time.Now(), VideoID: [16]byte{1}})
	for _, tc := range []struct {
		name   string
		req    *videov1.ListAuthorVideosRequest
		reason string
	}{
		{"empty author_id", &videov1.ListAuthorVideosRequest{}, ReasonInvalidAuthorID},
		{"author_id not a UUID", &videov1.ListAuthorVideosRequest{AuthorId: "me"}, ReasonInvalidAuthorID},
		{"upper case author_id", &videov1.ListAuthorVideosRequest{AuthorId: strings.ToUpper(caller)}, ReasonInvalidAuthorID},
		{"page_size -1", &videov1.ListAuthorVideosRequest{AuthorId: caller, PageSize: -1}, ReasonInvalidPageSize},
		{"page_size min int32", &videov1.ListAuthorVideosRequest{AuthorId: caller, PageSize: -1 << 31}, ReasonInvalidPageSize},
		{"garbage token", &videov1.ListAuthorVideosRequest{AuthorId: caller, PageToken: "%%%"}, ReasonInvalidPageToken},
		{"edited token", &videov1.ListAuthorVideosRequest{AuthorId: caller, PageToken: valid[:len(valid)-4]}, ReasonInvalidPageToken},
		{"token over 64 characters", &videov1.ListAuthorVideosRequest{AuthorId: caller, PageToken: valid + strings.Repeat("A", pagetoken.MaxLen)}, ReasonInvalidPageToken},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := listAuthorVideos(t, s, caller, tc.req)
			wantError(t, err, codes.InvalidArgument, tc.reason)
		})
	}
}
