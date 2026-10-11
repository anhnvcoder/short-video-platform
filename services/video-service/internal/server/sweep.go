package server

import (
	"context"
	"fmt"
	"log/slog"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/anhnvcoder/short-video-platform/internal/objstore"
	"github.com/anhnvcoder/short-video-platform/services/video-service/internal/store"
)

// sweepLockID is the transaction-scoped advisory lock a sweep batch holds, so only one instance
// sweeps at a time. It differs from the outbox relay's lock in the same database. The bytes spell
// "svpupswp".
const sweepLockID int64 = 0x7376707570737770

const (
	// sweepBatchSize is the most videos one sweep transaction locks.
	sweepBatchSize = 100
	// sweepBatchTimeout bounds one sweep transaction, its S3 deletes included, so a hung call
	// does not hold the row locks that CompleteUpload waits for. Tests shorten it.
	sweepBatchTimeout = 30 * time.Second
)

// UploadSweeper moves videos left UPLOADING for too long to FAILED and deletes their upload
// (ADR-0004 rule 4, docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 5).
type UploadSweeper struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	storage Storage
	logger  *slog.Logger

	abandonAfter time.Duration
	interval     time.Duration
	batchTimeout time.Duration
}

// NewUploadSweeper returns a sweeper that, every interval, fails the videos UPLOADING for more
// than abandonAfter.
func (s *Server) NewUploadSweeper(abandonAfter, interval time.Duration) *UploadSweeper {
	return &UploadSweeper{
		pool:         s.pool,
		queries:      s.queries,
		storage:      s.storage,
		logger:       s.logger,
		abandonAfter: abandonAfter,
		interval:     interval,
		batchTimeout: sweepBatchTimeout,
	}
}

// Run sweeps once at start, then every interval, until ctx is canceled.
func (w *UploadSweeper) Run(ctx context.Context) {
	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	for {
		w.sweep(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// sweep runs one round and returns how many videos it moved to FAILED. The next batch starts
// at once only when the last one was full and failed every video it selected; a short batch, a
// delete error or a batch error ends the round, so videos whose delete failed are retried in the
// next round instead of being selected again and again.
func (w *UploadSweeper) sweep(ctx context.Context) int {
	total := 0
	for {
		selected, failed, err := w.sweepBatch(ctx)
		total += failed
		if err != nil {
			if ctx.Err() == nil {
				w.logger.LogAttrs(ctx, slog.LevelWarn, "upload sweep failed",
					slog.Int("videos", total), slog.String("error", err.Error()))
			}
			break
		}
		if selected < sweepBatchSize || failed < selected {
			break
		}
	}
	if total > 0 {
		w.logger.LogAttrs(ctx, slog.LevelInfo, "abandoned uploads swept", slog.Int("videos", total))
	}
	return total
}

// sweepBatch locks up to sweepBatchSize of the oldest abandoned videos, deletes their upload and moves
// the videos whose delete succeeded to FAILED, in one transaction bounded by batchTimeout. It
// returns how many videos it selected and how many it moved, both 0 when another instance holds
// the sweep lock. On an error the transaction rolls back: every video stays UPLOADING, and an
// upload already deleted is deleted again, without error, next time.
func (w *UploadSweeper) sweepBatch(ctx context.Context) (selected, failed int, err error) {
	ctx, cancel := context.WithTimeout(ctx, w.batchTimeout)
	defer cancel()
	tx, err := w.pool.Begin(ctx)
	if err != nil {
		return 0, 0, fmt.Errorf("begin: %w", err)
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	q := w.queries.WithTx(tx)

	locked, err := q.TryLockUploadSweep(ctx, sweepLockID)
	if err != nil {
		return 0, 0, fmt.Errorf("take sweep lock: %w", err)
	}
	if !locked {
		return 0, 0, nil
	}
	videos, err := q.ListAbandonedUploads(ctx, store.ListAbandonedUploadsParams{
		CreatedBefore: time.Now().Add(-w.abandonAfter),
		MaxVideos:     sweepBatchSize,
	})
	if err != nil {
		return 0, 0, fmt.Errorf("select abandoned uploads: %w", err)
	}
	if len(videos) == 0 {
		return 0, 0, nil
	}

	// An UPLOADING video has no HLS output yet, so only its upload is deleted.
	deleted := make([]uuid.UUID, 0, len(videos))
	for _, v := range videos {
		if err := w.storage.Delete(ctx, objstore.UploadsPrefix+v.ID.String()); err != nil {
			if ctx.Err() != nil {
				return 0, 0, fmt.Errorf("delete abandoned uploads: %w", err)
			}
			w.logger.LogAttrs(ctx, slog.LevelWarn, "delete abandoned upload",
				slog.String("video_id", v.ID.String()), slog.String("error", err.Error()))
			continue
		}
		deleted = append(deleted, v.ID)
	}
	if len(deleted) == 0 {
		return len(videos), 0, nil
	}
	moved, err := q.MarkUploadsFailed(ctx, deleted)
	if err != nil {
		return 0, 0, fmt.Errorf("mark abandoned uploads failed: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, 0, fmt.Errorf("commit abandoned uploads: %w", err)
	}
	for _, v := range moved {
		w.logger.LogAttrs(ctx, slog.LevelInfo, "upload abandoned",
			slog.String("video_id", v.ID.String()), slog.String("user_id", v.AuthorID.String()))
	}
	return len(videos), len(moved), nil
}
