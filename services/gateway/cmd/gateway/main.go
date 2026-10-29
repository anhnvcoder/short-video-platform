// Command gateway runs the REST gateway (serve, the default) or checks a running instance's
// health (healthcheck). Configuration comes from environment variables only, so the same image
// runs in compose, in Kubernetes (k3d) and in the cloud with just the variables changed.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	feedv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/feed/v1"
	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/redisx"
	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
	"github.com/anhnvcoder/short-video-platform/internal/telemetry"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/api"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/breaker"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/ratelimit"
)

const (
	serviceName             = "gateway"
	defaultListenAddr       = "127.0.0.1:8080"
	defaultUserServiceAddr  = "127.0.0.1:9101"
	defaultVideoServiceAddr = "127.0.0.1:9102"
	defaultEngagementAddr   = "127.0.0.1:9103"
	defaultFeedServiceAddr  = "127.0.0.1:9104"
	// defaultRedisURL is the gateway's Redis db (CLAUDE.md); it holds the rate limits.
	defaultRedisURL = "redis://127.0.0.1:6379/10"
	// redisKeyPrefix starts every key the gateway writes, so its keys are told apart from other
	// services' and an ACL by prefix can be added on the cloud.
	redisKeyPrefix = "svp:gw:"
	// shutdownTimeout bounds the wait for in-flight requests after SIGINT or SIGTERM.
	shutdownTimeout = 10 * time.Second
	// healthcheckTimeout bounds the healthcheck subcommand, which a container runtime calls often.
	healthcheckTimeout = 3 * time.Second
)

// backend is a gRPC service the gateway calls.
type backend struct {
	// name names the service's circuit breaker in the log.
	name          string
	addrVar, addr string
	// retry are the full names of the idempotent methods retried on UNAVAILABLE; no other method
	// is retried, as a second try would repeat its effect (a new video from InitUpload, one more
	// view from RecordView) or cost a password hash again.
	retry []string
	// ignoreDeadline are the methods whose DEADLINE_EXCEEDED the breaker does not count.
	ignoreDeadline []string
}

var (
	userBackend = backend{
		name: "user-service", addrVar: "USER_SERVICE_ADDR", addr: defaultUserServiceAddr,
		// Logout revokes a family that stays revoked, so a second try changes nothing; Refresh is
		// not retried: a second try reuses the token and revokes its whole family.
		// UpdateDisplayName sets a value, so setting it twice is setting it once. GetProfiles is
		// not retried: it adds authors within a 100 ms budget that holds no second try.
		retry: []string{
			userv1.UserService_Follow_FullMethodName, userv1.UserService_Unfollow_FullMethodName,
			userv1.UserService_Logout_FullMethodName,
			userv1.UserService_GetProfileByHandle_FullMethodName, userv1.UserService_UpdateDisplayName_FullMethodName,
		},
		// A slow but live user-service must not open the breaker through the authors' 100 ms
		// budget and fail every login and follow.
		ignoreDeadline: []string{userv1.UserService_GetProfiles_FullMethodName},
	}
	videoBackend = backend{
		name: "video-service", addrVar: "VIDEO_SERVICE_ADDR", addr: defaultVideoServiceAddr,
		retry: []string{
			videov1.VideoService_GetVideo_FullMethodName, videov1.VideoService_CompleteUpload_FullMethodName,
			videov1.VideoService_GetPublicVideo_FullMethodName, videov1.VideoService_ListAuthorVideos_FullMethodName,
		},
	}
	feedBackend = backend{
		name: "feed-service", addrVar: "FEED_SERVICE_ADDR", addr: defaultFeedServiceAddr,
		retry: []string{feedv1.FeedService_GetFollowingFeed_FullMethodName, feedv1.FeedService_GetExploreFeed_FullMethodName},
	}
	engagementBackend = backend{
		name: "engagement-service", addrVar: "ENGAGEMENT_SERVICE_ADDR", addr: defaultEngagementAddr,
		retry: []string{engagementv1.EngagementService_Like_FullMethodName, engagementv1.EngagementService_Unlike_FullMethodName},
		// GetStats has a 100 ms budget: a slow but live engagement-service must not open the
		// breaker and fail every like and view.
		ignoreDeadline: []string{engagementv1.EngagementService_GetStats_FullMethodName},
	}
)

// serviceConfig returns b's service config, as JSON: a retry policy for the methods in b.retry.
// Every attempt runs within the call's one deadline. The retry throttling makes retries stop after
// a few failed calls to a service that is down, instead of tripling the load on it.
func (b backend) serviceConfig() string {
	type name struct {
		Service string `json:"service"`
		Method  string `json:"method"`
	}
	type retryPolicy struct {
		MaxAttempts          int      `json:"maxAttempts"`
		InitialBackoff       string   `json:"initialBackoff"`
		MaxBackoff           string   `json:"maxBackoff"`
		BackoffMultiplier    float64  `json:"backoffMultiplier"`
		RetryableStatusCodes []string `json:"retryableStatusCodes"`
	}
	type methodConfig struct {
		Name        []name      `json:"name"`
		RetryPolicy retryPolicy `json:"retryPolicy"`
	}
	type retryThrottling struct {
		MaxTokens  int     `json:"maxTokens"`
		TokenRatio float64 `json:"tokenRatio"`
	}
	type config struct {
		MethodConfig    []methodConfig  `json:"methodConfig"`
		RetryThrottling retryThrottling `json:"retryThrottling"`
	}

	names := make([]name, len(b.retry))
	for i, m := range b.retry {
		names[i].Service, names[i].Method, _ = strings.Cut(strings.TrimPrefix(m, "/"), "/")
	}
	cfg, err := json.Marshal(config{
		MethodConfig: []methodConfig{{
			Name: names,
			RetryPolicy: retryPolicy{
				MaxAttempts:          3,
				InitialBackoff:       "0.05s",
				MaxBackoff:           "0.2s",
				BackoffMultiplier:    2,
				RetryableStatusCodes: []string{"UNAVAILABLE"},
			},
		}},
		RetryThrottling: retryThrottling{MaxTokens: 10, TokenRatio: 0.1},
	})
	if err != nil {
		// A struct of strings and numbers always marshals.
		panic(err)
	}
	return string(cfg)
}

// dialOptions are the options of every connection to b: plain text until mTLS arrives in stage
// 6, client spans and metrics, b's own circuit breaker, and b's service config. A service config
// from the resolver (a DNS TXT record) is ignored, so the retry policy is always this one.
func (b backend) dialOptions() []grpc.DialOption {
	return []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		httpx.ClientTelemetry(),
		grpc.WithUnaryInterceptor(breaker.New(b.name, b.ignoreDeadline...)),
		grpc.WithDisableServiceConfig(),
		grpc.WithDefaultServiceConfig(b.serviceConfig()),
	}
}

func main() {
	logger := logx.New(serviceName)
	// httpx logs through the default logger.
	slog.SetDefault(logger)

	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, logger, cmd); err != nil {
		stop()
		os.Exit(1)
	}
}

// run runs the subcommand cmd and logs its error. Error reporting, telemetry and profiling start
// for serve only, never for healthcheck, which a container runtime runs every few seconds and
// which would otherwise add thousands of metric instances and probe error events a day. They
// stop after the error is logged, so a failure that stops the gateway still reaches the error
// tracker and the log pipeline. On shutdown the HTTP server stops first (in serve), then the
// connections, then telemetry is flushed, and the error tracker last.
func run(ctx context.Context, logger *slog.Logger, cmd string) error {
	var err error
	stopTelemetry := func() {}
	switch cmd {
	case "serve":
		stopTelemetry, err = startTelemetry(ctx, logger)
		if err == nil {
			err = serve(ctx, logger)
		}
	case "healthcheck":
		err = healthcheck(ctx)
	default:
		err = fmt.Errorf("unknown subcommand %q, want serve or healthcheck", cmd)
	}
	if err != nil {
		// A constant message, so the error tracker groups it.
		logger.Error("gateway failed", slog.Any("error", err))
	}
	stopTelemetry()
	return err
}

// startTelemetry starts error reporting, then the OTel providers and the profiler. The returned
// stop shuts the providers down, then flushes the error tracker. It is never nil: when the
// providers fail to start, it flushes the error tracker, which reports that failure.
func startTelemetry(ctx context.Context, logger *slog.Logger) (stop func(), err error) {
	flushErrors, err := sentryx.Init(serviceName)
	if err != nil {
		return func() {}, err
	}
	shutdownTelemetry, err := telemetry.Setup(ctx, serviceName)
	if err != nil {
		return flushErrors, fmt.Errorf("telemetry: %w", err)
	}
	return func() {
		// Setup bounds the shutdown itself; ctx is already cancelled by then.
		if err := shutdownTelemetry(context.WithoutCancel(ctx)); err != nil {
			logger.Warn("telemetry shutdown failed", slog.Any("error", err))
		}
		flushErrors()
	}, nil
}

// serve runs the gateway until ctx is done. Deferred calls run in reverse order, so on shutdown
// the HTTP server stops first, then the connections.
func serve(ctx context.Context, logger *slog.Logger) error {
	addr := envcfg.String("LISTEN_ADDR", defaultListenAddr)
	verifyKeys, err := envcfg.Required("JWT_VERIFY_KEYS")
	if err != nil {
		return err
	}
	keys, err := authtoken.ParseVerifyKeys(verifyKeys)
	if err != nil {
		return fmt.Errorf("JWT_VERIFY_KEYS: %w", err)
	}

	mediaBase, err := envcfg.Required("MEDIA_PUBLIC_BASE_URL")
	if err != nil {
		return err
	}
	mediaBase, err = parseMediaBaseURL(mediaBase)
	if err != nil {
		return fmt.Errorf("MEDIA_PUBLIC_BASE_URL: %w", err)
	}
	clientAddr, err := trustedProxies()
	if err != nil {
		return err
	}
	trustTrace, err := trustTraceContext()
	if err != nil {
		return err
	}

	// Like engagement-service's below, this connection is opened at start and never left idle:
	// GetProfiles adds the authors of every feed page within 100 ms.
	userConn, err := dial(userBackend, grpc.WithIdleTimeout(0))
	if err != nil {
		return err
	}
	defer func() { _ = userConn.Close() }()
	userConn.Connect()
	videoConn, err := dial(videoBackend)
	if err != nil {
		return err
	}
	defer func() { _ = videoConn.Close() }()
	feedConn, err := dial(feedBackend)
	if err != nil {
		return err
	}
	defer func() { _ = feedConn.Close() }()
	// A GetStats call that first has to set up DNS, TCP and HTTP/2 may miss its 100 ms budget, so
	// this connection is opened at start and kept open. Connect does not wait: the gateway starts
	// even when engagement-service is not up yet, and the connection keeps retrying in the
	// background. An idle timeout of 0 stops grpc-go from closing it after 30 minutes without
	// calls. When an open connection breaks (engagement-service restarts), grpc-go reconnects on
	// the next call, so that one feed page may come back without stats.
	engagementConn, err := dial(engagementBackend, grpc.WithIdleTimeout(0))
	if err != nil {
		return err
	}
	defer func() { _ = engagementConn.Close() }()
	engagementConn.Connect()

	// The client does not connect until the first command, so the gateway starts while Redis is
	// down; rate limits then use their fallback.
	redisClient, err := redisx.New(envcfg.String("REDIS_URL", defaultRedisURL))
	if err != nil {
		return fmt.Errorf("REDIS_URL: %w", err)
	}
	defer func() { _ = redisClient.Close() }()
	limits := ratelimit.New(redisClient, redisKeyPrefix)

	var lc net.ListenConfig
	lis, err := lc.Listen(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", addr, err)
	}
	// The spans and metrics name the gateway by its service name and the port it listens on, a
	// number even when LISTEN_ADDR names the port.
	serverName := net.JoinHostPort(serviceName, strconv.Itoa(lis.Addr().(*net.TCPAddr).Port))
	handler := api.New(userConn, videoConn, feedConn, engagementConn, authtoken.NewVerifier(keys), mediaBase, limits, clientAddr, serverName)
	if trustTrace {
		handler = httpx.TrustTraceContext(handler)
	}
	srv := httpx.NewServer(addr, handler)
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(lis) }()
	logger.InfoContext(ctx, "http server listening", slog.String("addr", lis.Addr().String()))

	select {
	case err := <-errCh:
		return fmt.Errorf("serve http: %w", err)
	case <-ctx.Done():
	}

	logger.Info("http server stopping")
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown http: %w", err)
	}
	if err := <-errCh; !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve http: %w", err)
	}
	logger.Info("http server stopped")
	return nil
}

// parseMediaBaseURL checks that s is an absolute http or https URL and returns it without a
// trailing slash. Object keys are appended to it, so a query or fragment would break every URL
// and userinfo would put a credential into every public URL. The error never carries the value.
func parseMediaBaseURL(s string) (string, error) {
	u, err := url.Parse(s)
	if err != nil {
		return "", errors.New("not a valid URL")
	}
	if (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", errors.New("want an absolute http or https URL")
	}
	// "?" and "#" cannot appear in the host, and an empty query or fragment leaves no trace in u.
	if strings.ContainsAny(s, "?#") || u.User != nil {
		return "", errors.New("want a URL without query, fragment or userinfo")
	}
	return strings.TrimRight(s, "/"), nil
}

// trustedProxies reads TRUSTED_PROXY_HOPS and TRUSTED_PROXY_CIDRS into the ClientAddr that finds
// each request's client address (see httpx.ClientAddr). HOPS is the number of proxies of ours in
// front of the gateway, CIDRS the comma-separated ranges they connect from; X-Forwarded-For is
// read only on connections from those ranges, and only its HOPS-th element from the right.
//
// HOPS defaults to 0, the connection's address: with no proxy in front (compose) every
// X-Forwarded-For comes from the client, so trusting one hop there would let a client pick its
// rate-limit bucket on every request. A wrong count fails silently at run time (one bucket for
// everyone, or spoofed IPs, threat model RL-1), so every setting that cannot be right stops the
// gateway instead: HOPS not a whole number >= 0, a range that does not parse, HOPS > 0 with no
// range (no proxy would ever be trusted), or ranges with HOPS 0 (ranges that do nothing hide a
// missing HOPS). The errors name the variable and never carry its value.
func trustedProxies() (httpx.ClientAddr, error) {
	hops, err := strconv.Atoi(envcfg.String("TRUSTED_PROXY_HOPS", "0"))
	if err != nil || hops < 0 {
		return httpx.ClientAddr{}, errors.New("TRUSTED_PROXY_HOPS: want a whole number >= 0")
	}
	var trusted []netip.Prefix
	if cidrs := envcfg.String("TRUSTED_PROXY_CIDRS", ""); cidrs != "" {
		for i, c := range strings.Split(cidrs, ",") {
			p, err := netip.ParsePrefix(strings.TrimSpace(c))
			if err != nil {
				return httpx.ClientAddr{}, fmt.Errorf("TRUSTED_PROXY_CIDRS: element %d is not a CIDR like 10.42.0.0/16", i+1)
			}
			// Of unmaps the connection's address (::ffff:10.42.0.7 becomes 10.42.0.7) before it asks
			// Contains, and an IPv6 prefix never contains an IPv4 address, so a range written in the
			// mapped form would parse and never match. Store it as the IPv4 range it means; a
			// mapped prefix shorter than 96 bits reaches beyond IPv4 and has no such form.
			if p.Addr().Is4In6() {
				if p.Bits() < 96 {
					return httpx.ClientAddr{}, fmt.Errorf("TRUSTED_PROXY_CIDRS: element %d is an IPv4-mapped range shorter than /96", i+1)
				}
				p = netip.PrefixFrom(p.Addr().Unmap(), p.Bits()-96)
			}
			trusted = append(trusted, p.Masked())
		}
	}
	switch {
	case hops > 0 && len(trusted) == 0:
		return httpx.ClientAddr{}, errors.New("TRUSTED_PROXY_HOPS is above 0 but TRUSTED_PROXY_CIDRS is not set")
	case hops == 0 && len(trusted) > 0:
		return httpx.ClientAddr{}, errors.New("TRUSTED_PROXY_CIDRS is set but TRUSTED_PROXY_HOPS is 0")
	}
	return httpx.NewClientAddr(hops, trusted), nil
}

// trustTraceContext reads TRUST_TRACE_CONTEXT: "true" makes the gateway's HTTP spans children of
// the traceparent and tracestate of each request (httpx.TrustTraceContext), "false" or unset keeps
// every request a new root trace. Turn it on only where every path into the gateway has already
// removed the client's trace context (Envoy in k3d strips it on every route, and a NetworkPolicy
// lets only Envoy and the web pods reach the gateway) or where the gateway listens on loopback and
// its private network only (compose). Anywhere else a client could pick the trace id of its own
// requests and attach its spans to other traces. Any other value stops the gateway, so a typo
// never leaves the setting silently off or on; the error names the variable and never carries
// its value.
func trustTraceContext() (bool, error) {
	switch envcfg.String("TRUST_TRACE_CONTEXT", "false") {
	case "true":
		return true, nil
	case "false":
		return false, nil
	default:
		return false, errors.New("TRUST_TRACE_CONTEXT: want true or false")
	}
}

// dial returns a client connection to b at the gRPC address in its variable, with b's dial
// options and opts. The connection connects lazily on the first call.
func dial(b backend, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	conn, err := grpc.NewClient(envcfg.String(b.addrVar, b.addr), append(b.dialOptions(), opts...)...)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", b.addrVar, err)
	}
	return conn, nil
}

// healthcheck asks the gateway on LISTEN_ADDR's port, over loopback, for /healthz and succeeds
// only on 200.
func healthcheck(ctx context.Context) error {
	_, port, err := net.SplitHostPort(envcfg.String("LISTEN_ADDR", defaultListenAddr))
	if err != nil {
		return fmt.Errorf("LISTEN_ADDR: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, healthcheckTimeout)
	defer cancel()
	url := "http://" + net.JoinHostPort("127.0.0.1", port) + "/healthz"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("get %s: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("get %s: status %d", url, resp.StatusCode)
	}
	return nil
}
