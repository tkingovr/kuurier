package storage

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/kuurier/server/internal/config"
)

// Postgres wraps a PostgreSQL connection pool
type Postgres struct {
	pool *pgxpool.Pool
	cfg  *config.Config
}

// NewPostgres creates a new PostgreSQL connection pool with configurable settings
func NewPostgres(cfg *config.Config) (*Postgres, error) {
	poolConfig, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse database URL: %w", err)
	}

	// Connection pool settings from config
	poolConfig.MaxConns = cfg.DBMaxConns
	poolConfig.MinConns = cfg.DBMinConns
	poolConfig.MaxConnLifetime = time.Duration(cfg.DBMaxConnLifetime) * time.Minute
	poolConfig.MaxConnIdleTime = time.Duration(cfg.DBMaxConnIdleTime) * time.Minute
	poolConfig.HealthCheckPeriod = time.Duration(cfg.DBHealthCheckPeriod) * time.Second

	// Connection acquire timeout - prevents requests from waiting indefinitely
	// when pool is exhausted
	poolConfig.ConnConfig.ConnectTimeout = time.Duration(cfg.DBConnectTimeout) * time.Second

	// Log pool configuration in development
	if cfg.Environment != "production" {
		log.Printf("Database pool config: MaxConns=%d, MinConns=%d, MaxLifetime=%dm, MaxIdleTime=%dm, AcquireTimeout=%ds",
			poolConfig.MaxConns,
			poolConfig.MinConns,
			cfg.DBMaxConnLifetime,
			cfg.DBMaxConnIdleTime,
			cfg.DBAcquireTimeout,
		)
	}

	// Connect with timeout
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.DBConnectTimeout)*time.Second)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create connection pool: %w", err)
	}

	// Verify connection
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}

	log.Printf("Connected to PostgreSQL (pool: %d-%d connections)", cfg.DBMinConns, cfg.DBMaxConns)

	return &Postgres{pool: pool, cfg: cfg}, nil
}

// Pool returns the underlying connection pool
func (p *Postgres) Pool() *pgxpool.Pool {
	return p.pool
}

// Close closes the connection pool
func (p *Postgres) Close() {
	p.pool.Close()
	log.Println("PostgreSQL connection pool closed")
}

// HealthCheck verifies the database connection is alive
func (p *Postgres) HealthCheck(ctx context.Context) error {
	// Use a shorter timeout for health checks
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return p.pool.Ping(ctx)
}

// Stats returns the current pool statistics
func (p *Postgres) Stats() *pgxpool.Stat {
	return p.pool.Stat()
}

// AcquireWithTimeout acquires a connection with the configured timeout
// Use this for operations that need explicit connection handling
func (p *Postgres) AcquireWithTimeout(ctx context.Context) (*pgxpool.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(p.cfg.DBAcquireTimeout)*time.Second)
	defer cancel()

	conn, err := p.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to acquire database connection (timeout: %ds): %w", p.cfg.DBAcquireTimeout, err)
	}
	return conn, nil
}

// LogStats logs current pool statistics (useful for monitoring)
func (p *Postgres) LogStats() {
	stats := p.pool.Stat()
	log.Printf("DB Pool Stats: total=%d, idle=%d, inUse=%d, maxConns=%d",
		stats.TotalConns(),
		stats.IdleConns(),
		stats.TotalConns()-stats.IdleConns(),
		stats.MaxConns(),
	)
}
