package traceparent

import "context"

type ctxKey struct{}

// NewContext returns a copy of ctx carrying the raw traceparent value v, so code that writes
// events (outbox rows, Kafka headers) passes the same value on.
func NewContext(ctx context.Context, v string) context.Context {
	return context.WithValue(ctx, ctxKey{}, v)
}

// FromContext returns the value stored by NewContext and true, or "" and false when there is
// none.
func FromContext(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(ctxKey{}).(string)
	return v, ok
}
