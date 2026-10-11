// Command gateway runs the REST gateway (serve, the default) or checks a running instance's
// health (healthcheck). Configuration comes from environment variables
// (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 4).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/api"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
)

const (
	serviceName             = "gateway"
	defaultListenAddr       = "127.0.0.1:8080"
	defaultUserServiceAddr  = "127.0.0.1:9101"
	defaultVideoServiceAddr = "127.0.0.1:9102"
	defaultEngagementAddr   = "127.0.0.1:9103"
	defaultFeedServiceAddr  = "127.0.0.1:9104"
	// shutdownTimeout bounds the wait for in-flight requests after SIGINT or SIGTERM.
	shutdownTimeout = 10 * time.Second
	// healthcheckTimeout bounds the healthcheck subcommand, which a container runtime calls often.
	healthcheckTimeout = 3 * time.Second
)

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

	var err error
	switch cmd {
	case "serve":
		err = serve(ctx, logger)
	case "healthcheck":
		err = healthcheck(ctx)
	default:
		err = fmt.Errorf("unknown subcommand %q, want serve or healthcheck", cmd)
	}
	if err != nil {
		logger.Error(cmd+" failed", slog.Any("error", err))
		stop()
		os.Exit(1)
	}
}

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

	userConn, err := dial("USER_SERVICE_ADDR", defaultUserServiceAddr)
	if err != nil {
		return err
	}
	defer func() { _ = userConn.Close() }()
	videoConn, err := dial("VIDEO_SERVICE_ADDR", defaultVideoServiceAddr)
	if err != nil {
		return err
	}
	defer func() { _ = videoConn.Close() }()
	feedConn, err := dial("FEED_SERVICE_ADDR", defaultFeedServiceAddr)
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
	engagementConn, err := dial("ENGAGEMENT_SERVICE_ADDR", defaultEngagementAddr, grpc.WithIdleTimeout(0))
	if err != nil {
		return err
	}
	defer func() { _ = engagementConn.Close() }()
	engagementConn.Connect()

	srv := httpx.NewServer(addr, api.New(userConn, videoConn, feedConn, engagementConn, authtoken.NewVerifier(keys), mediaBase))
	var lc net.ListenConfig
	lis, err := lc.Listen(ctx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", addr, err)
	}
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

// dial returns a client connection to the gRPC address in the variable name, with opts added.
// The connection is plain text until mTLS arrives in stage 6, and connects lazily on the first
// call.
func dial(name, def string, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	opts = append([]grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}, opts...)
	conn, err := grpc.NewClient(envcfg.String(name, def), opts...)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
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
