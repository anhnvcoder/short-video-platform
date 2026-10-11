package outbox

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
)

// lockID is the transaction-scoped advisory lock a relay holds while it sends a batch, so only
// one relay per database sends at a time. Advisory locks are per database and each service has
// its own database, so one constant serves every service. The bytes spell "svpoutbx".
const lockID int64 = 0x7376706f75746278

// Defaults of a Relay; tests shorten them.
const (
	batchSize        = 100
	idleWait         = 200 * time.Millisecond
	produceTimeout   = 10 * time.Second
	retryBase        = 500 * time.Millisecond
	retryMax         = 10 * time.Second
	cleanupEvery     = 10 * time.Minute
	cleanupBatchSize = 1000
)

// Relay sends the unsent outbox rows of one database to Kafka, oldest id first.
type Relay struct {
	pool   *pgxpool.Pool
	client *kgo.Client
	logger *slog.Logger

	idleWait       time.Duration
	produceTimeout time.Duration
	retryBase      time.Duration
	retryMax       time.Duration
	cleanupEvery   time.Duration
}

// NewRelay returns a relay reading the outbox table through pool and producing with client.
func NewRelay(pool *pgxpool.Pool, client *kgo.Client, logger *slog.Logger) *Relay {
	return &Relay{
		pool:           pool,
		client:         client,
		logger:         logger,
		idleWait:       idleWait,
		produceTimeout: produceTimeout,
		retryBase:      retryBase,
		retryMax:       retryMax,
		cleanupEvery:   cleanupEvery,
	}
}

// Run sends batches until ctx is canceled. A full batch is followed at once by the next one, a
// partial or empty batch by a short wait; a failed batch is rolled back and retried with a
// growing wait. Run also deletes rows sent more than 24 hours ago, at start and then every 10
// minutes.
func (r *Relay) Run(ctx context.Context) {
	r.cleanup(ctx)
	cleanup := time.NewTicker(r.cleanupEvery)
	defer cleanup.Stop()
	next := time.NewTimer(0)
	defer next.Stop()
	failures := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-cleanup.C:
			r.cleanup(ctx)
		case <-next.C:
			n, err := r.sendBatch(ctx)
			switch {
			case ctx.Err() != nil:
				return
			case err != nil:
				wait := r.retryWait(failures)
				failures++
				r.logger.LogAttrs(ctx, slog.LevelWarn, "outbox relay failed, retrying",
					slog.Duration("backoff", wait), slog.String("error", err.Error()))
				next.Reset(wait)
			case n == batchSize:
				failures = 0
				next.Reset(0)
			default:
				failures = 0
				next.Reset(r.idleWait)
			}
		}
	}
}

// retryWait returns the wait after failures earlier consecutive failures: retryBase doubled
// for each, capped at retryMax.
func (r *Relay) retryWait(failures int) time.Duration {
	d := r.retryBase
	for range failures {
		if d >= r.retryMax {
			break
		}
		d *= 2
	}
	return min(d, r.retryMax)
}

type row struct {
	id        int64
	topic     string
	key       string
	payload   []byte
	headers   map[string]string
	createdAt time.Time
}

// sendBatch sends up to batchSize unsent rows in one transaction holding lockID and marks them
// sent. It returns the number of rows sent, 0 when another relay holds the lock. On any error
// the transaction rolls back and the rows stay unsent, including rows already produced.
func (r *Relay) sendBatch(ctx context.Context) (n int, err error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()

	var locked bool
	if err := tx.QueryRow(ctx, "SELECT pg_try_advisory_xact_lock($1)", lockID).Scan(&locked); err != nil {
		return 0, fmt.Errorf("take relay lock: %w", err)
	}
	if !locked {
		return 0, nil
	}

	rows, err := readUnsent(ctx, tx)
	if err != nil {
		return 0, err
	}
	if len(rows) == 0 {
		return 0, nil
	}

	records := make([]*kgo.Record, len(rows))
	rowIDs := make([]int64, len(rows))
	for i, x := range rows {
		records[i] = toRecord(x)
		rowIDs[i] = x.id
	}
	pctx, cancel := context.WithTimeout(ctx, r.produceTimeout)
	err = kafkax.Produce(pctx, r.client, records...)
	cancel()
	if err != nil {
		return 0, fmt.Errorf("send outbox rows %d..%d: %w", rowIDs[0], rowIDs[len(rowIDs)-1], err)
	}
	sentAt := time.Now()

	if _, err := tx.Exec(ctx, "UPDATE outbox SET published_at = now() WHERE id = ANY($1)", rowIDs); err != nil {
		return 0, fmt.Errorf("mark outbox rows sent: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("commit outbox rows sent: %w", err)
	}
	r.logger.LogAttrs(ctx, slog.LevelInfo, "outbox batch sent",
		slog.Int("rows", len(rows)),
		slog.Int64("first_id", rowIDs[0]),
		slog.Int64("last_id", rowIDs[len(rowIDs)-1]),
		slog.Duration("max_lag", sentAt.Sub(rows[0].createdAt)))
	return len(rows), nil
}

func readUnsent(ctx context.Context, tx pgx.Tx) ([]row, error) {
	rs, err := tx.Query(ctx,
		`SELECT id, topic, record_key, payload, headers, created_at
		   FROM outbox WHERE published_at IS NULL ORDER BY id LIMIT $1`, batchSize)
	if err != nil {
		return nil, fmt.Errorf("read outbox: %w", err)
	}
	out, err := pgx.CollectRows(rs, func(rs pgx.CollectableRow) (row, error) {
		var x row
		err := rs.Scan(&x.id, &x.topic, &x.key, &x.payload, &x.headers, &x.createdAt)
		return x, err
	})
	if err != nil {
		return nil, fmt.Errorf("read outbox: %w", err)
	}
	return out, nil
}

func toRecord(x row) *kgo.Record {
	rec := &kgo.Record{Topic: x.topic, Key: []byte(x.key), Value: x.payload}
	keys := make([]string, 0, len(x.headers))
	for k := range x.headers {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	for _, k := range keys {
		rec.Headers = append(rec.Headers, kgo.RecordHeader{Key: k, Value: []byte(x.headers[k])})
	}
	return rec
}

// cleanup deletes rows sent more than 24 hours ago, cleanupBatchSize rows per statement so no
// statement holds many row locks for long. Unsent rows are never deleted. Deleting is
// idempotent, so relays of several replicas may run it at the same time without the lock.
func (r *Relay) cleanup(ctx context.Context) {
	total := int64(0)
	for {
		tag, err := r.pool.Exec(ctx,
			`DELETE FROM outbox WHERE id IN (
			   SELECT id FROM outbox WHERE published_at < now() - interval '24 hours' LIMIT $1)`,
			cleanupBatchSize)
		if err != nil {
			if ctx.Err() == nil {
				r.logger.LogAttrs(ctx, slog.LevelWarn, "outbox cleanup failed",
					slog.Int64("deleted", total), slog.String("error", err.Error()))
			}
			return
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < cleanupBatchSize {
			break
		}
	}
	if total > 0 {
		r.logger.LogAttrs(ctx, slog.LevelInfo, "outbox cleanup done", slog.Int64("deleted", total))
	}
}
