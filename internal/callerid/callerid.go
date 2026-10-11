// Package callerid reads the caller's user id from the x-user-id gRPC metadata the gateway sets
// after verifying the JWT (docs/adr/0006-contract-ids-and-event-envelope.md, section 5; threat
// model IN-1, IN-2).
//
// There is deliberately no helper that copies incoming metadata onward: the gateway builds
// outgoing metadata from scratch with only the values it sets.
package callerid

import (
	"context"
	"log/slog"
	"slices"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"

	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
)

// MetadataKey is the gRPC metadata key carrying the authenticated user id.
const MetadataKey = "x-user-id"

// ReasonUnauthenticatedCaller is the ErrorInfo reason when x-user-id is missing or invalid.
const ReasonUnauthenticatedCaller = "UNAUTHENTICATED_CALLER"

type ctxKey struct{}

// UnaryServerInterceptor requires a caller on every RPC except the full method names in public
// (e.g. "/svp.user.v1.UserService/Login"). Unless public, an RPC whose metadata does not hold
// exactly one x-user-id value in canonical UUID form fails with UNAUTHENTICATED before the
// handler runs; otherwise the user id goes into the context (FromContext) and into the log
// attributes as user_id. Public RPCs ignore x-user-id.
func UnaryServerInterceptor(public ...string) grpc.UnaryServerInterceptor {
	public = slices.Clone(public)
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if slices.Contains(public, info.FullMethod) {
			return handler(ctx, req)
		}
		md, _ := metadata.FromIncomingContext(ctx)
		values := md.Get(MetadataKey)
		if len(values) != 1 {
			return nil, unauthenticated()
		}
		if _, err := ids.Parse(values[0]); err != nil {
			return nil, unauthenticated()
		}
		ctx = context.WithValue(ctx, ctxKey{}, values[0])
		ctx = logx.With(ctx, slog.String("user_id", values[0]))
		return handler(ctx, req)
	}
}

// FromContext returns the caller's user id put into ctx by UnaryServerInterceptor, and false
// when there is none (a public RPC).
func FromContext(ctx context.Context) (string, bool) {
	id, ok := ctx.Value(ctxKey{}).(string)
	return id, ok
}

func unauthenticated() error {
	return grpcerr.New(codes.Unauthenticated, ReasonUnauthenticatedCaller, "missing or invalid caller identity")
}
