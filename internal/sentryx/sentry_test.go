package sentryx

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"log/slog"
	"net/http"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"
	"github.com/jackc/pgx/v5/pgconn"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/anhnvcoder/short-video-platform/internal/secret"
)

type transport struct {
	mu      sync.Mutex
	events  []*sentry.Event
	options sentry.ClientOptions
	timeout time.Duration
}

func (t *transport) Configure(options sentry.ClientOptions) { t.options = options }
func (*transport) Close()                                   {}
func (t *transport) Flush(timeout time.Duration) bool {
	t.timeout = timeout
	return true
}
func (*transport) FlushWithContext(context.Context) bool { return true }
func (t *transport) SendEvent(event *sentry.Event) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.events = append(t.events, event)
}
func (t *transport) captured() []*sentry.Event {
	t.mu.Lock()
	defer t.mu.Unlock()
	return slices.Clone(t.events)
}

func setup(t *testing.T) (*transport, *slog.Logger) {
	t.Helper()
	t.Setenv("SENTRY_DSN", "http://public@tracker.invalid/1")
	t.Setenv("SENTRY_ENVIRONMENT", "")
	tr := &transport{}
	flush, err := initClient("test-service", tr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(flush)
	return tr, slog.New(&Handler{})
}

func captured(t *testing.T, tr *transport) []*sentry.Event {
	t.Helper()
	if r := active.Load(); r != nil && !r.client.Flush(time.Second) {
		t.Fatal("fake transport did not flush")
	}
	return tr.captured()
}

func eventJSON(t *testing.T, event *sentry.Event) string {
	t.Helper()
	data, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func assertNoSecrets(t *testing.T, event *sentry.Event, values ...string) {
	t.Helper()
	data := eventJSON(t, event)
	for _, value := range values {
		if strings.Contains(data, value) {
			t.Errorf("event contains forbidden value %q", value)
		}
	}
}

func TestErrorEventContainsOnlySafeMetadata(t *testing.T) {
	tr, logger := setup(t)
	const password = "hunter2-Secret!"
	const email = "alice@example.com"
	const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"
	const id = "0192f0c4-0000-7000-8000-000000000001"
	sc := trace.NewSpanContext(trace.SpanContextConfig{TraceID: trace.TraceID{1}, SpanID: trace.SpanID{2}})
	ctx := trace.ContextWithSpanContext(context.Background(), sc)
	err := fmt.Errorf("login %s: %w", email, fmt.Errorf("pw %s: %w", password,
		&pgconn.PgError{Code: "23505", Message: password + email + jwt, Detail: "Authorization"}))
	logger.With("user_id", id).ErrorContext(ctx, "internal error",
		"error", err, "email", email, "password", password, "token", jwt,
		"authorization", "Authorization "+jwt, "headers", http.Header{"Authorization": {jwt}},
		"body", password, "route", "POST /videos/{video_id}", "status", 500,
		"code", "Internal", "method", "/svp.user.v1.UserService/Login", "target", "user-service",
		"topic", "video.ready", "partition", 1, "offset", int64(20), "loop", "outbox-relay",
		"video_id", id, "event_id", id, "trace_id", email, "span_id", jwt,
		slog.Group("request", slog.String("route", "POST /private"), slog.String("password", password)))
	events := captured(t, tr)
	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	event := events[0]
	assertNoSecrets(t, event, password, email, jwt, "Authorization", "request", "private")
	if event.Message != "internal error" || event.Tags["service"] != "test-service" || event.Environment != "local" {
		t.Fatalf("unexpected event metadata: %s", eventJSON(t, event))
	}
	if event.Tags["trace_id"] != sc.TraceID().String() || event.Tags["span_id"] != sc.SpanID().String() ||
		event.Contexts["trace"]["trace_id"] != sc.TraceID().String() {
		t.Error("event lost span correlation")
	}
	for _, key := range []string{"method", "route", "status", "code", "target", "topic", "partition", "offset", "loop", "video_id", "user_id", "event_id"} {
		if event.Tags[key] == "" {
			t.Errorf("missing safe attribute %s", key)
		}
	}
	if len(event.Exception) != 1 || event.Exception[0].Type != "*pgconn.PgError" || event.Exception[0].Value != "23505" {
		t.Fatalf("unexpected exception: %+v", event.Exception)
	}
}

func TestArbitraryMessageErrorsAndPanicNeverLeaveMachine(t *testing.T) {
	for _, panicRecord := range []bool{false, true} {
		t.Run(strconv.FormatBool(panicRecord), func(t *testing.T) {
			tr, logger := setup(t)
			const password = "hunter2-Secret!"
			const email = "alice@example.com"
			const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"
			message := "login " + password + email + jwt
			attrs := []any{"error", fmt.Errorf("login: %w", fmt.Errorf("pw %s", password)),
				"route", "/x?pw=" + password, "method", password, "target", secret.New(password),
				"topic", secret.New(password), "loop", email, "user_id", jwt}
			if panicRecord {
				message = "panic in http handler"
				attrs = append(attrs, "panic", "bad password "+password, "stack", string(debug.Stack()))
			}
			logger.Error(message, attrs...)
			events := captured(t, tr)
			if len(events) != 1 {
				t.Fatalf("events = %d, want 1", len(events))
			}
			event := events[0]
			assertNoSecrets(t, event, password, email, jwt, "Authorization", "bad password", "pw ")
			if panicRecord {
				if event.Exception[0].Type != "string" || event.Exception[0].Stacktrace == nil ||
					len(event.Exception[0].Stacktrace.Frames) == 0 {
					t.Fatalf("missing panic type/stack: %+v", event.Exception)
				}
			} else if event.Message != "unlisted error" || event.Exception[0].Type != "*errors.errorString" {
				t.Fatalf("unexpected filtered error: %s", eventJSON(t, event))
			}
		})
	}
}

func TestWrappedGRPCErrorOnlyReportsTypeAndCode(t *testing.T) {
	tr, logger := setup(t)
	logger.Error("grpc call failed", "error", fmt.Errorf("password: %w", status.Error(codes.Internal, "hunter2-Secret!")))
	event := captured(t, tr)[0]
	assertNoSecrets(t, event, "password", "hunter2-Secret!")
	if event.Exception[0].Type != "*status.Error" || event.Exception[0].Value != "Internal" {
		t.Fatalf("unexpected exception: %+v", event.Exception)
	}
}

type unprintableError struct{}

func (unprintableError) Error() string { panic("error text must not be evaluated") }

func TestHandlerDoesNotEvaluateErrorText(t *testing.T) {
	tr, logger := setup(t)
	logger.Error("internal error", "error", unprintableError{})
	event := captured(t, tr)[0]
	if event.Exception[0].Type != "sentryx.unprintableError" || event.Exception[0].Value != "" {
		t.Fatalf("unexpected exception: %+v", event.Exception)
	}
}

func TestSafeAttributeDomains(t *testing.T) {
	const id = "0192f0c4-0000-7000-8000-00000000000a"
	valid := []slog.Attr{
		slog.String("video_id", id), slog.String("user_id", id), slog.String("event_id", id),
		slog.Int("status", 500), slog.Int64("partition", 0), slog.Uint64("offset", 22),
		slog.String("code", "23505"), slog.String("code", "DeadlineExceeded"),
		slog.String("method", "POST"), slog.String("method", "/svp.user.v1.UserService/Login"),
		slog.String("route", "GET /videos/{video_id}"), slog.String("topic", "video.ready"),
		slog.String("target", "video-service"), slog.String("loop", "outbox-relay"),
	}
	invalid := []slog.Attr{
		slog.String("video_id", strings.ToUpper(id)), slog.String("user_id", "alice@example.com"),
		slog.String("event_id", "bad"), slog.String("status", "500"), slog.Float64("offset", 1),
		slog.String("partition", "1"), slog.String("code", "internal"), slog.String("code", "123456"),
		slog.String("method", "get"), slog.String("method", "/no-service/Login"),
		slog.String("route", "/videos"), slog.String("route", "GET /x?pw=hunter2-Secret!"),
		slog.String("route", "GET /x Authorization"), slog.String("topic", "alice@example.com"),
		slog.String("loop", strings.Repeat("a", 65)), slog.String("target", "User Service"),
		slog.Any("target", secret.New("hidden")), slog.Any("status", secret.New("500")),
		slog.String("email", "alice@example.com"), slog.Group("group", slog.String("topic", "video.ready")),
	}
	for _, a := range valid {
		if _, ok := safeAttr(a); !ok {
			t.Errorf("rejected valid attribute %s (%v)", a.Key, a.Value)
		}
	}
	for _, a := range invalid {
		if _, ok := safeAttr(a); ok {
			t.Errorf("accepted invalid attribute %s (%v)", a.Key, a.Value)
		}
	}
}

// Frames of dependencies keep their place in a panic's stack: their files are under the module
// cache, path@version, with or without -trimpath.
func TestStackKeepsModuleCacheFrames(t *testing.T) {
	const raw = "goroutine 7 [running]:\n" +
		"google.golang.org/grpc.(*Server).processUnaryRPC(0xc000123400, {0x1, 0x2})\n" +
		"\t/root/go/pkg/mod/google.golang.org/grpc@v1.75.0/server.go:1405 +0x1c4\n" +
		"github.com/BurntSushi/toml.parse(...)\n" +
		"\tgithub.com/!burnt!sushi/toml@v1.2.0+incompatible/parse.go:10\n" +
		"main.main()\n" +
		"\t/src/main.go:5 +0x10\n"
	st := parseStack(raw)
	if st == nil || len(st.Frames) != 3 {
		t.Fatalf("frames = %+v, want 3", st)
	}
	// Sentry lists the outermost frame first.
	want := []sentry.Frame{
		{Function: "main.main", Filename: "/src/main.go", Lineno: 5},
		{Function: "github.com/BurntSushi/toml.parse", Filename: "github.com/!burnt!sushi/toml@v1.2.0+incompatible/parse.go", Lineno: 10},
		{Function: "google.golang.org/grpc.(*Server).processUnaryRPC", Filename: "/root/go/pkg/mod/google.golang.org/grpc@v1.75.0/server.go", Lineno: 1405},
	}
	for i, f := range st.Frames {
		if f.Function != want[i].Function || f.Filename != want[i].Filename || f.Lineno != want[i].Lineno {
			t.Errorf("frame %d = %s %s:%d, want %s %s:%d", i, f.Function, f.Filename, f.Lineno, want[i].Function, want[i].Filename, want[i].Lineno)
		}
	}
}

func TestHandlerGroupsAndBoundAttributes(t *testing.T) {
	tr, logger := setup(t)
	parent := logger.With("topic", "video.ready")
	child := parent.WithGroup("request").With("target", "private")
	child.Error("internal error", "route", "GET /private", "error", errors.New("secret"))
	parent.Error("grpc call failed", "target", "user-service")
	events := captured(t, tr)
	if len(events) != 2 {
		t.Fatalf("events = %d, want 2", len(events))
	}
	if events[0].Tags["topic"] != "video.ready" || events[0].Tags["target"] != "" || len(events[0].Exception) != 0 {
		t.Errorf("bound group handling: %s", eventJSON(t, events[0]))
	}
	if events[1].Tags["target"] != "user-service" {
		t.Error("child changed parent")
	}
}

func TestBeforeSendRedactsEveryNestedSurface(t *testing.T) {
	const email = "alice@example.com"
	const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"
	value := email + " " + jwt
	event := &sentry.Event{
		Message: value, Request: &sentry.Request{Data: "hunter2-Secret!", Headers: map[string]string{"Authorization": jwt}},
		User: sentry.User{ID: "user-1", Email: email, IPAddress: "127.0.0.1", Username: value},
		Tags: map[string]string{email: value}, Fingerprint: []string{value},
		Exception: []sentry.Exception{{Type: value, Value: value}},
		Contexts: map[string]sentry.Context{email: {"nested": []any{map[string]string{jwt: value}},
			"struct": struct{ Value string }{value}}},
		Breadcrumbs: []*sentry.Breadcrumb{{Message: value, Type: value, Category: value,
			Data: map[string]any{email: []string{value}}}},
	}
	event = beforeSend(event, nil)
	assertNoSecrets(t, event, email, jwt, "hunter2-Secret!", "Authorization", "127.0.0.1")
	if event.Request != nil || event.User.ID != "user-1" || event.User.Email != "" ||
		event.Message != "[redacted] [redacted]" {
		t.Fatalf("unexpected sanitization: %s", eventJSON(t, event))
	}
}

func TestRateLimitsConcurrentDuplicatesAndProcessBudget(t *testing.T) {
	tr, logger := setup(t)
	var warnings bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&warnings, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	var mu sync.Mutex
	var delays []time.Duration
	var flushes []func()
	active.Load().after = func(d time.Duration, f func()) {
		mu.Lock()
		defer mu.Unlock()
		delays, flushes = append(delays, d), append(flushes, f)
	}
	var wg sync.WaitGroup
	for range 1000 {
		wg.Go(func() { logger.Error("internal error") })
	}
	wg.Wait()
	if got := len(captured(t, tr)); got != 1 {
		t.Fatalf("duplicate events = %d, want 1", got)
	}
	for i := range 100 {
		logger.Error("internal error", "route", fmt.Sprintf("GET /route/%d", i))
	}
	if got := len(captured(t, tr)); got != 60 {
		t.Fatalf("total events = %d, want 60", got)
	}
	if bytes.Count(warnings.Bytes(), []byte("\n")) != 1 || !strings.Contains(warnings.String(), `"dropped":1}`) {
		t.Fatalf("unexpected drop warnings: %s", warnings.String())
	}
	// The other 998 duplicates and the 41 events over the process budget are reported a minute
	// after the first warning, by the one flush scheduled then.
	if len(flushes) != 1 || delays[0] <= 0 || delays[0] > time.Minute {
		t.Fatalf("scheduled flushes after %v, want one within a minute", delays)
	}
	flushes[0]()
	if bytes.Count(warnings.Bytes(), []byte("\n")) != 2 || !strings.Contains(warnings.String(), `"dropped":1039}`) {
		t.Fatalf("unexpected drop warnings after the flush: %s", warnings.String())
	}
}

// The drops after the first one of a burst are counted and reported together once the minute of
// the first report is over, even when no event comes after the burst; the next report starts a
// new minute.
func TestDropWarningCountsTheTailOfABurst(t *testing.T) {
	var l limiter
	now := time.Unix(100, 0)
	key := fingerprint{"service", "internal error", "", "string"}
	if allowed, _, _ := l.allow(now, key); !allowed {
		t.Fatal("first event denied")
	}
	if _, dropped, flushAt := l.allow(now, key); dropped != 1 || !flushAt.IsZero() {
		t.Fatalf("first drop reported %d with flush at %v, want 1 at once and no flush", dropped, flushAt)
	}
	if _, dropped, flushAt := l.allow(now.Add(time.Second), key); dropped != 0 || !flushAt.Equal(now.Add(time.Minute)) {
		t.Fatalf("second drop reported %d with flush at %v, want 0 and a flush at %v", dropped, flushAt, now.Add(time.Minute))
	}
	for range 997 {
		if _, dropped, flushAt := l.allow(now.Add(2*time.Second), key); dropped != 0 || !flushAt.IsZero() {
			t.Fatalf("later drop reported %d with flush at %v, want 0 and no new flush", dropped, flushAt)
		}
	}
	if got := l.flush(now.Add(time.Minute)); got != 998 {
		t.Fatalf("flush() = %d, want the 998 drops after the first", got)
	}
	if got := l.flush(now.Add(time.Minute)); got != 0 {
		t.Fatalf("second flush() = %d, want 0", got)
	}
	// The flush is the last report: a drop within a minute of it waits for the next flush.
	later := now.Add(time.Minute + time.Second)
	if allowed, _, _ := l.allow(later, key); !allowed {
		t.Fatal("event denied after its 30 s and the process minute")
	}
	if _, dropped, flushAt := l.allow(later, key); dropped != 0 || !flushAt.Equal(now.Add(2*time.Minute)) {
		t.Fatalf("drop after the flush reported %d with flush at %v, want 0 and a flush at %v", dropped, flushAt, now.Add(2*time.Minute))
	}
}

func TestRateLimitSlidingWindowsAndDropCounts(t *testing.T) {
	var l limiter
	now := time.Unix(100, 0)
	key := fingerprint{"service", "internal error", "", "string"}
	if allowed, _, _ := l.allow(now, key); !allowed {
		t.Fatal("first event denied")
	}
	if allowed, dropped, _ := l.allow(now, key); allowed || dropped != 1 {
		t.Fatal("duplicate did not report first drop")
	}
	if allowed, _, _ := l.allow(now.Add(30*time.Second-time.Nanosecond), key); allowed {
		t.Fatal("duplicate allowed too soon")
	}
	if allowed, _, _ := l.allow(now.Add(30*time.Second), key); !allowed {
		t.Fatal("duplicate not allowed after 30s")
	}
	for i := range 58 {
		k := key
		k.route = strconv.Itoa(i)
		if allowed, _, _ := l.allow(now.Add(30*time.Second), k); !allowed {
			t.Fatal("process budget exhausted early")
		}
	}
	other := key
	other.kind = "*pgconn.PgError"
	if allowed, _, _ := l.allow(now.Add(time.Minute-time.Nanosecond), other); allowed {
		t.Fatal("rolling process budget reset too soon")
	}
	if allowed, _, _ := l.allow(now.Add(time.Minute), other); !allowed {
		t.Fatal("process budget did not free oldest slot")
	}
	if allowed, dropped, _ := l.allow(now.Add(time.Minute), other); allowed || dropped != 3 {
		t.Fatalf("warning count = %d, want 3", dropped)
	}
}

func TestFingerprintIncludesServiceMessageRouteAndErrorType(t *testing.T) {
	var l limiter
	now := time.Unix(100, 0)
	for _, key := range []fingerprint{
		{"a", "internal error", "GET /a", "string"},
		{"b", "internal error", "GET /a", "string"},
		{"a", "grpc call failed", "GET /a", "string"},
		{"a", "internal error", "GET /b", "string"},
		{"a", "internal error", "GET /a", "*pgconn.PgError"},
	} {
		if allowed, _, _ := l.allow(now, key); !allowed {
			t.Errorf("distinct fingerprint denied: %+v", key)
		}
	}
}

func TestInitDisabledAndInvalidDSN(t *testing.T) {
	tr, logger := setup(t)
	t.Setenv("SENTRY_DSN", "")
	flush, err := Init("disabled")
	if err != nil {
		t.Fatal(err)
	}
	logger.Error("internal error")
	flush()
	if active.Load() != nil || len(tr.captured()) != 0 || logger.Enabled(context.Background(), slog.LevelError) {
		t.Fatal("empty DSN did not disable reporter")
	}
	t.Setenv("SENTRY_DSN", "not-a-dsn-hunter2-Secret!")
	if _, err := Init("invalid"); err == nil || !strings.Contains(err.Error(), "SENTRY_DSN") || strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("invalid DSN error = %v", err)
	}
}

func TestInitOptionsAndErrorLevels(t *testing.T) {
	tr, logger := setup(t)
	opts := tr.options
	if opts.DataCollection == nil || opts.DataCollection.UserInfo.Value || len(opts.DataCollection.HTTPBodies) != 0 ||
		!opts.AttachStacktrace || opts.EnableTracing || opts.BeforeSend == nil {
		t.Fatal("unexpected client options")
	}
	logger.Info("internal error")
	logger.Warn("internal error")
	logger.Log(context.Background(), slog.LevelError+1, "internal error")
	if len(captured(t, tr)) != 1 {
		t.Fatal("handler did not enforce ERROR threshold")
	}
}

// unavailableHTTP is a tracker that does not answer: a request waits until release is closed,
// then fails.
type unavailableHTTP struct {
	sent, release chan struct{}
	once          sync.Once
}

func (u *unavailableHTTP) RoundTrip(*http.Request) (*http.Response, error) {
	u.once.Do(func() { close(u.sent) })
	<-u.release
	return nil, errors.New("tracker unavailable")
}

// unavailableTransport is the SDK's asynchronous HTTP transport in front of unavailableHTTP. Its
// flush notes the deadline it was given, then lets the tracker fail the request it holds.
type unavailableTransport struct {
	*sentry.HTTPTransport
	http        *unavailableHTTP
	deadline    time.Time
	hasDeadline bool
	release     sync.Once
}

func (t *unavailableTransport) Configure(options sentry.ClientOptions) {
	options.HTTPTransport = t.http
	t.HTTPTransport.Configure(options)
}

func (t *unavailableTransport) FlushWithContext(ctx context.Context) bool {
	t.deadline, t.hasDeadline = ctx.Deadline()
	t.release.Do(func() { close(t.http.release) })
	return t.HTTPTransport.FlushWithContext(ctx)
}

func TestUnavailableTrackerDoesNotBlockAndFlushIsBounded(t *testing.T) {
	t.Setenv("SENTRY_DSN", "http://public@tracker.invalid/1")
	tr := &unavailableTransport{HTTPTransport: sentry.NewHTTPTransport(),
		http: &unavailableHTTP{sent: make(chan struct{}), release: make(chan struct{})}}
	flush, err := initClient("test", tr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(flush)
	// The tracker holds the event's request until the flush below: logging must return before.
	logged := make(chan struct{})
	go func() {
		slog.New(&Handler{}).Error("internal error")
		close(logged)
	}()
	for what, ch := range map[string]chan struct{}{"logging to return": logged, "the event to be sent": tr.http.sent} {
		select {
		case <-ch:
		case <-time.After(10 * time.Second):
			t.Fatalf("timed out waiting for %s while the tracker does not answer", what)
		}
	}
	before := time.Now()
	flush()
	after := time.Now()
	if !tr.hasDeadline || tr.deadline.Before(before.Add(2*time.Second)) || tr.deadline.After(after.Add(2*time.Second)) {
		t.Fatalf("flush deadline = %v (set %v), want two seconds after the flush started, within %v..%v",
			tr.deadline, tr.hasDeadline, before.Add(2*time.Second), after.Add(2*time.Second))
	}
}

// stalledTransport is a tracker that never finishes a flush: it notes the deadline it was given
// and gives up at once, as it would at that deadline.
type stalledTransport struct {
	transport
	deadline    time.Time
	hasDeadline bool
}

func (s *stalledTransport) FlushWithContext(ctx context.Context) bool {
	s.deadline, s.hasDeadline = ctx.Deadline()
	return false
}

func TestFlushStopsWaitingAfterTwoSeconds(t *testing.T) {
	t.Setenv("SENTRY_DSN", "http://public@tracker.invalid/1")
	tr := &stalledTransport{}
	flush, err := initClient("stalled", tr)
	if err != nil {
		t.Fatal(err)
	}
	before := time.Now()
	flush()
	after := time.Now()
	if !tr.hasDeadline || tr.deadline.Before(before.Add(2*time.Second)) || tr.deadline.After(after.Add(2*time.Second)) {
		t.Fatalf("flush deadline = %v (set %v), want two seconds after the flush started, within %v..%v",
			tr.deadline, tr.hasDeadline, before.Add(2*time.Second), after.Add(2*time.Second))
	}
}

func TestAllowedMessagesMatchErrorLogs(t *testing.T) {
	// The AST scan is the equivalent of grepping ERROR calls, including static
	// messages passed through the services' internal error helpers.
	belowError := []string{"LevelDebug", "LevelInfo", "LevelWarn"}
	found := make(map[string]bool)
	for _, root := range []string{"../../internal", "../../services", "../../tools"} {
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if err != nil {
				return err
			}
			ast.Inspect(file, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				selector, ok := call.Fun.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				index := -1
				switch selector.Sel.Name {
				case "Error":
					// Exclude status.Error(codes.X, message).
					if pkg, ok := selector.X.(*ast.Ident); !ok || pkg.Name != "status" {
						index = 0
					}
				case "ErrorContext":
					index = 1
				case "internal":
					// user-service's helper logs "internal error" and stores
					// this argument under op, which is not in the allowlist.
					if !strings.Contains(path, "user-service/") {
						index = 1
					}
				case "Log", "LogAttrs":
					// A level that is not a constant below ERROR, such as a variable, may be ERROR.
					if len(call.Args) > 2 {
						if level, ok := call.Args[1].(*ast.SelectorExpr); !ok || !slices.Contains(belowError, level.Sel.Name) {
							index = 2
						}
					}
				}
				if index >= 0 && len(call.Args) > index {
					if literal, ok := call.Args[index].(*ast.BasicLit); ok && literal.Kind == token.STRING {
						message, err := strconv.Unquote(literal.Value)
						if err != nil {
							t.Fatal(err)
						}
						found[message] = true
					}
				}
				return true
			})
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	actual := make([]string, 0, len(found))
	for message := range found {
		actual = append(actual, message)
	}
	slices.Sort(actual)
	if !slices.Equal(actual, allowedMessages) {
		t.Fatalf("ERROR message inventory changed:\ngot  %q\nwant %q", actual, allowedMessages)
	}
}
