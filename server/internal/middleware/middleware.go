package middleware

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"log"
	"net/http"
	"strings"
	"sync"
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
// In production, only allow requests from trusted origins
func CORS(allowedOrigins []string) gin.HandlerFunc {
	// Build a map for O(1) lookup
	originsMap := make(map[string]bool)
	for _, origin := range allowedOrigins {
		originsMap[origin] = true
	}

	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")

		// Check if origin is allowed
		if len(allowedOrigins) > 0 {
			if _, ok := originsMap[origin]; ok {
				c.Header("Access-Control-Allow-Origin", origin)
				c.Header("Vary", "Origin")
			} else {
				// Origin not allowed - don't set CORS headers
				// Browser will block the request
				if c.Request.Method == "OPTIONS" {
					c.AbortWithStatus(http.StatusForbidden)
					return
				}
			}
		} else {
			// Development mode - allow all origins (empty allowedOrigins list)
			c.Header("Access-Control-Allow-Origin", "*")
		}

		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")
		c.Header("Access-Control-Allow-Credentials", "true")
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

// RateLimitConfig configures rate limiting behavior
type RateLimitConfig struct {
	RequestsPerMinute int64 // Default: 100
	FailClosedMode    bool  // If true, reject requests when Redis is unavailable
}

// Local in-memory rate limiter as fallback
var localRateLimiter = struct {
	sync.Mutex
	counts map[string]int64
	expiry map[string]time.Time
}{
	counts: make(map[string]int64),
	expiry: make(map[string]time.Time),
}

// RateLimit implements rate limiting per token with fail-safe behavior
func RateLimit(redis *storage.Redis, rateCfg *RateLimitConfig, serverCfg *config.Config) gin.HandlerFunc {
	if rateCfg == nil {
		rateCfg = &RateLimitConfig{
			RequestsPerMinute: 100,
			FailClosedMode:    true, // Secure by default
		}
	}

	return func(c *gin.Context) {
		// Get identifier (user ID from token, or hashed fingerprint for anonymous)
		identifier := c.GetString("user_id")
		if identifier == "" {
			// For unauthenticated requests, use HMAC-based fingerprint (not IP)
			identifier = "anon:" + hashFingerprintHMAC(c, serverCfg.JWTSecret)
		}

		key := "ratelimit:" + identifier

		// Check rate limit (configurable requests per minute)
		ctx := c.Request.Context()
		count, err := redis.Client().Incr(ctx, key).Result()

		if err != nil {
			// Redis unavailable - use local fallback or fail closed
			log.Printf("WARNING: Redis rate limit check failed: %v", err)

			if rateCfg.FailClosedMode {
				// Use local in-memory rate limiter as fallback
				count = localRateLimitCheck(key, rateCfg.RequestsPerMinute)
			} else {
				// Legacy behavior: allow request but log warning
				c.Next()
				return
			}
		} else {
			// Set expiry on first request in Redis
			if count == 1 {
				redis.Client().Expire(ctx, key, time.Minute)
			}
		}

		if count > rateCfg.RequestsPerMinute {
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

// localRateLimitCheck provides a local fallback rate limiter
func localRateLimitCheck(key string, limit int64) int64 {
	localRateLimiter.Lock()
	defer localRateLimiter.Unlock()

	// Clean up expired entries periodically
	now := time.Now()
	if len(localRateLimiter.counts) > 10000 {
		for k, exp := range localRateLimiter.expiry {
			if now.After(exp) {
				delete(localRateLimiter.counts, k)
				delete(localRateLimiter.expiry, k)
			}
		}
	}

	// Check if key has expired
	if exp, ok := localRateLimiter.expiry[key]; ok && now.After(exp) {
		delete(localRateLimiter.counts, key)
		delete(localRateLimiter.expiry, key)
	}

	// Increment count
	count := localRateLimiter.counts[key] + 1
	localRateLimiter.counts[key] = count

	// Set expiry if new key
	if _, ok := localRateLimiter.expiry[key]; !ok {
		localRateLimiter.expiry[key] = now.Add(time.Minute)
	}

	return count
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

// hashFingerprintHMAC creates a privacy-preserving identifier from request headers
// SECURITY: Uses HMAC with server secret to prevent fingerprint prediction/manipulation
func hashFingerprintHMAC(c *gin.Context, secret []byte) string {
	// Use non-identifying headers to create a fingerprint
	// This is NOT for tracking, just for rate limiting
	data := c.GetHeader("User-Agent") + "|" + c.GetHeader("Accept-Language") + "|" + c.GetHeader("Accept-Encoding")

	// Use HMAC-SHA256 with server secret for secure hashing
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(data))
	return hex.EncodeToString(mac.Sum(nil))[:32] // Truncate to 32 chars for storage efficiency
}
