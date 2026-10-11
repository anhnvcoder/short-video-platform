// Package logx builds the JSON logger every service uses and carries request-scoped attributes
// (trace_id, user_id) in a context.Context, so packages add them to logs without importing
// each other.
package logx

import (
	"context"
	"io"
	"log/slog"
	"os"
)

// New returns a JSON logger writing to stdout. Every record carries the service attribute and
// the attributes stored in the context by With, when logged through a ...Context method.
func New(service string) *slog.Logger {
	return newLogger(os.Stdout, service)
}

func newLogger(w io.Writer, service string) *slog.Logger {
	return slog.New(NewHandler(slog.NewJSONHandler(w, nil))).With(slog.String("service", service))
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
	next slog.Handler
}

// NewHandler wraps next.
func NewHandler(next slog.Handler) *Handler {
	return &Handler{next: next}
}

// Enabled reports whether the wrapped handler handles records at level.
func (h *Handler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

// Handle adds the context attributes to r and passes it on.
func (h *Handler) Handle(ctx context.Context, r slog.Record) error {
	if attrs, ok := ctx.Value(ctxKey{}).([]slog.Attr); ok {
		r = r.Clone()
		r.AddAttrs(attrs...)
	}
	return h.next.Handle(ctx, r)
}

// WithAttrs returns a Handler whose wrapped handler carries attrs.
func (h *Handler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &Handler{next: h.next.WithAttrs(attrs)}
}

// WithGroup returns a Handler whose wrapped handler opens the group name.
func (h *Handler) WithGroup(name string) slog.Handler {
	return &Handler{next: h.next.WithGroup(name)}
}
