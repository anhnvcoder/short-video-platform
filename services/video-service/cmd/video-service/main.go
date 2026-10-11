// Command video-service serves svp.video.v1.VideoService over gRPC.
//
// Subcommands (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 7):
//
//	serve        run the service (default when no subcommand is given)
//	migrate      apply the database migrations, then exit
//	healthcheck  ask the running service for its health; exit 0 when SERVING, 1 otherwise
//
// Configuration comes from the environment: LISTEN_ADDR (default 127.0.0.1:9102) and
// DATABASE_URL (required for serve and migrate).
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"

	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/dbmigrate"
	"github.com/anhnvcoder/short-video-platform/internal/envcfg"
	"github.com/anhnvcoder/short-video-platform/internal/grpcserver"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/services/video-service/internal/server"
	"github.com/anhnvcoder/short-video-platform/services/video-service/migrations"
)

const (
	serviceName        = "video-service"
	defaultListenAddr  = "127.0.0.1:9102"
	healthcheckTimeout = 3 * time.Second
)

func main() {
	logger := logx.New(serviceName)
	// dbmigrate logs through the default logger.
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, logger, os.Args[1:])
	stop()
	if err != nil {
		logger.Error("video-service failed", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(ctx context.Context, logger *slog.Logger, args []string) error {
	cmd := "serve"
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "serve":
		return serve(ctx, logger)
	case "migrate":
		return migrate(ctx)
	case "healthcheck":
		return healthcheck(ctx)
	}
	return fmt.Errorf("unknown command %q, want serve, migrate or healthcheck", cmd)
}

func serve(ctx context.Context, logger *slog.Logger) error {
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return fmt.Errorf("open database pool: %w", err)
	}
	defer pool.Close()
	// pgxpool connects lazily: check the database now so a bad URL fails at startup.
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}

	srv := server.New(pool, logger)
	register := func(s *grpc.Server) { videov1.RegisterVideoServiceServer(s, srv) }
	return grpcserver.Run(ctx, envcfg.String("LISTEN_ADDR", defaultListenAddr), logger, register,
		server.CallerInterceptor())
}

func migrate(ctx context.Context) error {
	databaseURL, err := envcfg.Required("DATABASE_URL")
	if err != nil {
		return err
	}
	return dbmigrate.Up(ctx, databaseURL, migrations.FS)
}

func healthcheck(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, healthcheckTimeout)
	defer cancel()
	return grpcserver.Healthcheck(ctx, envcfg.String("LISTEN_ADDR", defaultListenAddr))
}
