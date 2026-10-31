// Package server implements svp.feed.v1.FeedService: the caller's following feed from their own
// timeline and the explore feed of every READY video, both newest first with keyset pagination
// (docs/architecture.md §8.3). The first explore page, which every new user reads, is cached in
// Redis.
package server

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"strconv"
	"sync/atomic"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/singleflight"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	feedv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/feed/v1"
	"github.com/anhnvcoder/svp-backend/internal/callerid"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/pagetoken"
	"github.com/anhnvcoder/svp-backend/services/feed-service/internal/store"
)

// Page sizes (AIP-158, feed_service.proto).
const (
	DefaultPageSize = 10
	MaxPageSize     = 50
)

// Explore cache. Every new user reads the same first explore page, a hot key that would otherwise
// cost a Postgres query per request.
const (
	// ExploreCacheTTL is how long a cached first explore page is served; nothing deletes it
	// earlier, so a new video reaches the explore feed at most this late.
	ExploreCacheTTL = 5 * time.Second
	// defaultCacheTimeout bounds one Redis command; past it the page is read from Postgres.
	defaultCacheTimeout = 50 * time.Millisecond
	// exploreLoadTimeout bounds the shared Postgres read of a first explore page.
	exploreLoadTimeout = 2 * time.Second
	// cacheWarnInterval is the least time between two warnings about a failing cache, so a
	// Redis outage does not log on every request.
	cacheWarnInterval = time.Minute
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

	cache       *redis.Client
	cachePrefix string
	// cacheTimeout bounds one Redis command.
	cacheTimeout time.Duration
	// exploreCacheTTL is ExploreCacheTTL; tests lengthen it so a slow run does not see the page
	// expire.
	exploreCacheTTL time.Duration
	// exploreRows reads explore rows; tests wrap it to count or slow down reads.
	exploreRows func(context.Context, store.GetExploreFeedParams) ([]store.GetExploreFeedRow, error)
	// firstPages makes concurrent cache misses of one first explore page share a single read.
	firstPages singleflight.Group
	// lastCacheWarn is when the last cache warning was logged, in Unix nanoseconds.
	lastCacheWarn atomic.Int64
}

// Option changes a Server built by New.
type Option func(*Server)

// WithCacheTimeout bounds every Redis command of the explore cache by d instead of 50 ms. Tests
// that count Postgres reads use a longer bound, so a slow test run
// does not take the Postgres path.
func WithCacheTimeout(d time.Duration) Option {
	return func(s *Server) { s.cacheTimeout = d }
}

// New returns a Server reading through pool, which caches the first explore page in cache under
// keys starting with cachePrefix. The cache is optional to serving: when Redis fails or is
// slow, the page is read from Postgres.
func New(pool *pgxpool.Pool, cache *redis.Client, cachePrefix string, logger *slog.Logger, opts ...Option) *Server {
	s := &Server{queries: store.New(pool), logger: logger, cache: cache, cachePrefix: cachePrefix,
		cacheTimeout: defaultCacheTimeout, exploreCacheTTL: ExploreCacheTTL}
	s.exploreRows = s.queries.GetExploreFeed
	for _, opt := range opts {
		opt(s)
	}
	return s
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

// GetExploreFeed returns a page of every READY video, the same for every caller. The first page
// goes through the cache; later pages are read from Postgres.
func (s *Server) GetExploreFeed(ctx context.Context, req *feedv1.GetExploreFeedRequest) (*feedv1.GetExploreFeedResponse, error) {
	if _, err := callerID(ctx); err != nil {
		return nil, err
	}
	p, err := parsePage(req.GetPageSize(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	if p.before == nil {
		return s.firstExplorePage(ctx, p)
	}
	resp, err := s.explorePage(ctx, p)
	if err != nil {
		return nil, s.internal(ctx, "select explore feed", err)
	}
	return resp, nil
}

// firstExplorePage serves the first explore page of p.size items from the cache. On a miss,
// concurrent requests for the same page share one Postgres read, which then fills the cache.
// That read is detached from the request that started it, so a caller giving up does not fail
// the others; each caller still waits only as long as its own context allows.
func (s *Server) firstExplorePage(ctx context.Context, p page) (*feedv1.GetExploreFeedResponse, error) {
	key := s.cachePrefix + "explore:v1:first:" + strconv.Itoa(int(p.size))
	if resp, _, got := s.cachedExplorePage(ctx, key); got == cacheHit {
		return resp, nil
	}
	loaded := s.firstPages.DoChan(key, func() (any, error) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), exploreLoadTimeout)
		defer cancel()
		// A request that missed the cache just before an earlier read filled it gets here once
		// that read has ended: look again rather than read Postgres a second time.
		_, b, got := s.cachedExplorePage(ctx, key)
		if got == cacheHit {
			return b, nil
		}
		resp, err := s.explorePage(ctx, p)
		if err != nil {
			return nil, err
		}
		b, err = proto.Marshal(resp)
		if err != nil {
			return nil, err
		}
		wrote := s.cacheExplorePage(ctx, key, b)
		// The line carries why the cache did not serve this read, so the Postgres reads a slow
		// Redis caused can be counted: the cache WARNs are logged at most once a minute and do
		// not count them. The look just above is the one that decides whether Postgres is read.
		// It also carries how caching the page ended: a write past the budget may leave no page,
		// so the next shared read finds none (cache=miss) because Redis was slow, not because the
		// page expired.
		s.logger.InfoContext(ctx, "explore page loaded from database", slog.Int("page_size", int(p.size)),
			slog.String("cache", string(got)), slog.String("cache_write", string(wrote)))
		return b, nil
	})
	var r singleflight.Result
	select {
	case <-ctx.Done():
		return nil, status.FromContextError(ctx.Err()).Err()
	case r = <-loaded:
	}
	if r.Err != nil {
		return nil, s.internal(ctx, "select explore feed", r.Err)
	}
	// Every caller gets its own copy of the shared page.
	resp := new(feedv1.GetExploreFeedResponse)
	if err := proto.Unmarshal(r.Val.([]byte), resp); err != nil {
		return nil, s.internal(ctx, "decode explore feed", err)
	}
	return resp, nil
}

// cacheResult is how a read or a write of the explore cache ended.
type cacheResult string

const (
	cacheHit cacheResult = "hit"
	// cacheStored: a write Redis acknowledged.
	cacheStored cacheResult = "ok"
	// cacheMiss: no page under the key.
	cacheMiss cacheResult = "miss"
	// cacheTimeout: Redis did not answer within cacheTimeout.
	cacheTimeout cacheResult = "timeout"
	// cacheError: any other Redis failure, or cached bytes that do not decode.
	cacheError cacheResult = "error"
)

// cachedExplorePage returns the page cached under key, decoded and as stored, and cacheHit. On a
// miss, a Redis error or timeout, and bytes that do not decode it returns why: the caller reads
// Postgres instead. A read that fails because the request of ctx was cancelled or ran out of time
// is not a cache failure and is not logged.
func (s *Server) cachedExplorePage(ctx context.Context, key string) (*feedv1.GetExploreFeedResponse, []byte, cacheResult) {
	getCtx, cancel := context.WithTimeout(ctx, s.cacheTimeout)
	defer cancel()
	b, err := s.cache.Get(getCtx, key).Bytes()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, nil, cacheMiss
		}
		if ctx.Err() == nil {
			s.warnCache(ctx, "read explore cache", err)
		}
		return nil, nil, cacheFailure(err)
	}
	resp := new(feedv1.GetExploreFeedResponse)
	if err := proto.Unmarshal(b, resp); err != nil {
		s.warnCache(ctx, "decode explore cache", err)
		return nil, nil, cacheError
	}
	return resp, b, cacheHit
}

// cacheFailure tells a Redis command that ran out of time from one that failed otherwise. With
// the context deadline of redisx, go-redis reports running out of time three ways: the socket's
// read, write or dial deadline (a net.Error whose Timeout is true), the context's own
// context.DeadlineExceeded while it waits for a pooled connection (also a net.Error with Timeout
// true), or redis.ErrPoolTimeout when the pool's wait of PoolTimeout ends first.
func cacheFailure(err error) cacheResult {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() || errors.Is(err, redis.ErrPoolTimeout) {
		return cacheTimeout
	}
	return cacheError
}

// cacheExplorePage stores page b under key for ExploreCacheTTL and returns how the write ended. A
// failure is only logged: the next request reads Postgres again.
func (s *Server) cacheExplorePage(ctx context.Context, key string, b []byte) cacheResult {
	ctx, cancel := context.WithTimeout(ctx, s.cacheTimeout)
	defer cancel()
	if err := s.cache.Set(ctx, key, b, s.exploreCacheTTL).Err(); err != nil {
		s.warnCache(ctx, "write explore cache", err)
		return cacheFailure(err)
	}
	return cacheStored
}

// warnCache logs a cache failure at most once per cacheWarnInterval.
func (s *Server) warnCache(ctx context.Context, what string, err error) {
	now := time.Now().UnixNano()
	last := s.lastCacheWarn.Load()
	if now-last < int64(cacheWarnInterval) || !s.lastCacheWarn.CompareAndSwap(last, now) {
		return
	}
	s.logger.WarnContext(ctx, what, slog.Any("error", err))
}

// explorePage reads the explore page p from Postgres.
func (s *Server) explorePage(ctx context.Context, p page) (*feedv1.GetExploreFeedResponse, error) {
	params := store.GetExploreFeedParams{RowLimit: p.size + 1}
	params.BeforePublishedAt, params.BeforeVideoID = p.cursorArgs()
	rows, err := s.exploreRows(ctx, params)
	if err != nil {
		return nil, err
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
	return &p.before.Time, p.before.VideoID
}

// pageOf turns up to size+1 rows into the items of the page and the token of the next one: an
// extra row means there is a next page, which starts after the page's last item.
func pageOf(rows []store.GetFollowingFeedRow, size int32) ([]*feedv1.FeedItem, string) {
	next := ""
	if len(rows) > int(size) {
		rows = rows[:size]
		last := rows[len(rows)-1]
		next = pagetoken.Encode(pagetoken.Cursor{Time: last.PublishedAt, VideoID: last.VideoID})
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
