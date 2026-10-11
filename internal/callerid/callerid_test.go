package callerid

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
)

const (
	loginMethod  = "/svp.user.v1.UserService/Login"
	followMethod = "/svp.user.v1.UserService/Follow"
	userID       = "01928c6e-7b3a-7cde-8f01-23456789abcd"
)

// call runs the interceptor for method with the given incoming metadata pairs and reports
// whether the handler ran and with which caller.
func call(t *testing.T, method string, pairs ...string) (ran bool, caller string, err error) {
	t.Helper()
	ctx := context.Background()
	if pairs != nil {
		ctx = metadata.NewIncomingContext(ctx, metadata.Pairs(pairs...))
	}
	handler := func(ctx context.Context, _ any) (any, error) {
		ran = true
		caller, _ = FromContext(ctx)
		return "ok", nil
	}
	_, err = UnaryServerInterceptor(loginMethod)(ctx, nil, &grpc.UnaryServerInfo{FullMethod: method}, handler)
	return ran, caller, err
}

func TestPublicMethodNeedsNoCaller(t *testing.T) {
	ran, caller, err := call(t, loginMethod)
	if err != nil || !ran {
		t.Fatalf("public method without x-user-id: ran = %v, err = %v; want handler to run", ran, err)
	}
	if caller != "" {
		t.Errorf("caller = %q, want none", caller)
	}
	if ran, _, err := call(t, loginMethod, MetadataKey, "garbage"); err != nil || !ran {
		t.Errorf("public method with an invalid x-user-id: ran = %v, err = %v; want handler to run", ran, err)
	}
}

func TestValidCallerReachesHandler(t *testing.T) {
	ran, caller, err := call(t, followMethod, MetadataKey, userID)
	if err != nil || !ran {
		t.Fatalf("ran = %v, err = %v; want handler to run", ran, err)
	}
	if caller != userID {
		t.Errorf("FromContext() = %q, want %q", caller, userID)
	}
}

func TestInvalidCallerIsUnauthenticated(t *testing.T) {
	tests := []struct {
		name  string
		pairs []string
	}{
		{"no metadata", nil},
		{"metadata without x-user-id", []string{"other", "x"}},
		{"two values", []string{MetadataKey, userID, MetadataKey, "01928c6e-7b3a-7cde-8f01-000000000000"}},
		{"two equal values", []string{MetadataKey, userID, MetadataKey, userID}},
		{"empty", []string{MetadataKey, ""}},
		{"upper case", []string{MetadataKey, strings.ToUpper(userID)}},
		{"braces", []string{MetadataKey, "{" + userID + "}"}},
		{"urn", []string{MetadataKey, "urn:uuid:" + userID}},
		{"no hyphens", []string{MetadataKey, strings.ReplaceAll(userID, "-", "")}},
		{"not a UUID", []string{MetadataKey, "admin"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ran, _, err := call(t, followMethod, tt.pairs...)
			if ran {
				t.Error("handler ran")
			}
			if status.Code(err) != codes.Unauthenticated || grpcerr.Reason(err) != ReasonUnauthenticatedCaller {
				t.Errorf("err = %v (reason %q), want UNAUTHENTICATED with %s", err, grpcerr.Reason(err), ReasonUnauthenticatedCaller)
			}
		})
	}
}

func TestCallerInLogAttributes(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(&buf, nil)))
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(MetadataKey, userID))
	handler := func(ctx context.Context, _ any) (any, error) {
		logger.InfoContext(ctx, "in handler")
		return nil, nil
	}
	if _, err := UnaryServerInterceptor()(ctx, nil, &grpc.UnaryServerInfo{FullMethod: followMethod}, handler); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), `"user_id":"`+userID+`"`) {
		t.Errorf("log line has no user_id: %s", buf.String())
	}
}

func TestFromContextWithoutCaller(t *testing.T) {
	if id, ok := FromContext(context.Background()); ok || id != "" {
		t.Errorf("FromContext() = (%q, %v), want (\"\", false)", id, ok)
	}
}
