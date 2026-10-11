package grpcerr

import (
	"errors"
	"fmt"
	"testing"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestNewCarriesCodeMessageAndErrorInfo(t *testing.T) {
	err := New(codes.NotFound, "VIDEO_NOT_FOUND", "video not found")

	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("New() returned a non-status error: %v", err)
	}
	if st.Code() != codes.NotFound || st.Message() != "video not found" {
		t.Errorf("status = (%v, %q), want (NotFound, %q)", st.Code(), st.Message(), "video not found")
	}
	details := st.Details()
	if len(details) != 1 {
		t.Fatalf("got %d details, want 1", len(details))
	}
	info, ok := details[0].(*errdetails.ErrorInfo)
	if !ok {
		t.Fatalf("detail is %T, want *errdetails.ErrorInfo", details[0])
	}
	if info.GetReason() != "VIDEO_NOT_FOUND" || info.GetDomain() != "svp" {
		t.Errorf("ErrorInfo = (%q, %q), want (VIDEO_NOT_FOUND, svp)", info.GetReason(), info.GetDomain())
	}
}

func TestReason(t *testing.T) {
	foreign, err := status.New(codes.Internal, "x").WithDetails(&errdetails.ErrorInfo{Reason: "QUOTA", Domain: "googleapis.com"})
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "svp error", err: New(codes.Unauthenticated, "INVALID_CREDENTIALS", "invalid credentials"), want: "INVALID_CREDENTIALS"},
		{name: "wrapped svp error", err: fmt.Errorf("login: %w", New(codes.AlreadyExists, "EMAIL_TAKEN", "taken")), want: "EMAIL_TAKEN"},
		{name: "status without details", err: status.Error(codes.Internal, "boom"), want: ""},
		{name: "foreign domain", err: foreign.Err(), want: ""},
		{name: "plain error", err: errors.New("plain"), want: ""},
		{name: "nil", err: nil, want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Reason(tt.err); got != tt.want {
				t.Errorf("Reason() = %q, want %q", got, tt.want)
			}
		})
	}
}
