package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kuurier/server/internal/api"
	"github.com/kuurier/server/internal/bot"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/logger"
	"github.com/kuurier/server/internal/migrations"
	"github.com/kuurier/server/internal/storage"
)

// Build-time variables populated via -ldflags="-X main.Version=... -X main.GitSHA=... -X main.BuildDate=..."
var (
	Version   = "dev"
	GitSHA    = "unknown"
	BuildDate = "unknown"
)

// BuildInfo exposes the build-time identity so deploy scripts can verify
// the running binary matches what was just pushed.
func BuildInfo() (version, sha, buildDate string) {
	return Version, GitSHA, BuildDate
}

func main() {
	// --migrate-only: run migrations and exit. Useful for CI and for
	// out-of-band schema updates that shouldn't also restart the API.
	migrateOnly := flag.Bool("migrate-only", false, "run database migrations and exit")
	flag.Parse()

	// Load configuration
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	log.Printf("Kuurier server starting — version=%s sha=%s built_at=%s", Version, GitSHA, BuildDate)

	// Initialize structured logging (JSON in production, text in dev)
	logger.Init(cfg.Environment)

	// Initialize database connection with configured pool settings
	db, err := storage.NewPostgres(cfg)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	// Apply any pending migrations before anything else touches the DB.
	// Uses a postgres advisory lock so blue+green racing on deploy resolves
	// safely — only one runs migrations, the other waits then continues.
	migrateCtx, migrateCancel := context.WithTimeout(context.Background(), 2*time.Minute)
	if err := migrations.Run(migrateCtx, db.Pool()); err != nil {
		migrateCancel()
		log.Fatalf("Failed to apply migrations: %v", err)
	}
	migrateCancel()

	if *migrateOnly {
		log.Println("--migrate-only set, exiting after successful migration run")
		return
	}

	// Initialize Redis connection
	redis, err := storage.NewRedis(cfg.RedisURL)
	if err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}
	defer redis.Close()

	// Initialize MinIO (object storage)
	minio, err := storage.NewMinIO(cfg.MinIOEndpoint, cfg.MinIOAccessKey, cfg.MinIOSecretKey, cfg.MinIOBucket, cfg.MinIOUseSSL)
	if err != nil {
		log.Printf("Warning: Failed to connect to MinIO: %v (media uploads disabled)", err)
		minio = nil
	}

	// Initialize APNs (push notifications)
	apnsCfg := storage.APNsConfig{
		KeyPath:    cfg.APNsKeyPath,
		KeyID:      cfg.APNsKeyID,
		TeamID:     cfg.APNsTeamID,
		BundleID:   cfg.APNsBundleID,
		Production: cfg.APNsProduction,
	}
	apns, err := storage.NewAPNs(apnsCfg)
	if err != nil {
		log.Printf("Warning: Failed to initialize APNs: %v (push notifications disabled)", err)
		apns = nil
	}

	// Create router and WebSocket hub
	router, wsHub := api.NewRouter(cfg, db, redis, minio, apns, api.BuildInfo{
		Version:   Version,
		SHA:       GitSHA,
		BuildDate: BuildDate,
	})

	// Start WebSocket hub
	go wsHub.Run()
	defer wsHub.Stop()

	// Start news aggregation bot (posts twice daily at 8 AM and 6 PM UTC)
	newsBot := bot.NewNewsBot(db)
	api.SetNewsBot(newsBot)
	newsBot.Start()
	defer newsBot.Stop()

	// Start protest scraper bot (scrapes findaprotest.info twice daily at 7 AM and 5 PM UTC)
	protestBot := bot.NewProtestBot(db)
	api.SetProtestBot(protestBot)
	protestBot.Start()
	defer protestBot.Stop()

	// Create server
	srv := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      router,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start server in goroutine
	go func() {
		log.Printf("Kuurier server starting on port %s (WebSocket enabled)", cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited")
}
