// kuurier-worker runs the scheduled background jobs that used to live
// in the API process: news aggregation, protest scraping, and any
// future batch work (feed materialization, etc).
//
// It shares the same codebase and image as kuurier-server; the
// Dockerfile produces both binaries and docker-compose picks which
// one to run via `command:`.
//
// Responsibilities:
//   - Connect to DB + Redis.
//   - Run any pending embedded migrations (same code as the API, so
//     either binary can bootstrap a fresh DB — whichever wins the
//     advisory lock race does the work).
//   - Start NewsBot and ProtestBot schedulers.
//   - Consume Redis-backed admin triggers.
//   - Emit a heartbeat key every 30 seconds so the API can surface
//     worker liveness.
//
// There is no HTTP server here; no gin, no WebSocket hub.
package main

import (
	"context"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/kuurier/server/internal/bot"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/feed"
	"github.com/kuurier/server/internal/logger"
	"github.com/kuurier/server/internal/metrics"
	"github.com/kuurier/server/internal/migrations"
	"github.com/kuurier/server/internal/storage"
)

// Build-time identity, injected via ldflags.
var (
	Version   = "dev"
	GitSHA    = "unknown"
	BuildDate = "unknown"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}
	log.Printf("Kuurier worker starting — version=%s sha=%s built_at=%s", Version, GitSHA, BuildDate)

	logger.Init(cfg.Environment)

	db, err := storage.NewPostgres(cfg)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	// Apply migrations. Either the API or the worker may win the race
	// on a fresh DB; the advisory lock serializes them.
	migrateCtx, migrateCancel := context.WithTimeout(context.Background(), 2*time.Minute)
	if err := migrations.Run(migrateCtx, db.Pool()); err != nil {
		migrateCancel()
		log.Fatalf("Failed to apply migrations: %v", err)
	}
	migrateCancel()

	redis, err := storage.NewRedis(cfg.RedisURL)
	if err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}
	defer redis.Close()

	// Wire up root context, cancelled on SIGINT/SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Start schedulers.
	newsBot := bot.NewNewsBot(db)
	newsBot.Start()
	defer newsBot.Stop()

	protestBot := bot.NewProtestBot(db)
	protestBot.Start()
	defer protestBot.Stop()

	// Prometheus metrics on :9090 (/metrics). Scraped from inside
	// the docker network; not externally exposed.
	metricsSrv := &http.Server{
		Addr:              ":9090",
		Handler:           metricsMux(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		log.Println("Worker metrics server starting on :9090 (/metrics)")
		if err := metricsSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("metrics server error: %v", err)
		}
	}()
	defer metricsSrv.Shutdown(context.Background())

	// Heartbeat loop: write every 30s so the API can check worker health.
	go runHeartbeat(ctx, redis)

	// Feed materialization: precompute ranked feeds for active users.
	// Runs every 5 minutes in a loop, with a panic-recovering wrapper
	// similar to the bot scheduler.
	materializer := feed.NewMaterializer(cfg, db, redis)
	go runMaterializer(ctx, materializer)

	// Consume Redis-backed admin triggers and dispatch to the right bot.
	go bot.RunTriggerConsumer(ctx, redis, func(queue string) {
		triggerCtx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		switch queue {
		case bot.TriggerQueueNews:
			_ = newsBot.RunOnce(triggerCtx)
		case bot.TriggerQueueProtest:
			_ = protestBot.RunOnce(triggerCtx)
		}
	})

	log.Println("Worker ready")
	<-ctx.Done()
	log.Println("Worker shutting down")
}

func metricsMux() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/metrics", metrics.Handler())
	return mux
}

func runMaterializer(ctx context.Context, m *feed.Materializer) {
	// Run immediately so the first feeds are fresh for blue/green warm-up,
	// then on a ticker. Wrap each call so a panic in scoring doesn't
	// take the worker down.
	runOnce := func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("feed materializer panic recovered: %v", r)
			}
		}()
		runCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
		defer cancel()
		if err := m.RunOnce(runCtx); err != nil {
			log.Printf("feed materializer error: %v", err)
		}
	}

	runOnce()
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runOnce()
		}
	}
}

func runHeartbeat(ctx context.Context, redis *storage.Redis) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	// Write immediately so status is accurate from the first moment.
	writeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	_ = bot.RecordHeartbeat(writeCtx, redis)
	cancel()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			writeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			if err := bot.RecordHeartbeat(writeCtx, redis); err != nil {
				log.Printf("heartbeat write failed: %v", err)
			}
			cancel()
		}
	}
}
