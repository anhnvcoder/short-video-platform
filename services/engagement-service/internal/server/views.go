package server

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
	"strings"
	"time"
	"uuid"

	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/services/engagement-service/internal/store"
)

// ViewsGroup is the consumer group that counts TopicViews; it also names the group's rows in
// consumer_offsets.
const ViewsGroup = "engagement-service"

// viewsHandlerTimeout bounds one attempt at a batch: the end offset lookup and the transaction,
// commit included, so a stuck lock or a slow broker fails the attempt and kafkax retries it
// (docs/adr/0011-observability-stage3.md, section 11).
const viewsHandlerTimeout = 30 * time.Second

// ViewsConsumerConfig returns the batch consumer of TopicViews in ViewsGroup, with the batch
// size and retry settings of kafkax: up to 5,000 records or 1 s a batch, few transactions at
// 10,000 views a second, and retries without limit, since a batch sent to the dead-letter topic
// for a database outage would lose its views (ADR-0009, section 4). A batch attempt past
// viewsHandlerTimeout is retried like any other failure.
func (s *Server) ViewsConsumerConfig(brokers string) kafkax.BatchConsumerConfig {
	return kafkax.BatchConsumerConfig{
		Brokers:        brokers,
		ClientID:       ViewsGroup,
		Group:          ViewsGroup,
		Topics:         []string{TopicViews},
		Handler:        s.HandleViews,
		Logger:         s.logger,
		HandlerTimeout: viewsHandlerTimeout,
	}
}

// partitionSpan is the first and last offset of one partition's records in a batch.
type partitionSpan struct{ first, last int64 }

// view is a decoded view.recorded with the record it came from.
type view struct {
	r       *kgo.Record
	videoID uuid.UUID
}

// HandleViews is the kafkax.BatchHandler of TopicViews (ADR-0009, section 4). It adds the views
// of the batch to view_counts in one transaction that also moves each partition's next_offset in
// consumer_offsets, and skips records below the stored next_offset: those were counted by an
// earlier delivery. A redelivered record is therefore counted once, however Kafka's own commit
// went.
//
// Records that do not decode are rejected on every delivery, so they reach the dead-letter
// topic at least once; their offsets still move next_offset. A database error, or a failed end
// offset lookup, returns an error and kafkax retries the whole batch.
func (s *Server) HandleViews(ctx context.Context, b *kafkax.Batch) ([]kafkax.Rejected, error) {
	var (
		views    []view
		rejected []kafkax.Rejected
		spans    = map[kafkax.TopicPartition]partitionSpan{}
	)
	for _, r := range b.Records {
		tp := kafkax.TopicPartition{Topic: r.Topic, Partition: r.Partition}
		if sp, ok := spans[tp]; ok {
			spans[tp] = partitionSpan{first: min(sp.first, r.Offset), last: max(sp.last, r.Offset)}
		} else {
			spans[tp] = partitionSpan{first: r.Offset, last: r.Offset}
		}
		videoID, err := decodeView(r)
		if err != nil {
			rejected = append(rejected, kafkax.Rejected{Record: r, Err: err})
			continue
		}
		views = append(views, view{r: r, videoID: videoID})
	}
	if len(spans) == 0 {
		return nil, nil
	}

	if err := s.inTx(ctx, func(q *store.Queries) error { return s.countViews(ctx, q, views, spans) }); err != nil {
		return nil, fmt.Errorf("count %d views: %w", len(views), err)
	}
	return rejected, nil
}

// countViews runs in the batch's transaction: it locks the offset row of every partition in the
// batch, adds the views at or past each stored next_offset, and moves next_offset past the batch.
func (s *Server) countViews(ctx context.Context, q *store.Queries, views []view,
	spans map[kafkax.TopicPartition]partitionSpan,
) error {
	// Lock the offset rows in ascending partition order, so two batches never wait on each other
	// in a cycle.
	tps := slices.SortedFunc(maps.Keys(spans), func(a, b kafkax.TopicPartition) int {
		return cmp.Or(strings.Compare(a.Topic, b.Topic), cmp.Compare(a.Partition, b.Partition))
	})
	next := make(map[kafkax.TopicPartition]int64, len(tps))
	var beyond []kafkax.TopicPartition
	for _, tp := range tps {
		key := store.InsertConsumerOffsetParams{ConsumerGroup: ViewsGroup, Topic: tp.Topic, Partition: tp.Partition}
		if err := q.InsertConsumerOffset(ctx, key); err != nil {
			return fmt.Errorf("insert offset of %s/%d: %w", tp.Topic, tp.Partition, err)
		}
		n, err := q.LockConsumerOffset(ctx, store.LockConsumerOffsetParams(key))
		if err != nil {
			return fmt.Errorf("lock offset of %s/%d: %w", tp.Topic, tp.Partition, err)
		}
		next[tp] = n
		if n > spans[tp].last+1 {
			beyond = append(beyond, tp)
		}
	}
	if err := s.resetRecreated(ctx, beyond, spans, next); err != nil {
		return err
	}

	counts := map[uuid.UUID]int64{}
	for _, v := range views {
		if v.r.Offset >= next[kafkax.TopicPartition{Topic: v.r.Topic, Partition: v.r.Partition}] {
			counts[v.videoID]++
		}
	}
	if len(counts) > 0 {
		// One row per video in ascending order: Postgres rejects an upsert that touches a row
		// twice, and a fixed order means two batches lock the counters of hot videos alike.
		videoIDs := slices.SortedFunc(maps.Keys(counts), uuid.UUID.Compare)
		add := store.AddViewCountsParams{VideoIds: videoIDs, Counts: make([]int64, len(videoIDs))}
		for i, id := range videoIDs {
			add.Counts[i] = counts[id]
		}
		if err := q.AddViewCounts(ctx, add); err != nil {
			return fmt.Errorf("add view counts of %d videos: %w", len(videoIDs), err)
		}
	}

	for _, tp := range tps {
		// Never lower the offset: a redelivered batch can be shorter than the one counted before.
		err := q.SetConsumerOffset(ctx, store.SetConsumerOffsetParams{
			NextOffset:    max(next[tp], spans[tp].last+1),
			ConsumerGroup: ViewsGroup,
			Topic:         tp.Topic,
			Partition:     tp.Partition,
		})
		if err != nil {
			return fmt.Errorf("set offset of %s/%d: %w", tp.Topic, tp.Partition, err)
		}
	}
	return nil
}

// resetRecreated handles the partitions whose stored next_offset lies beyond the batch. It asks
// the broker for their current end offsets, now that their rows are locked: an offset written by
// a committed transaction belongs to a record already on the log, so it can only exceed the end
// offset when the topic was deleted and created again. Such a partition starts over from its
// first record in the batch. Otherwise the batch is a redelivery that was already counted, and
// next_offset stays.
func (s *Server) resetRecreated(ctx context.Context, tps []kafkax.TopicPartition,
	spans map[kafkax.TopicPartition]partitionSpan, next map[kafkax.TopicPartition]int64,
) error {
	if len(tps) == 0 {
		return nil
	}
	ends, err := kafkax.EndOffsets(ctx, s.producer, tps...)
	if err != nil {
		return err
	}
	for _, tp := range tps {
		if next[tp] <= ends[tp] {
			continue
		}
		s.logger.LogAttrs(ctx, slog.LevelWarn, "stored offset is beyond the end of the partition, topic was recreated: counting from the batch",
			slog.String("topic", tp.Topic), slog.Int("partition", int(tp.Partition)),
			slog.Int64("stored_next_offset", next[tp]), slog.Int64("end_offset", ends[tp]),
			slog.Int64("reset_to", spans[tp].first))
		next[tp] = spans[tp].first
	}
	return nil
}

// decodeView returns the video id of a view.recorded record, or why the record is not one.
func decodeView(r *kgo.Record) (uuid.UUID, error) {
	var ev engagementv1.ViewEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		return uuid.UUID{}, fmt.Errorf("decode ViewEvent: %w", err)
	}
	v := ev.GetViewRecorded()
	if v == nil {
		return uuid.UUID{}, errors.New("ViewEvent has no view_recorded")
	}
	videoID, err := ids.Parse(v.GetVideoId())
	if err != nil {
		return uuid.UUID{}, fmt.Errorf("view_recorded.video_id: %w", err)
	}
	if _, err := ids.Parse(v.GetViewerId()); err != nil {
		return uuid.UUID{}, fmt.Errorf("view_recorded.viewer_id: %w", err)
	}
	return videoID, nil
}
