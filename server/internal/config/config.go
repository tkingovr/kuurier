package config

import (
	"fmt"
	"os"
	"strconv"
)

// Config holds all configuration for the server
type Config struct {
	// Server
	Port        string
	Environment string

	// Database
	DatabaseURL string

	// Redis
	RedisURL string

	// Security
	JWTSecret     []byte
	TokenDuration int // hours

	// Encryption
	EncryptionKey []byte

	// Push notifications
	APNsKeyPath string
	APNsKeyID   string
	APNsTeamID  string
}

// Load reads configuration from environment variables
func Load() (*Config, error) {
	cfg := &Config{
		Port:          getEnv("PORT", "8080"),
		Environment:   getEnv("ENVIRONMENT", "development"),
		DatabaseURL:   getEnv("DATABASE_URL", "postgres://localhost:5432/kuurier?sslmode=disable"),
		RedisURL:      getEnv("REDIS_URL", "redis://localhost:6379"),
		TokenDuration: getEnvInt("TOKEN_DURATION_HOURS", 720), // 30 days default
		APNsKeyPath:   getEnv("APNS_KEY_PATH", ""),
		APNsKeyID:     getEnv("APNS_KEY_ID", ""),
		APNsTeamID:    getEnv("APNS_TEAM_ID", ""),
	}

	// JWT secret is required in production
	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		if cfg.Environment == "production" {
			return nil, fmt.Errorf("JWT_SECRET is required in production")
		}
		// Use a default for development only
		jwtSecret = "dev-secret-do-not-use-in-production"
	}
	cfg.JWTSecret = []byte(jwtSecret)

	// Encryption key for sensitive data
	encKey := os.Getenv("ENCRYPTION_KEY")
	if encKey == "" {
		if cfg.Environment == "production" {
			return nil, fmt.Errorf("ENCRYPTION_KEY is required in production")
		}
		// 32-byte key for AES-256 (development only)
		encKey = "dev-key-32-bytes-do-not-use!!"
	}
	cfg.EncryptionKey = []byte(encKey)

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
