// Package server implements svp.feed.v1.FeedService: the caller's following feed from their own
// timeline and the explore feed of every READY video, both newest first with keyset pagination
// (docs/adr/0009-engagement-feed-stage2b.md, section 8; docs/architecture.md §8.3).
package server

import (
	"context"
	"log/slog"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	feedv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/feed/v1"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/internal/pagetoken"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/internal/store"
)

// Page sizes (AIP-158, feed_service.proto).
const (
	DefaultPageSize = 10
	MaxPageSize     = 50
)

// ErrorInfo reasons returned by the service.
const (
	ReasonInvalidPageSize  = "INVALID_PAGE_SIZE"
	ReasonInvalidPageToken = "INVALID_PAGE_TOKEN"
)

// Server serves FeedService from the read model alone. Every RPC expects the caller id that
// callerid.UnaryServerInterceptor puts into the context.
type Server struct {
	feedv1.UnimplementedFeedServiceServer

	queries *store.Queries
	logger  *slog.Logger
}

// New returns a Server reading through pool.
func New(pool *pgxpool.Pool, logger *slog.Logger) *Server {
	return &Server{queries: store.New(pool), logger: logger}
}

// CallerInterceptor requires the caller's x-user-id on every FeedService RPC. Only the health
// check is public: the healthcheck subcommand and probes call it without a user.
func CallerInterceptor() grpc.UnaryServerInterceptor {
	return callerid.UnaryServerInterceptor(healthpb.Health_Check_FullMethodName)
}

// page is a parsed page request: how many rows to read and where to start.
type page struct {
	size int32
	// before is the cursor of the token; nil for the first page.
	before *pagetoken.Cursor
}

// GetFollowingFeed returns a page of the caller's own timeline of the last 30 days. The user
// whose timeline is read always comes from x-user-id, never from the token (threat model PG-1).
func (s *Server) GetFollowingFeed(ctx context.Context, req *feedv1.GetFollowingFeedRequest) (*feedv1.GetFollowingFeedResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	p, err := parsePage(req.GetPageSize(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	params := store.GetFollowingFeedParams{UserID: caller, RowLimit: p.size + 1}
	params.BeforePublishedAt, params.BeforeVideoID = p.cursorArgs()
	rows, err := s.queries.GetFollowingFeed(ctx, params)
	if err != nil {
		return nil, s.internal(ctx, "select following feed", err)
	}
	items, next := pageOf(rows, p.size)
	return &feedv1.GetFollowingFeedResponse{Items: items, NextPageToken: next}, nil
}

// GetExploreFeed returns a page of every READY video, the same for every caller.
func (s *Server) GetExploreFeed(ctx context.Context, req *feedv1.GetExploreFeedRequest) (*feedv1.GetExploreFeedResponse, error) {
	if _, err := callerID(ctx); err != nil {
		return nil, err
	}
	p, err := parsePage(req.GetPageSize(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	params := store.GetExploreFeedParams{RowLimit: p.size + 1}
	params.BeforePublishedAt, params.BeforeVideoID = p.cursorArgs()
	rows, err := s.queries.GetExploreFeed(ctx, params)
	if err != nil {
		return nil, s.internal(ctx, "select explore feed", err)
	}
	following := make([]store.GetFollowingFeedRow, len(rows))
	for i, r := range rows {
		// Both queries select the same columns, so their row types convert into each other.
		following[i] = store.GetFollowingFeedRow(r)
	}
	items, next := pageOf(following, p.size)
	return &feedv1.GetExploreFeedResponse{Items: items, NextPageToken: next}, nil
}

// parsePage checks page_size (0 means DefaultPageSize, above MaxPageSize means MaxPageSize,
// negative is rejected) and decodes page_token ("" is the first page).
func parsePage(size int32, token string) (page, error) {
	switch {
	case size < 0:
		return page{}, grpcerr.New(codes.InvalidArgument, ReasonInvalidPageSize, "page_size must not be negative")
	case size == 0:
		size = DefaultPageSize
	case size > MaxPageSize:
		size = MaxPageSize
	}
	p := page{size: size}
	if token != "" {
		c, err := pagetoken.Decode(token)
		if err != nil {
			return page{}, grpcerr.New(codes.InvalidArgument, ReasonInvalidPageToken, "page_token is not a token this service returned")
		}
		p.before = &c
	}
	return p, nil
}

// cursorArgs returns the query arguments of the cursor: a NULL time for the first page, which
// the queries read as "before infinity".
func (p page) cursorArgs() (*time.Time, uuid.UUID) {
	if p.before == nil {
		return nil, uuid.UUID{}
	}
	return &p.before.PublishedAt, p.before.VideoID
}

// pageOf turns up to size+1 rows into the items of the page and the token of the next one: an
// extra row means there is a next page, which starts after the page's last item.
func pageOf(rows []store.GetFollowingFeedRow, size int32) ([]*feedv1.FeedItem, string) {
	next := ""
	if len(rows) > int(size) {
		rows = rows[:size]
		last := rows[len(rows)-1]
		next = pagetoken.Encode(pagetoken.Cursor{PublishedAt: last.PublishedAt, VideoID: last.VideoID})
	}
	items := make([]*feedv1.FeedItem, len(rows))
	for i, r := range rows {
		items[i] = &feedv1.FeedItem{
			VideoId:      r.VideoID.String(),
			AuthorId:     r.AuthorID.String(),
			Title:        r.Title,
			Duration:     durationpb.New(time.Duration(r.DurationMs) * time.Millisecond),
			PlaylistKey:  r.PlaylistKey,
			ThumbnailKey: r.ThumbnailKey,
			PublishedAt:  timestamppb.New(r.PublishedAt),
		}
	}
	return items, next
}

// callerID returns the caller put into ctx by the callerid interceptor, which has already
// checked it is a canonical UUID. Without one the server was wired without the interceptor:
// fail closed rather than serve an anonymous caller.
func callerID(ctx context.Context) (uuid.UUID, error) {
	id, ok := callerid.FromContext(ctx)
	if !ok {
		return uuid.UUID{}, status.Error(codes.Unauthenticated, "missing caller identity")
	}
	return uuid.MustParse(id), nil
}

// internal logs err with what failed and returns a generic INTERNAL error, so database details
// never reach the caller.
func (s *Server) internal(ctx context.Context, what string, err error) error {
	s.logger.ErrorContext(ctx, what, slog.Any("error", err))
	return status.Error(codes.Internal, "internal error")
}
