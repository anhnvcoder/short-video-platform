// Package grpcerr builds gRPC errors that carry a machine-readable reason in a
// google.rpc.ErrorInfo status detail, and reads the reason back (docs/architecture.md §8.4).
package grpcerr

import (
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Domain is the ErrorInfo domain of every error the platform's services return.
const Domain = "svp"

// New returns a gRPC error with code and msg, carrying an ErrorInfo with reason (an
// UPPER_SNAKE_CASE constant such as VIDEO_NOT_FOUND) and Domain.
func New(code codes.Code, reason, msg string) error {
	st := status.New(code, msg)
	withInfo, err := st.WithDetails(&errdetails.ErrorInfo{Reason: reason, Domain: Domain})
	if err != nil {
		// Only fails for code OK or a detail that cannot be marshaled; neither is a real error.
		return st.Err()
	}
	return withInfo.Err()
}

// Reason returns the reason of the first ErrorInfo with Domain in err's status details, or ""
// when err is not a gRPC status error or carries no such detail.
func Reason(err error) string {
	st, ok := status.FromError(err)
	if !ok {
		return ""
	}
	for _, d := range st.Details() {
		if info, ok := d.(*errdetails.ErrorInfo); ok && info.GetDomain() == Domain {
			return info.GetReason()
		}
	}
	return ""
}
