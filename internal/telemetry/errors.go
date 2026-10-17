package telemetry

import (
	"log/slog"
	"sync"
	"time"
)

type errorHandler struct {
	mu         sync.Mutex
	now        func() time.Time
	last       time.Time
	suppressed uint64
}

func newErrorHandler(now func() time.Time) *errorHandler { return &errorHandler{now: now} }

func (h *errorHandler) Handle(err error) {
	h.mu.Lock()
	now := h.now()
	if !h.last.IsZero() && now.Sub(h.last) < time.Minute {
		h.suppressed++
		h.mu.Unlock()
		return
	}
	suppressed := h.suppressed
	h.last, h.suppressed = now, 0
	h.mu.Unlock()
	// Release the lock before logging: exporting this warning may itself fail.
	slog.Default().Warn("telemetry export failed", slog.Any("error", err), slog.Uint64("suppressed", suppressed))
}
