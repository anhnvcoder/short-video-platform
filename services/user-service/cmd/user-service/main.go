// Command user-service runs the user service (serve, the default), applies its database
// migrations (migrate) or checks a running instance's health (healthcheck). Configuration comes
// from environment variables (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 4).
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/grpcserver"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/password"
	"github.com/anhnvcoder/short-video-platform/services/user-service/internal/server"
	"github.com/anhnvcoder/short-video-platform/services/user-service/migrations"
)

const (
	serviceName       = "user-service"
	defaultListenAddr = "127.0.0.1:9101"
	// healthcheckTimeout bounds the healthcheck subcommand, which a container runtime calls often.
	healthcheckTimeout = 3 * time.Second
)

func main() {
	logger := logx.New(serviceName)
	// dbmigrate logs through the default logger.
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
	case "migrate":
		err = migrate(ctx)
	case "healthcheck":
		err = healthcheck(ctx)
	default:
		err = fmt.Errorf("unknown subcommand %q, want serve, migrate or healthcheck", cmd)
	}
	if err != nil {
		logger.Error(cmd+" failed", slog.Any("error", err))
		stop()
		os.Exit(1)
	}
}

func serve(ctx context.Context, logger *slog.Logger) error {
	addr := envcfg.String("LISTEN_ADDR", defaultListenAddr)
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	kid, err := envcfg.Required("JWT_SIGNING_KID")
	if err != nil {
		return err
	}
	seed, err := envcfg.Required("JWT_SIGNING_KEY")
	if err != nil {
		return err
	}
	key, err := authtoken.ParseSigningKey(kid, seed)
	if err != nil {
		return fmt.Errorf("JWT_SIGNING_KID or JWT_SIGNING_KEY: %w", err)
	}

	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return fmt.Errorf("DATABASE_URL: %w", err)
	}
	defer pool.Close()
	// pgxpool connects lazily; fail at startup instead of on the first request.
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}

	srv := server.New(pool, password.NewHasher(), authtoken.NewIssuer(kid, key), logger)
	return grpcserver.Run(ctx, addr, logger,
		func(s *grpc.Server) { userv1.RegisterUserServiceServer(s, srv) },
		callerid.UnaryServerInterceptor(server.PublicMethods...),
	)
}

func migrate(ctx context.Context) error {
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	return dbmigrate.Up(ctx, databaseURL, migrations.FS)
}

// healthcheck asks the server on LISTEN_ADDR's port, over loopback, whether it is SERVING.
func healthcheck(ctx context.Context) error {
	_, port, err := net.SplitHostPort(envcfg.String("LISTEN_ADDR", defaultListenAddr))
	if err != nil {
		return fmt.Errorf("LISTEN_ADDR: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, healthcheckTimeout)
	defer cancel()
	return grpcserver.Healthcheck(ctx, net.JoinHostPort("127.0.0.1", port))
}
