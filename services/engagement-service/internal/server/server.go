// Package server implements svp.engagement.v1.EngagementService: Like and Unlike keep the likes
// and their counter, GetStats reads the counters of up to 50 videos, and RecordView produces
// view.recorded without touching the database.
//
// The service reads and writes Postgres through two pools of its own size: a read pool for
// GetStats only, and a write pool for Like, Unlike and the views consumer. The gateway gives
// GetStats 100 ms and cancels it when Postgres is slow; pgx then closes the connection and the
// pool dials a new one, a dial that goes on after the cancel. In a pool of its own that churn
// holds at most the read pool's connections, so likes never wait behind it for a connection.
package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	engagementv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/engagement/v1"
	eventv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/event/v1"
	"github.com/anhnvcoder/svp-backend/internal/callerid"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/services/engagement-service/internal/store"
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

	// writeTimeout bounds the Postgres part of Like and Unlike, the wait for a connection of the
	// write pool included. Each is one statement run in pgx's default mode, which prepares a
	// statement once per connection and keeps it: on a connection that has run it before it is
	// one round trip, on a connection running it for the first time two (prepare, then execute),
	// and a new connection adds the TCP connect and the Postgres startup with its authentication,
	// several round trips more. The pool also pings a connection idle for more than a second
	// before handing it out, one round trip more. With 200 ms a round trip, a pooled connection
	// answers in 200 to 600 ms, well within this bound, while a new one does not: the caller then
	// gets UNAVAILABLE after a second instead of waiting out the gateway's 3 s call deadline.
	writeTimeout = 1 * time.Second

	// retryPushbackKey is the trailer by which a server tells a gRPC client's retry policy
	// whether and when to retry; a negative value means do not retry this call.
	retryPushbackKey = "grpc-retry-pushback-ms"
)

// ErrorInfo reasons returned by the service.
const (
	ReasonInvalidVideoID  = "INVALID_VIDEO_ID"
	ReasonTooManyVideoIDs = "TOO_MANY_VIDEO_IDS"
	// ReasonDependencyUnavailable goes with UNAVAILABLE when a dependency of the service (the
	// broker, or Postgres for a like) is down or too slow while the service itself runs: the
	// gateway's breaker does not count it.
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

	writePool *pgxpool.Pool
	// reads runs GetStats on the read pool, writes everything else on the write pool.
	reads, writes *store.Queries
	producer      *kgo.Client
	logger        *slog.Logger
}

// New returns a Server that reads the counters of GetStats through readPool, writes likes and
// view counts through writePool, and produces view events with producer.
func New(readPool, writePool *pgxpool.Pool, producer *kgo.Client, logger *slog.Logger) *Server {
	return &Server{
		writePool: writePool,
		reads:     store.New(readPool),
		writes:    store.New(writePool),
		producer:  producer,
		logger:    logger,
	}
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

// Like records that the caller likes the video. In one statement it inserts the likes row and,
// only when the row is new, adds one to like_count, so liking twice counts once. A database that
// is down or slower than writeTimeout is UNAVAILABLE (see writeError).
func (s *Server) Like(ctx context.Context, req *engagementv1.LikeRequest) (*engagementv1.LikeResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, invalidVideoIDMessage)
	}
	wctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	if err := s.writes.Like(wctx, store.LikeParams{VideoID: videoID, UserID: caller}); err != nil {
		s.logger.ErrorContext(ctx, "like video", slog.Any("error", err))
		return nil, writeError(ctx, wctx, "like could not be saved, retry later", err)
	}
	return &engagementv1.LikeResponse{}, nil
}

// Unlike removes the caller's like. In one statement it deletes the likes row and, only when a
// row was deleted, takes one from like_count, so unliking a video not liked changes nothing. Its
// errors are Like's.
func (s *Server) Unlike(ctx context.Context, req *engagementv1.UnlikeRequest) (*engagementv1.UnlikeResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, invalidVideoIDMessage)
	}
	wctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	if err := s.writes.Unlike(wctx, store.UnlikeParams{VideoID: videoID, UserID: caller}); err != nil {
		s.logger.ErrorContext(ctx, "unlike video", slog.Any("error", err))
		return nil, writeError(ctx, wctx, "unlike could not be saved, retry later", err)
	}
	return &engagementv1.UnlikeResponse{}, nil
}

// writeError returns the caller's error for err, the failure of a Like or Unlike statement run
// on wctx (ctx bounded by writeTimeout), which the caller has logged:
//   - ctx ended first (the caller's deadline or cancel): DEADLINE_EXCEEDED or CANCELLED, what the
//     caller sees anyway;
//   - writeTimeout ran out, or Postgres could not be reached or the connection broke
//     (unreachable): UNAVAILABLE with ErrorInfo ReasonDependencyUnavailable and msg, and a
//     negative retry pushback so the caller's retry policy does not try again at once against a
//     database that is down or slow; the statement may have run, and running it again is safe;
//   - anything else: the generic INTERNAL error of internal.
//
// No error carries database details.
func writeError(ctx, wctx context.Context, msg string, err error) error {
	switch {
	case ctx.Err() != nil:
		return status.FromContextError(ctx.Err()).Err()
	case wctx.Err() != nil || unreachable(err):
		// Fails only outside a gRPC call (a handler called directly in a test): no trailer then.
		_ = grpc.SetTrailer(ctx, metadata.Pairs(retryPushbackKey, "-1"))
		return grpcerr.New(codes.Unavailable, ReasonDependencyUnavailable, msg)
	default:
		return status.Error(codes.Internal, "internal error")
	}
}

// unreachable reports whether err means Postgres could not be reached or the connection to it
// broke, as opposed to Postgres answering with an error: a failed connect without an answer from
// the server (refused, timed out, cut during the handshake); a connection that ended or timed out
// while in use; or a Postgres error of class 08 (connection exception) or one saying the server
// is shutting down or starting up (57P01, 57P02, 57P03). Unlike the startup retries, a failure
// after connecting counts: a broken connection mid-request is the database going away.
func unreachable(err error) bool {
	if pgErr, ok := errors.AsType[*pgconn.PgError](err); ok {
		switch pgErr.Code {
		case "57P01", "57P02", "57P03":
			return true
		}
		return strings.HasPrefix(pgErr.Code, "08")
	}
	if _, ok := errors.AsType[*pgconn.ConnectError](err); ok {
		return true
	}
	if opErr, ok := errors.AsType[*net.OpError](err); ok && (opErr.Op == "read" || opErr.Op == "write") {
		return true
	}
	return errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, pgconn.ErrConnClosed) || errors.Is(err, net.ErrClosed) || pgconn.Timeout(err)
}

// inTx runs fn on queries bound to one transaction of the write pool and commits when fn returns
// nil, within the deadline of ctx.
func (s *Server) inTx(ctx context.Context, fn func(q *store.Queries) error) error {
	tx, err := s.writePool.Begin(ctx)
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
	if err := fn(s.writes.WithTx(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// GetStats returns the counters of each requested video in request order, a repeated id once per
// occurrence, and zeros for an id never liked or viewed. Without a caller liked_by_me is false for
// every video and no like is read. It reads through the read pool within the caller's deadline:
// when the read pool is full, it waits for a connection until then.
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
		return s.reads.GetStats(ctx, store.GetStatsParams{VideoIds: videoIDs, CallerID: uuid.MustParse(caller)})
	}
	counts, err := s.reads.GetCounts(ctx, videoIDs)
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
