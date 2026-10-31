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

	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/logx"
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

const statsMethod = "/svp.engagement.v1.EngagementService/GetStats"

// callOptional is call with statsMethod as an RPC whose caller is optional, and loginMethod public.
func callOptional(t *testing.T, method string, pairs ...string) (ran bool, caller string, err error) {
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
	interceptor := NewUnaryServerInterceptor(Methods{Public: []string{loginMethod}, OptionalCaller: []string{statsMethod}})
	_, err = interceptor(ctx, nil, &grpc.UnaryServerInfo{FullMethod: method}, handler)
	return ran, caller, err
}

func TestOptionalCallerAbsentRunsWithoutCaller(t *testing.T) {
	for name, pairs := range map[string][]string{"no metadata": nil, "metadata without x-user-id": {"other", "x"}} {
		ran, caller, err := callOptional(t, statsMethod, pairs...)
		if err != nil || !ran {
			t.Errorf("%s: ran = %v, err = %v; want handler to run", name, ran, err)
		}
		if caller != "" {
			t.Errorf("%s: caller = %q, want none", name, caller)
		}
	}
}

func TestOptionalCallerPresentAndValidReachesHandler(t *testing.T) {
	ran, caller, err := callOptional(t, statsMethod, MetadataKey, userID)
	if err != nil || !ran {
		t.Fatalf("ran = %v, err = %v; want handler to run", ran, err)
	}
	if caller != userID {
		t.Errorf("FromContext() = %q, want %q", caller, userID)
	}
}

// A present x-user-id must be valid: a malformed one is never served as an anonymous call.
func TestOptionalCallerPresentButInvalidIsUnauthenticated(t *testing.T) {
	for _, tc := range []struct {
		name  string
		pairs []string
	}{
		{"empty", []string{MetadataKey, ""}},
		{"two values", []string{MetadataKey, userID, MetadataKey, userID}},
		{"upper case", []string{MetadataKey, strings.ToUpper(userID)}},
		{"not a UUID", []string{MetadataKey, "admin"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ran, _, err := callOptional(t, statsMethod, tc.pairs...)
			if ran {
				t.Error("handler ran")
			}
			if status.Code(err) != codes.Unauthenticated || grpcerr.Reason(err) != ReasonUnauthenticatedCaller {
				t.Errorf("err = %v (reason %q), want UNAUTHENTICATED with %s", err, grpcerr.Reason(err), ReasonUnauthenticatedCaller)
			}
		})
	}
}

// Listing some RPCs as optional or public changes nothing for the others.
func TestOptionalCallerLeavesOtherModesAlone(t *testing.T) {
	if ran, _, err := callOptional(t, followMethod); ran || status.Code(err) != codes.Unauthenticated {
		t.Errorf("required caller without x-user-id: ran = %v, err = %v; want UNAUTHENTICATED", ran, err)
	}
	if ran, caller, err := callOptional(t, followMethod, MetadataKey, userID); err != nil || !ran || caller != userID {
		t.Errorf("required caller with x-user-id: ran = %v, caller = %q, err = %v", ran, caller, err)
	}
	if ran, caller, err := callOptional(t, loginMethod, MetadataKey, "garbage"); err != nil || !ran || caller != "" {
		t.Errorf("public method with an invalid x-user-id: ran = %v, caller = %q, err = %v; want handler to run without caller", ran, caller, err)
	}
}
