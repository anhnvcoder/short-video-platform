// Package server implements svp.video.v1.VideoService: InitUpload records a new video and signs
// its upload form, CompleteUpload checks the uploaded object and emits video.uploaded through the
// outbox, GetVideo reads a video back. GetPublicVideo serves a READY video to anyone and
// ListAuthorVideos lists the videos of an author. HandleTranscode consumes
// the transcode results that move the video to READY or FAILED.
package server

import (
	"context"
	"errors"
	"log/slog"
	"mime"
	"strings"
	"time"
	"unicode/utf8"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/metric/noop"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/callerid"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/internal/outbox"
	"github.com/anhnvcoder/svp-backend/internal/pagetoken"
	"github.com/anhnvcoder/svp-backend/services/video-service/internal/store"
)

const (
	// MaxTitleRunes is the longest title accepted, counted in characters after trimming (OPS-3).
	MaxTitleRunes = 200
	// MaxSizeBytes is the "500 MB" upload limit, read as 500 MiB (524,288,000 bytes).
	MaxSizeBytes = 500 << 20

	maxMediaTypeLen = len("video/") + 127

	// uploadFormTTL is how long a presigned upload form is accepted: long enough for a slow mobile
	// upload, short because anyone holding a leaked form can write to its key until then
	// (UP-2).
	uploadFormTTL = 15 * time.Minute
	// MaxOpenUploads is how many videos one author may have UPLOADING with a form still valid, so
	// one account holds at most 1.5 GB of open upload forms
	// (UP-7).
	MaxOpenUploads = 3
	// TopicVideoLifecycle carries svp.video.v1.VideoEvent, keyed by video_id.
	TopicVideoLifecycle = "video.lifecycle.v1"
	// rollbackTimeout bounds the rollback of a transcode or sweep transaction, which runs after
	// the step's own deadline may have passed.
	rollbackTimeout = 5 * time.Second
)

// Page sizes of ListAuthorVideos (AIP-158, video_service.proto), as in the feeds.
const (
	DefaultPageSize = 10
	MaxPageSize     = 50
)

// readyBuckets are the bucket bounds of svp.video.ready.duration, in seconds, the same as
// media-worker's svp.transcode.duration.
// 120 is a boundary because the video-ready SLO counts a sample at or under 120 s as good.
var readyBuckets = []float64{10, 20, 30, 45, 60, 90, 120, 180, 300, 600}

// ErrorInfo reasons returned by the service.
const (
	ReasonInvalidTitle       = "INVALID_TITLE"
	ReasonInvalidSize        = "INVALID_SIZE"
	ReasonInvalidContentType = "INVALID_CONTENT_TYPE"
	ReasonInvalidVideoID     = "INVALID_VIDEO_ID"
	ReasonVideoNotFound      = "VIDEO_NOT_FOUND"
	ReasonVideoFailed        = "VIDEO_FAILED"
	ReasonUploadNotFound     = "UPLOAD_NOT_FOUND"
	ReasonUploadMismatch     = "UPLOAD_MISMATCH"
	ReasonTooManyUploads     = "TOO_MANY_UPLOADS"
	ReasonInvalidAuthorID    = "INVALID_AUTHOR_ID"
	ReasonInvalidPageSize    = "INVALID_PAGE_SIZE"
	ReasonInvalidPageToken   = "INVALID_PAGE_TOKEN"
	// ReasonDependencyUnavailable goes with UNAVAILABLE when a dependency of the service (object
	// storage) is down while the service itself runs: the gateway's breaker does not count it.
	ReasonDependencyUnavailable = "DEPENDENCY_UNAVAILABLE"
)

// Video statuses as stored in the status column.
const (
	statusUploading  = "UPLOADING"
	statusProcessing = "PROCESSING"
	statusReady      = "READY"
	statusFailed     = "FAILED"
)

// Storage is the part of the object storage the server uses; *objstore.Store implements it.
type Storage interface {
	PresignPost(ctx context.Context, key string, sizeBytes int64, contentType string, ttl time.Duration) (*objstore.PresignedPost, error)
	Head(ctx context.Context, key string) (objstore.ObjectInfo, error)
	Delete(ctx context.Context, key string) error
	DeletePrefix(ctx context.Context, prefix string) error
}

// Server serves VideoService. Every RPC but GetPublicVideo expects the caller id that
// callerid.UnaryServerInterceptor puts into the context.
type Server struct {
	videov1.UnimplementedVideoServiceServer

	pool    *pgxpool.Pool
	queries *store.Queries
	storage Storage
	logger  *slog.Logger

	// readyDuration is svp.video.ready.duration: from CompleteUpload to READY or FAILED.
	readyDuration metric.Float64Histogram
	// rollbackTimeout is the constant of the same name; tests shorten it.
	rollbackTimeout time.Duration
}

// New returns a Server reading and writing through pool and storage. Its metrics go to the
// global meter provider.
func New(pool *pgxpool.Pool, storage Storage, logger *slog.Logger) *Server {
	readyDuration, err := otel.Meter("github.com/anhnvcoder/svp-backend/services/video-service/internal/server").
		Float64Histogram("svp.video.ready.duration", metric.WithUnit("s"),
			metric.WithDescription("Time from CompleteUpload to the video becoming READY or FAILED"),
			metric.WithExplicitBucketBoundaries(readyBuckets...))
	if err != nil {
		// A metric never stops the service: report the error and record nothing.
		otel.Handle(err)
		readyDuration = noop.Float64Histogram{}
	}
	return &Server{
		pool: pool, queries: store.New(pool), storage: storage, logger: logger,
		readyDuration: readyDuration, rollbackTimeout: rollbackTimeout,
	}
}

// CallerInterceptor requires the caller's x-user-id on every VideoService RPC but the public ones:
// the health check, which the healthcheck subcommand and probes call without a user, and
// GetPublicVideo, which answers the same for everyone and so ignores x-user-id.
func CallerInterceptor() grpc.UnaryServerInterceptor {
	return callerid.UnaryServerInterceptor(
		healthpb.Health_Check_FullMethodName,
		videov1.VideoService_GetPublicVideo_FullMethodName,
	)
}

// InitUpload creates a video in UPLOADING owned by the caller and returns a form that uploads
// exactly uploads/<video_id>, of 1 to size_bytes bytes with the normalized content type, for 15
// minutes (UP-1). The form is a credential: it is never logged (UP-2). A caller who already has
// MaxOpenUploads videos UPLOADING created within the form's lifetime gets RESOURCE_EXHAUSTED
// (UP-7).
func (s *Server) InitUpload(ctx context.Context, req *videov1.InitUploadRequest) (*videov1.InitUploadResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	title, err := checkTitle(req.GetTitle())
	if err != nil {
		return nil, err
	}
	if size := req.GetSizeBytes(); size <= 0 || size > MaxSizeBytes {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidSize, "size_bytes must be between 1 and 524288000")
	}
	contentType, err := checkContentType(req.GetContentType())
	if err != nil {
		return nil, err
	}

	id := ids.New()
	err = s.createVideo(ctx, store.CreateVideoParams{
		ID:          uuid.MustParse(id),
		AuthorID:    caller,
		Title:       title,
		SizeBytes:   req.GetSizeBytes(),
		ContentType: contentType,
	})
	if errors.Is(err, errTooManyUploads) {
		s.logger.InfoContext(ctx, "too many uploads in progress")
		return nil, grpcerr.New(codes.ResourceExhausted, ReasonTooManyUploads, "too many uploads in progress")
	}
	if err != nil {
		return nil, s.internal(ctx, "insert video", err)
	}
	// user_id and trace_id are already in the context; video_id joins them on every later log
	// (UP-8), only now that the video is stored, so no log names a video that does not exist.
	ctx = logx.With(ctx, slog.String("video_id", id))
	s.logger.InfoContext(ctx, "video created")

	// The key comes from the id the server generated, never from the request (UP-4).
	form, err := s.storage.PresignPost(ctx, objstore.UploadsPrefix+id, req.GetSizeBytes(), contentType, uploadFormTTL)
	if err != nil {
		return nil, s.internal(ctx, "presign upload form", err)
	}
	return &videov1.InitUploadResponse{
		VideoId:    id,
		UploadUrl:  form.URL,
		FormFields: form.Fields,
		ExpiresAt:  timestamppb.New(form.ExpiresAt),
	}, nil
}

// errTooManyUploads is returned by createVideo when the author has MaxOpenUploads open uploads.
var errTooManyUploads = errors.New("too many uploads in progress")

// createVideo inserts the video unless its author already has MaxOpenUploads videos UPLOADING
// created within uploadFormTTL. The count and the insert run in one transaction under a lock per
// author, so concurrent calls of one author are counted one after the other.
func (s *Server) createVideo(ctx context.Context, p store.CreateVideoParams) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := s.queries.WithTx(tx)

	if err := q.LockAuthorUploads(ctx, p.AuthorID); err != nil {
		return err
	}
	// The cutoff uses this clock, like the form's expiry: a video created before it has an
	// expired form.
	open, err := q.CountOpenUploads(ctx, store.CountOpenUploadsParams{
		AuthorID:     p.AuthorID,
		CreatedAfter: time.Now().Add(-uploadFormTTL),
	})
	if err != nil {
		return err
	}
	if open >= MaxOpenUploads {
		return errTooManyUploads
	}
	if err := q.CreateVideo(ctx, p); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// CompleteUpload checks that uploads/<video_id> holds the declared size and content type, then
// moves the video from UPLOADING to PROCESSING and writes video.uploaded to the outbox in one
// transaction. A video already PROCESSING or READY is returned as is, so a retried call emits
// nothing. A video of another user gets the same error as a missing one (UP-3).
func (s *Server) CompleteUpload(ctx context.Context, req *videov1.CompleteUploadRequest) (*videov1.CompleteUploadResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, "video_id must be a canonical lowercase UUID")
	}

	v, err := s.queries.GetVideo(ctx, videoID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, videoNotFound()
	}
	if err != nil {
		return nil, s.internal(ctx, "select video", err)
	}
	if v.AuthorID != caller {
		return nil, videoNotFound()
	}
	ctx = logx.With(ctx, slog.String("video_id", v.ID.String()))
	switch v.Status {
	case statusProcessing, statusReady:
		return &videov1.CompleteUploadResponse{Video: toProto(v)}, nil
	case statusFailed:
		return nil, grpcerr.New(codes.FailedPrecondition, ReasonVideoFailed, "video has failed")
	}

	key := objstore.UploadsPrefix + v.ID.String()
	obj, err := s.storage.Head(ctx, key)
	if errors.Is(err, objstore.ErrNotFound) {
		return nil, grpcerr.New(codes.FailedPrecondition, ReasonUploadNotFound, "uploaded file not found")
	}
	if err != nil {
		s.logger.ErrorContext(ctx, "head uploaded file", slog.Any("error", err))
		return nil, grpcerr.New(codes.Unavailable, ReasonDependencyUnavailable, "storage unavailable")
	}
	// The form limits the size to 1..size_bytes; the video needs exactly what InitUpload declared.
	// The video stays UPLOADING, so the client can upload again while its form is valid.
	if obj.Size != v.SizeBytes || obj.ContentType != v.ContentType {
		s.logger.InfoContext(ctx, "uploaded file does not match",
			slog.Int64("size_bytes", obj.Size), slog.Int64("declared_size_bytes", v.SizeBytes),
			slog.String("content_type", obj.ContentType), slog.String("declared_content_type", v.ContentType))
		return nil, grpcerr.New(codes.FailedPrecondition, ReasonUploadMismatch,
			"uploaded file does not match the declared size or content type")
	}

	v, emitted, err := s.markProcessing(ctx, v, key)
	if err != nil {
		return nil, s.internal(ctx, "mark video processing", err)
	}
	// Another transaction moved the video between the read above and the UPDATE; a video that
	// failed meanwhile is answered as one that had failed before the call.
	if v.Status == statusFailed {
		return nil, grpcerr.New(codes.FailedPrecondition, ReasonVideoFailed, "video has failed")
	}
	if emitted {
		s.logger.InfoContext(ctx, "upload completed")
	}
	return &videov1.CompleteUploadResponse{Video: toProto(v)}, nil
}

// markProcessing moves v to PROCESSING and writes its video.uploaded event in one transaction.
// The UPDATE locks the row before the outbox insert, as internal/outbox requires for per-key
// order. When a concurrent call moved the video first, the UPDATE waits for it, matches no row,
// and markProcessing returns the video as that call left it, with emitted false.
func (s *Server) markProcessing(ctx context.Context, v store.Video, key string) (_ store.Video, emitted bool, err error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return store.Video{}, false, err
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := s.queries.WithTx(tx)

	updated, err := q.MarkVideoProcessing(ctx, v.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		current, err := q.GetVideo(ctx, v.ID)
		return current, false, err
	}
	if err != nil {
		return store.Video{}, false, err
	}
	id := v.ID.String()
	ev := &videov1.VideoEvent{
		Meta: outbox.NewMeta(),
		Event: &videov1.VideoEvent_VideoUploaded{VideoUploaded: &videov1.VideoUploaded{
			VideoId:     id,
			AuthorId:    v.AuthorID.String(),
			SourceKey:   key,
			ContentType: v.ContentType,
			SizeBytes:   v.SizeBytes,
		}},
	}
	if err := outbox.Write(ctx, tx, TopicVideoLifecycle, id, ev); err != nil {
		return store.Video{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return store.Video{}, false, err
	}
	return updated, true, nil
}

// GetVideo returns a video that is READY, or any video of the caller's own. Every other case
// returns the same NOT_FOUND error, so a hidden video looks exactly like a missing one (UP-3).
func (s *Server) GetVideo(ctx context.Context, req *videov1.GetVideoRequest) (*videov1.GetVideoResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidVideoID, "video_id must be a canonical lowercase UUID")
	}

	v, err := s.queries.GetVideo(ctx, videoID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, videoNotFound()
	}
	if err != nil {
		return nil, s.internal(ctx, "select video", err)
	}
	if v.Status != statusReady && v.AuthorID != caller {
		return nil, videoNotFound()
	}
	return &videov1.GetVideoResponse{Video: toProto(v)}, nil
}

// GetPublicVideo returns a READY video to anyone, for the public share page; it has no caller.
// A malformed id, a missing video and a video not READY all get the same NOT_FOUND as GetVideo, so
// an anonymous caller cannot tell an unpublished video from a missing one (UP-3). A malformed id
// is still rejected before the database is read.
func (s *Server) GetPublicVideo(ctx context.Context, req *videov1.GetPublicVideoRequest) (*videov1.GetPublicVideoResponse, error) {
	videoID, err := ids.Parse(req.GetVideoId())
	if err != nil {
		return nil, videoNotFound()
	}
	v, err := s.queries.GetVideo(ctx, videoID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, videoNotFound()
	}
	if err != nil {
		return nil, s.internal(ctx, "select video", err)
	}
	if v.Status != statusReady {
		return nil, videoNotFound()
	}
	return &videov1.GetPublicVideoResponse{Video: toProto(v)}, nil
}

// ListAuthorVideos returns a page of the videos of author_id, newest first by (created_at,
// video_id). The author sees videos in every status; anyone else only READY ones, the rule of
// GetVideo (UP-3). Which videos are listed comes from author_id and the caller only: the page
// token holds a position, so an edited or borrowed token never shows a hidden video.
func (s *Server) ListAuthorVideos(ctx context.Context, req *videov1.ListAuthorVideosRequest) (*videov1.ListAuthorVideosResponse, error) {
	caller, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	authorID, err := ids.Parse(req.GetAuthorId())
	if err != nil {
		return nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidAuthorID, "author_id must be a canonical lowercase UUID")
	}
	size, before, err := parsePage(req.GetPageSize(), req.GetPageToken())
	if err != nil {
		return nil, err
	}

	params := store.ListAuthorVideosParams{
		AuthorID:    authorID,
		AllStatuses: authorID == caller,
		// One row more than the page tells whether a next page exists.
		RowLimit: size + 1,
	}
	if before != nil {
		params.BeforeCreatedAt, params.BeforeID = &before.Time, before.VideoID
	}
	rows, err := s.queries.ListAuthorVideos(ctx, params)
	if err != nil {
		return nil, s.internal(ctx, "select author videos", err)
	}
	next := ""
	if len(rows) > int(size) {
		rows = rows[:size]
		last := rows[len(rows)-1]
		next = pagetoken.Encode(pagetoken.Cursor{Time: last.CreatedAt, VideoID: last.ID})
	}
	videos := make([]*videov1.Video, len(rows))
	for i, v := range rows {
		videos[i] = toProto(v)
	}
	return &videov1.ListAuthorVideosResponse{Videos: videos, NextPageToken: next}, nil
}

// parsePage checks page_size (0 means DefaultPageSize, above MaxPageSize means MaxPageSize,
// negative is rejected) and decodes page_token: "" is the first page, with a nil cursor.
func parsePage(size int32, token string) (int32, *pagetoken.Cursor, error) {
	switch {
	case size < 0:
		return 0, nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidPageSize, "page_size must not be negative")
	case size == 0:
		size = DefaultPageSize
	case size > MaxPageSize:
		size = MaxPageSize
	}
	if token == "" {
		return size, nil, nil
	}
	c, err := pagetoken.Decode(token)
	if err != nil {
		return 0, nil, grpcerr.New(codes.InvalidArgument, ReasonInvalidPageToken, "page_token is not a token this service returned")
	}
	return size, &c, nil
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

// checkTitle trims title and requires 1 to MaxTitleRunes characters of valid UTF-8 without NUL
// (Postgres text cannot hold NUL). The title is stored as given, without escaping: whoever
// displays it must treat it as text (OPS-3).
func checkTitle(title string) (string, error) {
	title = strings.TrimSpace(title)
	if !utf8.ValidString(title) || strings.ContainsRune(title, 0) {
		return "", grpcerr.New(codes.InvalidArgument, ReasonInvalidTitle, "title must be valid UTF-8 text")
	}
	if n := utf8.RuneCountInString(title); n == 0 || n > MaxTitleRunes {
		return "", grpcerr.New(codes.InvalidArgument, ReasonInvalidTitle, "title must be 1 to 200 characters")
	}
	return title, nil
}

// checkContentType requires a video/<subtype> media type and returns it in lower case without
// parameters: "Video/MP4; codecs=avc1" becomes "video/mp4".
func checkContentType(contentType string) (string, error) {
	invalid := grpcerr.New(codes.InvalidArgument, ReasonInvalidContentType, "content_type must be a video media type such as video/mp4")
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return "", invalid
	}
	// ParseMediaType lower-cases the media type and requires a non-empty subtype after "/".
	// RFC 6838 caps type and subtype names at 127 characters each. ParseMediaType accepts "*" as
	// a token, but a media range such as video/* names no concrete type to store.
	if !strings.HasPrefix(mediaType, "video/") || strings.Contains(mediaType, "*") || len(mediaType) > maxMediaTypeLen {
		return "", invalid
	}
	return mediaType, nil
}

func videoNotFound() error {
	return grpcerr.New(codes.NotFound, ReasonVideoNotFound, "video not found")
}

// internal logs err with what failed and returns a generic INTERNAL error, so database details
// never reach the caller.
func (s *Server) internal(ctx context.Context, what string, err error) error {
	s.logger.ErrorContext(ctx, what, slog.Any("error", err))
	return status.Error(codes.Internal, "internal error")
}

func toProto(v store.Video) *videov1.Video {
	out := &videov1.Video{
		VideoId:   v.ID.String(),
		AuthorId:  v.AuthorID.String(),
		Title:     v.Title,
		Status:    toProtoStatus(v.Status),
		CreatedAt: timestamppb.New(v.CreatedAt),
	}
	if v.DurationMs != nil {
		out.Duration = durationpb.New(time.Duration(*v.DurationMs) * time.Millisecond)
	}
	if v.PlaylistKey != nil {
		out.PlaylistKey = *v.PlaylistKey
	}
	if v.ThumbnailKey != nil {
		out.ThumbnailKey = *v.ThumbnailKey
	}
	if v.PublishedAt != nil {
		out.PublishedAt = timestamppb.New(*v.PublishedAt)
	}
	return out
}

func toProtoStatus(s string) videov1.VideoStatus {
	switch s {
	case statusUploading:
		return videov1.VideoStatus_VIDEO_STATUS_UPLOADING
	case statusProcessing:
		return videov1.VideoStatus_VIDEO_STATUS_PROCESSING
	case statusReady:
		return videov1.VideoStatus_VIDEO_STATUS_READY
	case statusFailed:
		return videov1.VideoStatus_VIDEO_STATUS_FAILED
	}
	return videov1.VideoStatus_VIDEO_STATUS_UNSPECIFIED
}
