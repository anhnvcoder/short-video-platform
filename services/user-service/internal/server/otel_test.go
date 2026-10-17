package server

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"log/slog"
	"strings"
	"testing"

	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/pgpool"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/password"
)

// Register and Login on the pool serve opens (pgpool, with SQL spans) leave neither the email nor
// the password in any span: names, attributes, events and statuses.
func TestSpansHoldNoSecrets(t *testing.T) {
	if testPool == nil {
		t.Skip(skipReason)
	}
	previous := otel.GetTracerProvider()
	recorder := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder), sdktrace.WithSampler(sdktrace.AlwaysSample()))
	otel.SetTracerProvider(tp)
	t.Cleanup(func() {
		otel.SetTracerProvider(previous)
		if err := tp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	})
	pool, err := pgpool.New(t.Context(), testPool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s := New(pool, password.NewHasher(), authtoken.NewIssuer("test", key), slog.New(slog.DiscardHandler))

	email := "Span.Check-" + ids.New() + "@Example.io"
	const wrongPassword = "wrong password!"
	// The span the gRPC server instrumentation opens around each call.
	ctx, span := otel.Tracer("test").Start(t.Context(), "svp.user.v1.UserService/Register")
	_, err = s.Register(ctx, &userv1.RegisterRequest{Email: email, Password: testPassword})
	span.End()
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	for _, pw := range []string{testPassword, wrongPassword} {
		ctx, span := otel.Tracer("test").Start(t.Context(), "svp.user.v1.UserService/Login")
		_, _ = s.Login(ctx, &userv1.LoginRequest{Email: email, Password: pw})
		span.End()
	}

	var sql int
	for _, sp := range recorder.Ended() {
		if sp.InstrumentationScope().Name != "test" {
			sql++
		}
		texts := []string{sp.Name(), sp.Status().Description}
		attrs := sp.Attributes()
		for _, ev := range sp.Events() {
			texts = append(texts, ev.Name)
			attrs = append(attrs, ev.Attributes...)
		}
		for _, a := range attrs {
			texts = append(texts, string(a.Key), a.Value.String())
		}
		for _, text := range texts {
			for _, leak := range []string{email, strings.ToLower(email), testPassword, wrongPassword} {
				if strings.Contains(text, leak) {
					t.Errorf("span %q holds %q in %q", sp.Name(), leak, text)
				}
			}
		}
	}
	if sql == 0 {
		t.Error("no SQL span recorded: the check above saw nothing")
	}
	t.Logf("%d spans checked, %d of them from the database", len(recorder.Ended()), sql)
}
