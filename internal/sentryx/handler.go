package sentryx

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/getsentry/sentry-go"
	"github.com/jackc/pgx/v5/pgconn"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// These literals come from application ERROR call sites and their internal helpers.
// TestAllowedMessagesMatchErrorLogs checks the list against the repository source.
var allowedMessages = []string{
	"decode explore feed", "engagement-service failed", "feed consumer stopped, restarting",
	"feed-service failed", "gateway failed", "grpc call failed", "head uploaded file", "insert video",
	"internal error", "like video", "mark video processing", "marshal ViewEvent", "media-worker failed",
	"panic in grpc handler", "panic in http handler", "presign upload form", "produce view.recorded",
	"prune timeline", "rpc", "select author videos", "select explore feed", "select following feed", "select stats", "select video",
	"transcode consumer stopped, restarting", "unlike video", "user-service failed", "video-service failed",
	"views consumer stopped, restarting",
}

var (
	uuidPattern   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	namePattern   = regexp.MustCompile(`^[a-z0-9._-]{1,64}$`)
	sqlPattern    = regexp.MustCompile(`^[0-9A-Z]{5}$`)
	methodPattern = regexp.MustCompile(`^/[A-Za-z_][A-Za-z0-9_.]*\.[A-Za-z_][A-Za-z0-9_]*/[A-Za-z_][A-Za-z0-9_]*$`)
	routePattern  = regexp.MustCompile(`^(GET|HEAD|POST|PUT|PATCH|DELETE|CONNECT|OPTIONS|TRACE) /[A-Za-z0-9_/{}.-]*$`)
	stackFunction = regexp.MustCompile(`^[A-Za-z0-9_./*()\[\]-]+$`)
	// File paths in the module cache read path@version, with ! before an escaped capital and
	// +incompatible in some versions.
	stackFile = regexp.MustCompile(`^\t([A-Za-z0-9_./@!+-]+\.go):([0-9]+)(?: \+0x[0-9a-f]+)?$`)
)

// Handler forwards ERROR records to the process reporter. Its zero value is ready to use.
// Groups are deliberately excluded, including attributes bound inside WithGroup.
type Handler struct {
	attrs   []slog.Attr
	grouped bool
}

func (*Handler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= slog.LevelError && active.Load() != nil
}

func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	copy := *h
	if !h.grouped {
		copy.attrs = append(slices.Clone(h.attrs), attrs...)
	}
	return &copy
}

func (h *Handler) WithGroup(name string) slog.Handler {
	copy := *h
	copy.grouped = h.grouped || name != ""
	return &copy
}

func (h *Handler) Handle(ctx context.Context, record slog.Record) error {
	r := active.Load()
	if r == nil || record.Level < slog.LevelError {
		return nil
	}
	event := &sentry.Event{Level: sentry.LevelError, Message: "unlisted error",
		Tags: map[string]string{"service": r.service}, Contexts: make(map[string]sentry.Context)}
	if slices.Contains(allowedMessages, record.Message) {
		event.Message = record.Message
	}
	var exception sentry.Exception
	add := func(a slog.Attr) bool {
		// Do not resolve LogValuer or stringify arbitrary values: only native
		// strings/integers and explicitly handled error/panic metadata may pass.
		switch a.Key {
		case "error":
			if err, ok := a.Value.Any().(error); ok {
				exception.Type, exception.Value = DescribeError(err)
			}
		case "panic":
			exception.Type = fmt.Sprintf("%T", a.Value.Any())
		case "stack":
			if a.Value.Kind() == slog.KindString {
				exception.Stacktrace = parseStack(a.Value.String())
			}
		default:
			if value, ok := safeAttr(a); ok {
				event.Tags[a.Key] = value
			}
		}
		return true
	}
	for _, a := range h.attrs {
		add(a)
	}
	if !h.grouped {
		record.Attrs(add)
	}
	if exception.Type != "" || exception.Stacktrace != nil {
		event.Exception = []sentry.Exception{exception}
	}
	sc := trace.SpanContextFromContext(ctx)
	if sc.IsValid() {
		event.Tags["trace_id"], event.Tags["span_id"] = sc.TraceID().String(), sc.SpanID().String()
		event.Contexts["trace"] = sentry.Context{"trace_id": sc.TraceID().String(), "span_id": sc.SpanID().String()}
	}
	key := fingerprint{r.service, event.Message, event.Tags["route"], exception.Type}
	now := time.Now()
	allowed, dropped, flushAt := r.limits.allow(now, key)
	if dropped != 0 {
		slog.WarnContext(ctx, "error tracker events dropped", slog.Uint64("dropped", dropped))
	}
	if !flushAt.IsZero() {
		r.after(flushAt.Sub(now), func() {
			if dropped := r.limits.flush(time.Now()); dropped != 0 {
				slog.Warn("error tracker events dropped", slog.Uint64("dropped", dropped))
			}
		})
	}
	if allowed {
		event.Fingerprint = []string{key.service, key.message, key.route, key.kind}
		r.client.CaptureEvent(event, nil, nil)
	}
	return nil
}

// DescribeError returns what may leave the process about err: kind, the type of the innermost
// error along its errors.Unwrap chain (%T, such as *pgconn.PgError), and code, the SQLSTATE of a
// Postgres error or the code of a gRPC status, empty otherwise. The error's text is never read:
// it can quote a parameter, an email or a token.
func DescribeError(err error) (kind, code string) {
	for next := errors.Unwrap(err); next != nil; next = errors.Unwrap(err) {
		err = next
	}
	kind = fmt.Sprintf("%T", err)
	if pg, ok := errors.AsType[*pgconn.PgError](err); ok && sqlPattern.MatchString(pg.Code) {
		code = pg.Code
	} else if grpc, ok := err.(interface{ GRPCStatus() *status.Status }); ok {
		if st := grpc.GRPCStatus(); st != nil && st.Code() <= codes.Unauthenticated {
			code = st.Code().String()
		}
	}
	return kind, code
}

func safeAttr(a slog.Attr) (string, bool) {
	switch a.Key {
	case "status", "partition", "offset":
		switch a.Value.Kind() {
		case slog.KindInt64:
			return strconv.FormatInt(a.Value.Int64(), 10), true
		case slog.KindUint64:
			return strconv.FormatUint(a.Value.Uint64(), 10), true
		}
		return "", false
	}
	if a.Value.Kind() != slog.KindString {
		return "", false
	}
	v := a.Value.String()
	switch a.Key {
	case "video_id", "user_id", "event_id":
		return v, uuidPattern.MatchString(v)
	case "topic", "target", "loop":
		return v, namePattern.MatchString(v)
	case "method":
		return v, httpMethod(v) || methodPattern.MatchString(v)
	case "route":
		return v, routePattern.MatchString(v)
	case "code":
		if sqlPattern.MatchString(v) {
			return v, true
		}
		for code := codes.OK; code <= codes.Unauthenticated; code++ {
			if v == code.String() {
				return v, true
			}
		}
	}
	return "", false
}

func httpMethod(v string) bool {
	switch v {
	case "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "CONNECT", "OPTIONS", "TRACE":
		return true
	}
	return false
}

// debug.Stack includes argument values on function lines. Strip the final
// parenthesized arguments, then accept only function/file/line syntax.
func parseStack(raw string) *sentry.Stacktrace {
	lines := strings.Split(raw, "\n")
	var frames []sentry.Frame
	for i := 1; i < len(lines); i++ {
		match := stackFile.FindStringSubmatch(lines[i])
		if match == nil {
			continue
		}
		function := lines[i-1]
		at := strings.LastIndex(function, "(")
		if at < 0 {
			continue
		}
		function = function[:at]
		if !stackFunction.MatchString(function) {
			continue
		}
		line, err := strconv.Atoi(match[2])
		if err == nil {
			frames = append(frames, sentry.Frame{Function: function, Filename: match[1], Lineno: line})
		}
	}
	if len(frames) == 0 {
		return nil
	}
	slices.Reverse(frames)
	return &sentry.Stacktrace{Frames: frames}
}
