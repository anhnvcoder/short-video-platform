// Package server implements svp.video.v1.VideoService for stage 1: InitUpload records a new video
// and GetVideo reads one back. CompleteUpload needs object storage and the outbox, so it stays
// UNIMPLEMENTED until stage 2 (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 8).
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
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/services/video-service/internal/store"
)

const (
	// MaxTitleRunes is the longest title accepted, counted in characters after trimming (OPS-3).
	MaxTitleRunes = 200
	// MaxSizeBytes is the "500 MB" upload limit of ADR-0004, read as 500 MiB (ADR-0007, section 8).
	MaxSizeBytes = 500 << 20

	maxMediaTypeLen = len("video/") + 127
)

// ErrorInfo reasons returned by the service.
const (
	ReasonInvalidTitle       = "INVALID_TITLE"
	ReasonInvalidSize        = "INVALID_SIZE"
	ReasonInvalidContentType = "INVALID_CONTENT_TYPE"
	ReasonInvalidVideoID     = "INVALID_VIDEO_ID"
	ReasonVideoNotFound      = "VIDEO_NOT_FOUND"
)

// Video statuses as stored in the status column.
const (
	statusUploading  = "UPLOADING"
	statusProcessing = "PROCESSING"
	statusReady      = "READY"
	statusFailed     = "FAILED"
)

// Server serves VideoService. Every RPC expects the caller id that callerid.UnaryServerInterceptor
// puts into the context.
type Server struct {
	videov1.UnimplementedVideoServiceServer

	queries *store.Queries
	logger  *slog.Logger
}

// New returns a Server reading and writing through db.
func New(db store.DBTX, logger *slog.Logger) *Server {
	return &Server{queries: store.New(db), logger: logger}
}

// CallerInterceptor requires the caller's x-user-id on every VideoService RPC. Only the health
// check is public: the healthcheck subcommand and probes call it without a user.
func CallerInterceptor() grpc.UnaryServerInterceptor {
	return callerid.UnaryServerInterceptor(healthpb.Health_Check_FullMethodName)
}

// InitUpload creates a video in UPLOADING owned by the caller. Until object storage exists
// (stage 2) the response carries only video_id.
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
	// user_id and trace_id are already in the context; video_id joins them on every later log (UP-8).
	ctx = logx.With(ctx, slog.String("video_id", id))
	err = s.queries.CreateVideo(ctx, store.CreateVideoParams{
		ID:          uuid.MustParse(id),
		AuthorID:    caller,
		Title:       title,
		SizeBytes:   req.GetSizeBytes(),
		ContentType: contentType,
	})
	if err != nil {
		return nil, s.internal(ctx, "insert video", err)
	}
	s.logger.InfoContext(ctx, "video created")
	return &videov1.InitUploadResponse{VideoId: id}, nil
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
