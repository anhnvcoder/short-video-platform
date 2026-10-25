// Package server implements svp.engagement.v1.EngagementService: Like and Unlike keep the likes
// and their counter, GetStats reads the counters of up to 50 videos, and RecordView produces
// view.recorded without touching the database.
package server

import (
	"context"
	"fmt"
	"log/slog"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	eventv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/event/v1"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/services/engagement-service/internal/store"
)

const (
	// MaxStatsVideoIDs is the most video ids one GetStats call accepts: a whole feed page, at most
	// 50 videos, in one call.
	MaxStatsVideoIDs = 50
	// TopicViews carries svp.engagement.v1.ViewEvent, keyed by video_id.
	TopicViews = "engagement.views.v1"

	// produceTimeout bounds producing one view.recorded: enough for
	// franz-go to retry through a leader change or a reconnect, short for a side action.
	produceTimeout = 2 * time.Second
	// rollbackTimeout bounds the rollback of a failed transaction, which runs on a context of its
	// own: the caller's may have run out.
	rollbackTimeout = 5 * time.Second
)

// ErrorInfo reasons returned by the service.
const (
	ReasonInvalidVideoID  = "INVALID_VIDEO_ID"
	ReasonTooManyVideoIDs = "TOO_MANY_VIDEO_IDS"
	// ReasonDependencyUnavailable goes with UNAVAILABLE when a dependency of the service (the
	// broker) is down while the service itself runs: the gateway's breaker does not count it.
	ReasonDependencyUnavailable = "DEPENDENCY_UNAVAILABLE"
)

const (
	invalidVideoIDMessage  = "video_id must be a canonical lowercase UUID"
	invalidVideoIDsMessage = "video_ids must be canonical lowercase UUIDs"
)

// Server serves EngagementService. Every RPC expects the caller id that
// callerid.UnaryServerInterceptor puts into the context, except GetStats, whose caller is optional.
type Server struct {
	engagementv1.UnimplementedEngagementServiceServer

	pool     *pgxpool.Pool
	queries  *store.Queries
	producer *kgo.Client
	logger   *slog.Logger
}

// New returns a Server reading and writing through pool and producing view events with producer.
func New(pool *pgxpool.Pool, producer *kgo.Client, logger *slog.Logger) *Server {
	return &Server{pool: pool, queries: store.New(pool), producer: producer, logger: logger}
}

// CallerInterceptor requires the caller's x-user-id on every EngagementService RPC but two. The
// health check is public: the healthcheck subcommand and probes call it without a user. GetStats
// takes an optional caller: the public share page reads counters without one, while a present
// x-user-id must still be valid.
func CallerInterceptor() grpc.UnaryServerInterceptor {
	return callerid.NewUnaryServerInterceptor(callerid.Methods{
		Public:         []string{healthpb.Health_Check_FullMethodName},
		OptionalCaller: []string{engagementv1.EngagementService_GetStats_FullMethodName},
	})
}

// Like records that the caller likes the video. In one transaction it inserts the likes row and,
// only when the row is new, adds one to like_count, so liking twice counts once.
func (s *Server) Like(ctx context.Context, req *engagementv1.LikeRequest) (*engagementv1.LikeResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, invalidVideoIDMessage)
	}
	err = s.inTx(ctx, func(q *store.Queries) error {
		n, err := q.InsertLike(ctx, store.InsertLikeParams{VideoID: videoID, UserID: caller})
		if err != nil || n == 0 {
			return err
		}
		return q.IncrementLikeCount(ctx, videoID)
	})
	if err != nil {
		return nil, s.internal(ctx, "like video", err)
	}
	return &engagementv1.LikeResponse{}, nil
}

// Unlike removes the caller's like. In one transaction it deletes the likes row and, only when a
// row was deleted, takes one from like_count, so unliking a video not liked changes nothing.
func (s *Server) Unlike(ctx context.Context, req *engagementv1.UnlikeRequest) (*engagementv1.UnlikeResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, invalidVideoIDMessage)
	}
	err = s.inTx(ctx, func(q *store.Queries) error {
		n, err := q.DeleteLike(ctx, store.DeleteLikeParams{VideoID: videoID, UserID: caller})
		if err != nil || n == 0 {
			return err
		}
		return q.DecrementLikeCount(ctx, videoID)
	})
	if err != nil {
		return nil, s.internal(ctx, "unlike video", err)
	}
	return &engagementv1.UnlikeResponse{}, nil
}

// inTx runs fn on queries bound to one transaction and commits when fn returns nil, within the
// deadline of ctx.
func (s *Server) inTx(ctx context.Context, fn func(q *store.Queries) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	// After Commit this is a no-op. Once ctx is canceled or past its deadline, the rollback still
	// reaches the server, within a bound of its own.
	defer func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), rollbackTimeout)
		defer cancel()
		_ = tx.Rollback(rctx)
	}()
	if err := fn(s.queries.WithTx(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// GetStats returns the counters of each requested video in request order, a repeated id once per
// occurrence, and zeros for an id never liked or viewed. Without a caller liked_by_me is false for
// every video and no like is read.
func (s *Server) GetStats(ctx context.Context, req *engagementv1.GetStatsRequest) (*engagementv1.GetStatsResponse, error) {
	reqIDs := req.GetVideoIds()
	if len(reqIDs) > MaxStatsVideoIDs {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonTooManyVideoIDs, "at most 50 video_ids are allowed")
	}
	if len(reqIDs) == 0 {
		return &engagementv1.GetStatsResponse{}, nil
	}
	videoIDs := make([]uuid.UUID, len(reqIDs))
	for i, id := range reqIDs {
		var err error
		if videoIDs[i], err = ids.Parse(id); err != nil {
			return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, invalidVideoIDsMessage)
		}
	}

	rows, err := s.stats(ctx, videoIDs)
	if err != nil {
		return nil, s.internal(ctx, "select stats", err)
	}
	if len(rows) != len(reqIDs) {
		return nil, s.internal(ctx, "select stats", fmt.Errorf("got %d rows for %d ids", len(rows), len(reqIDs)))
	}
	stats := make([]*engagementv1.VideoStats, len(rows))
	for i, r := range rows {
		stats[i] = &engagementv1.VideoStats{
			VideoId:   reqIDs[i],
			ViewCount: r.ViewCount,
			LikeCount: r.LikeCount,
			LikedByMe: r.LikedByMe,
		}
	}
	return &engagementv1.GetStatsResponse{Stats: stats}, nil
}

// stats reads the GetStats rows of videoIDs for the caller in ctx. Without a caller it reads only
// the counters, never the likes table, and leaves liked_by_me false.
func (s *Server) stats(ctx context.Context, videoIDs []uuid.UUID) ([]store.GetStatsRow, error) {
	if caller, ok := callerid.FromContext(ctx); ok {
		return s.queries.GetStats(ctx, store.GetStatsParams{VideoIds: videoIDs, CallerID: uuid.MustParse(caller)})
	}
	counts, err := s.queries.GetCounts(ctx, videoIDs)
	if err != nil {
		return nil, err
	}
	rows := make([]store.GetStatsRow, len(counts))
	for i, c := range counts {
		rows[i] = store.GetStatsRow{ViewCount: c.ViewCount, LikeCount: c.LikeCount}
	}
	return rows, nil
}

// RecordView produces one view.recorded for the caller, keyed by video_id, and waits for the
// broker to acknowledge it, at most produceTimeout. The viewer is always the caller, never a
// value from the request. A failed or late produce is UNAVAILABLE without the broker's error,
// which only goes to the log.
func (s *Server) RecordView(ctx context.Context, req *engagementv1.RecordViewRequest) (*engagementv1.RecordViewResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, invalidVideoIDMessage)
	}
	id := videoID.String()
	ev := &engagementv1.ViewEvent{
		Meta: &eventv1.EventMeta{EventId: ids.New(), OccurredAt: timestamppb.Now()},
		Event: &engagementv1.ViewEvent_ViewRecorded{ViewRecorded: &engagementv1.ViewRecorded{
			VideoId:  id,
			ViewerId: caller.String(),
		}},
	}
	value, err := proto.Marshal(ev)
	if err != nil {
		return nil, s.internal(ctx, "marshal ViewEvent", err)
	}

	produceCtx, cancel := context.WithTimeout(ctx, produceTimeout)
	defer cancel()
	// kafkax.Produce gives the record a producer span under the request's span, and that span's
	// traceparent header. A produce cut short is not retried: the broker may have the record.
	err = kafkax.Produce(produceCtx, s.producer, &kgo.Record{Topic: TopicViews, Key: []byte(id), Value: value})
	if err != nil {
		s.logger.ErrorContext(logx.With(ctx, slog.String("video_id", id)), "produce view.recorded", slog.Any("error", err))
		return nil, grpcerr.New(codes.Unavailable, ReasonDependencyUnavailable, "view could not be recorded, retry later")
	}
	return &engagementv1.RecordViewResponse{}, nil
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
