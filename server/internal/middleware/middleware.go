package middleware

import (
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Logger provides request logging
func Logger() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		path := c.Request.URL.Path

		c.Next()

		// Log after request completes
		latency := time.Since(start)
		status := c.Writer.Status()
		method := c.Request.Method

		// Minimal logging - no IPs for privacy
		log.Printf("%s %s %d %v", method, path, status, latency)
	}
}

// CORS handles Cross-Origin Resource Sharing
func CORS() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*") // Restrict in production
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")
		c.Header("Access-Control-Max-Age", "86400")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}

		c.Next()
	}
}

// Security adds security headers
func Security() gin.HandlerFunc {
	return func(c *gin.Context) {
		// Prevent MIME type sniffing
		c.Header("X-Content-Type-Options", "nosniff")

		// Prevent clickjacking
		c.Header("X-Frame-Options", "DENY")

		// Enable XSS filter
		c.Header("X-XSS-Protection", "1; mode=block")

		// Strict transport security (HTTPS only)
		c.Header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")

		// Content Security Policy
		c.Header("Content-Security-Policy", "default-src 'self'")

		// Don't expose server info
		c.Header("Server", "")

		// Referrer policy
		c.Header("Referrer-Policy", "no-referrer")

		// Permissions policy
		c.Header("Permissions-Policy", "geolocation=(), camera=(), microphone=()")

		c.Next()
	}
}

// RateLimit implements rate limiting per token
func RateLimit(redis *storage.Redis) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Get identifier (user ID from token, or hashed fingerprint for anonymous)
		identifier := c.GetString("user_id")
		if identifier == "" {
			// For unauthenticated requests, use a hash of headers (not IP)
			identifier = "anon:" + hashFingerprint(c)
		}

		key := "ratelimit:" + identifier

		// Check rate limit (100 requests per minute)
		ctx := c.Request.Context()
		count, err := redis.Client().Incr(ctx, key).Result()
		if err != nil {
			// If Redis fails, allow the request (fail open for availability)
			c.Next()
			return
		}

		// Set expiry on first request
		if count == 1 {
			redis.Client().Expire(ctx, key, time.Minute)
		}

		if count > 100 {
			c.Header("Retry-After", "60")
			c.JSON(http.StatusTooManyRequests, gin.H{
				"error": "rate limit exceeded",
			})
			c.Abort()
			return
		}

		c.Next()
	}
}

// Auth validates JWT tokens
func Auth(cfg *config.Config) gin.HandlerFunc {
	return func(c *gin.Context) {
		authHeader := c.GetHeader("Authorization")
		if authHeader == "" {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "authorization header required"})
			c.Abort()
			return
		}

		// Extract token from "Bearer <token>"
		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 || parts[0] != "Bearer" {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid authorization header format"})
			c.Abort()
			return
		}

		tokenString := parts[1]

		// Parse and validate token
		token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
			// Validate signing method
			if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
				return nil, jwt.ErrSignatureInvalid
			}
			return cfg.JWTSecret, nil
		})

		if err != nil || !token.Valid {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
			c.Abort()
			return
		}

		// Extract claims
		claims, ok := token.Claims.(jwt.MapClaims)
		if !ok {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid token claims"})
			c.Abort()
			return
		}

		// Set user info in context
		c.Set("user_id", claims["sub"])
		c.Set("trust_score", claims["trust_score"])

		c.Next()
	}
}

// RequireTrust checks minimum trust score for sensitive operations
func RequireTrust(minScore int) gin.HandlerFunc {
	return func(c *gin.Context) {
		trustScore, exists := c.Get("trust_score")
		if !exists {
			c.JSON(http.StatusForbidden, gin.H{"error": "trust score not found"})
			c.Abort()
			return
		}

		score, ok := trustScore.(float64)
		if !ok || int(score) < minScore {
			c.JSON(http.StatusForbidden, gin.H{
				"error":    "insufficient trust level",
				"required": minScore,
				"current":  int(score),
			})
			c.Abort()
			return
		}

		c.Next()
	}
}

// hashFingerprint creates a privacy-preserving identifier from request headers
func hashFingerprint(c *gin.Context) string {
	// Use non-identifying headers to create a fingerprint
	// This is NOT for tracking, just for rate limiting
	data := c.GetHeader("User-Agent") + c.GetHeader("Accept-Language")
	// In production, use a proper hash
	return data[:min(32, len(data))]
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
