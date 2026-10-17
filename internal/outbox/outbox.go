// Package outbox writes events to a service's outbox table in the transaction that changes the
// data, and relays them to Kafka in id order. Writing the event in the same transaction makes the
// data change and the event happen together or not at all, which a produce after the commit
// cannot promise (ADR-0003 option B, ADR-0008 section 7).
//
// # Table
//
// Each service creates the table in its own database with a goose migration:
//
//	CREATE TABLE outbox (
//	    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
//	    event_id     uuid        NOT NULL UNIQUE,
//	    topic        text        NOT NULL,
//	    record_key   text        NOT NULL,
//	    payload      bytea       NOT NULL,
//	    headers      jsonb       NOT NULL DEFAULT '{}',
//	    created_at   timestamptz NOT NULL DEFAULT now(),
//	    published_at timestamptz
//	);
//	CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;
//
// # Writing
//
// Lock the entity row first, then write its event, in the same transaction:
//
//	tx, err := pool.Begin(ctx)
//	...
//	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
//	if _, err := tx.Exec(ctx, "UPDATE videos SET status = 'PROCESSING' WHERE id = $1", id); err != nil { ... }
//	ev := &videov1.VideoEvent{Meta: outbox.NewMeta(), Event: &videov1.VideoEvent_VideoUploaded{...}}
//	if err := outbox.Write(ctx, tx, "video.lifecycle.v1", id, ev); err != nil { ... }
//	return tx.Commit(ctx)
//
// The relay sends rows in id order, and the id is taken when the row is inserted, not when the
// transaction commits. Two transactions on the same entity that both insert before locking can
// commit in one order and hold ids in the other, and the relay then sends the entity's events out
// of order. Locking the row first (UPDATE ... WHERE id = $1, or SELECT ... FOR UPDATE) makes the
// second transaction wait for the first to commit before it takes its id.
//
// # Relaying
//
// Every service that writes events runs one relay next to its server, until shutdown:
//
//	relay := outbox.NewRelay(pool, kafkaClient, logger)
//	go relay.Run(ctx)
//
// Delivery is at-least-once: a batch produced but not marked as sent (produce error, shutdown,
// crash) is sent again with the same event_id, so consumers must tolerate duplicates.
package outbox

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	eventv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/event/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
)

// Event is a topic's wrapper message, such as svp.video.v1.VideoEvent: the envelope in field 1,
// then the oneof of event types.
type Event interface {
	proto.Message
	GetMeta() *eventv1.EventMeta
}

// NewMeta returns an envelope with a new UUIDv7 event_id and the current time as occurred_at.
func NewMeta() *eventv1.EventMeta {
	return &eventv1.EventMeta{EventId: ids.New(), OccurredAt: timestamppb.Now()}
}

// Write adds ev to the outbox in tx, to be produced to topic with record key key (the entity
// id). The current trace context, if any, is stored in headers for the relay to extract.
// The caller must have locked the entity row in tx before calling Write (see the package doc).
func Write(ctx context.Context, tx pgx.Tx, topic, key string, ev Event) error {
	if topic == "" || key == "" {
		return errors.New("outbox: topic and key are required")
	}
	meta := ev.GetMeta()
	if meta.GetOccurredAt() == nil {
		return errors.New("outbox: event meta needs occurred_at")
	}
	if _, err := ids.Parse(meta.GetEventId()); err != nil {
		return fmt.Errorf("outbox: event meta event_id: %w", err)
	}
	payload, err := proto.Marshal(ev)
	if err != nil {
		return fmt.Errorf("outbox: marshal event: %w", err)
	}
	headers := map[string]string{}
	otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(headers))
	_, err = tx.Exec(ctx,
		"INSERT INTO outbox (event_id, topic, record_key, payload, headers) VALUES ($1, $2, $3, $4, $5)",
		meta.GetEventId(), topic, key, payload, headers)
	if err != nil {
		return fmt.Errorf("outbox: insert event: %w", err)
	}
	return nil
}
