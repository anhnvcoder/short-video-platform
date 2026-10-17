// Package logx builds the JSON logger every service uses and carries request-scoped attributes
// (user_id, video_id) in a context.Context, so packages add them to logs without importing
// each other.
package logx

import (
	"context"
	"io"
	"log/slog"
	"os"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
)

// New returns a logger writing JSON to stdout and logs to the global OTel provider.
// The bridge follows the first provider installed after New, so New may precede telemetry setup.
// Every record carries the service attribute and
// the attributes stored in the context by With, when logged through a ...Context method.
func New(service string) *slog.Logger {
	return newLogger(os.Stdout, service)
}

func newLogger(w io.Writer, service string) *slog.Logger {
	return slog.New(NewHandler(slog.NewMultiHandler(
		slog.NewJSONHandler(w, nil), otelslog.NewHandler(service), &sentryx.Handler{},
	))).With(slog.String("service", service))
}

type ctxKey struct{}

// With returns a copy of ctx that carries attrs in addition to the attributes ctx already
// carries.
func With(ctx context.Context, attrs ...slog.Attr) context.Context {
	prev, _ := ctx.Value(ctxKey{}).([]slog.Attr)
	merged := make([]slog.Attr, 0, len(prev)+len(attrs))
	merged = append(merged, prev...)
	merged = append(merged, attrs...)
	return context.WithValue(ctx, ctxKey{}, merged)
}

// Handler adds the attributes stored in the record's context by With to each record, then
// passes it to the wrapped handler.
//
// Attributes are added to the record, so after WithGroup they land inside the group.
type Handler struct {
	next         slog.Handler
	nextWithSpan slog.Handler
}

// NewHandler wraps next.
func NewHandler(next slog.Handler) *Handler {
	return &Handler{next: next, nextWithSpan: next}
}

// Enabled reports whether the wrapped handler handles records at level.
func (h *Handler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

// Handle adds the context attributes to r and passes it on.
func (h *Handler) Handle(ctx context.Context, r slog.Record) error {
	sc := trace.SpanContextFromContext(ctx)
	// A valid span context takes precedence over legacy trace attributes.
	clean := slog.NewRecord(r.Time, r.Level, r.Message, r.PC)
	r.Attrs(func(a slog.Attr) bool {
		if !sc.IsValid() || !isTraceAttr(a) {
			clean.AddAttrs(a)
		}
		return true
	})
	r = clean
	if attrs, ok := ctx.Value(ctxKey{}).([]slog.Attr); ok {
		r = r.Clone()
		for _, a := range attrs {
			if !sc.IsValid() || !isTraceAttr(a) {
				r.AddAttrs(a)
			}
		}
	}
	if sc.IsValid() {
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()), slog.String("span_id", sc.SpanID().String()))
		return h.nextWithSpan.Handle(ctx, r)
	}
	return h.next.Handle(ctx, r)
}

// WithAttrs returns a Handler whose wrapped handler carries attrs.
func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	// Keep both variants because span validity is only known at Handle time.
	clean := make([]slog.Attr, 0, len(attrs))
	for _, a := range attrs {
		if !isTraceAttr(a) {
			clean = append(clean, a)
		}
	}
	return &Handler{next: h.next.WithAttrs(attrs), nextWithSpan: h.nextWithSpan.WithAttrs(clean)}
}

func isTraceAttr(a slog.Attr) bool { return a.Key == "trace_id" || a.Key == "span_id" }

// WithGroup returns a Handler whose wrapped handler opens the group name.
func (h *Handler) WithGroup(name string) slog.Handler {
	return &Handler{next: h.next.WithGroup(name), nextWithSpan: h.nextWithSpan.WithGroup(name)}
}
