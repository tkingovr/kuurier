package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config holds all configuration for the server
type Config struct {
	// Server
	Port        string
	Environment string

	// Database
	DatabaseURL string

	// Database Pool Settings
	DBMaxConns          int32
	DBMinConns          int32
	DBMaxConnLifetime   int // minutes
	DBMaxConnIdleTime   int // minutes
	DBHealthCheckPeriod int // seconds
	DBConnectTimeout    int // seconds
	DBAcquireTimeout    int // seconds

	// Redis
	RedisURL string

	// MinIO (object storage)
	MinIOEndpoint  string
	MinIOAccessKey string
	MinIOSecretKey string
	MinIOBucket    string
	MinIOUseSSL    bool

	// Security
	JWTSecret      []byte
	TokenDuration  int      // hours
	AllowedOrigins []string // CORS allowed origins (empty = allow all in dev)

	// Encryption
	EncryptionKey []byte

	// Push notifications
	APNsKeyPath    string
	APNsKeyID      string
	APNsTeamID     string
	APNsBundleID   string
	APNsProduction bool
}

// Load reads configuration from environment variables
func Load() (*Config, error) {
	cfg := &Config{
		Port:        getEnv("PORT", "8080"),
		Environment: getEnv("ENVIRONMENT", "development"),
		DatabaseURL: getEnv("DATABASE_URL", "postgres://localhost:5432/kuurier?sslmode=disable"),

		// Database Pool Settings
		// These defaults are tuned for a moderate workload
		// Adjust based on your PostgreSQL max_connections and expected load
		DBMaxConns:          int32(getEnvInt("DB_MAX_CONNS", 50)),          // Max connections in pool
		DBMinConns:          int32(getEnvInt("DB_MIN_CONNS", 10)),          // Min idle connections
		DBMaxConnLifetime:   getEnvInt("DB_MAX_CONN_LIFETIME", 60),         // Close conns older than 60 min
		DBMaxConnIdleTime:   getEnvInt("DB_MAX_CONN_IDLE_TIME", 15),        // Close idle conns after 15 min
		DBHealthCheckPeriod: getEnvInt("DB_HEALTH_CHECK_PERIOD", 30),       // Health check every 30s
		DBConnectTimeout:    getEnvInt("DB_CONNECT_TIMEOUT", 10),           // Connection timeout 10s
		DBAcquireTimeout:    getEnvInt("DB_ACQUIRE_TIMEOUT", 5),            // Wait max 5s for connection

		RedisURL:       getEnv("REDIS_URL", "redis://localhost:6379"),
		MinIOEndpoint:  getEnv("MINIO_ENDPOINT", "localhost:9000"),
		MinIOAccessKey: getEnv("MINIO_ACCESS_KEY", "kuurier_admin"),
		MinIOSecretKey: getEnv("MINIO_SECRET_KEY", "kuurier_minio_password"),
		MinIOBucket:    getEnv("MINIO_BUCKET", "kuurier-media"),
		MinIOUseSSL:    getEnv("MINIO_USE_SSL", "false") == "true",
		TokenDuration:  getEnvInt("TOKEN_DURATION_HOURS", 720), // 30 days default
		APNsKeyPath:    getEnv("APNS_KEY_PATH", ""),
		APNsKeyID:      getEnv("APNS_KEY_ID", ""),
		APNsTeamID:     getEnv("APNS_TEAM_ID", ""),
		APNsBundleID:   getEnv("APNS_BUNDLE_ID", "com.kuurier.app"),
		APNsProduction: getEnv("APNS_PRODUCTION", "false") == "true",
	}

	// JWT secret is required in production
	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		if cfg.Environment == "production" {
			return nil, fmt.Errorf("JWT_SECRET is required in production - generate with: openssl rand -base64 32")
		}
		// Use a clearly marked dev secret only in development
		jwtSecret = "INSECURE_DEV_SECRET_CHANGE_IN_PRODUCTION"
		fmt.Println("WARNING: Using insecure default JWT secret. Set JWT_SECRET in production!")
	}
	// Ensure minimum length for JWT secret (32 bytes recommended)
	if len(jwtSecret) < 32 {
		return nil, fmt.Errorf("JWT_SECRET must be at least 32 characters")
	}
	cfg.JWTSecret = []byte(jwtSecret)

	// Encryption key for sensitive data
	encKey := os.Getenv("ENCRYPTION_KEY")
	if encKey == "" {
		if cfg.Environment == "production" {
			return nil, fmt.Errorf("ENCRYPTION_KEY is required in production - generate with: openssl rand -base64 32")
		}
		// 32-byte key for AES-256 (development only)
		encKey = "INSECURE_DEV_KEY_32_CHANGE_ME!!"
		fmt.Println("WARNING: Using insecure default encryption key. Set ENCRYPTION_KEY in production!")
	}
	// Encryption key must be exactly 32 bytes for AES-256
	if len(encKey) != 32 {
		return nil, fmt.Errorf("ENCRYPTION_KEY must be exactly 32 characters for AES-256")
	}
	cfg.EncryptionKey = []byte(encKey)

	// CORS allowed origins (required in production)
	corsOrigins := os.Getenv("CORS_ALLOWED_ORIGINS")
	if corsOrigins != "" {
		cfg.AllowedOrigins = strings.Split(corsOrigins, ",")
		// Trim whitespace from each origin
		for i, origin := range cfg.AllowedOrigins {
			cfg.AllowedOrigins[i] = strings.TrimSpace(origin)
		}
	} else if cfg.Environment == "production" {
		return nil, fmt.Errorf("CORS_ALLOWED_ORIGINS is required in production (comma-separated list)")
	}
	// Empty AllowedOrigins in development = allow all (handled by middleware)

	return cfg, nil
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
	}
	return defaultValue
}
