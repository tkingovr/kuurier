package middleware

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
)

func TestMaxBodySize_AllowsSmallBody(t *testing.T) {
	router := gin.New()
	router.Use(MaxBodySize(1024)) // 1KB limit
	router.POST("/test", func(c *gin.Context) {
		body := make([]byte, 100)
		n, _ := c.Request.Body.Read(body)
		c.JSON(http.StatusOK, gin.H{"bytes_read": n})
	})

	req := httptest.NewRequest("POST", "/test", bytes.NewReader(make([]byte, 100)))
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusOK, w.Code)
}

func TestMaxBodySize_RejectsOversizedBody(t *testing.T) {
	router := gin.New()
	router.Use(MaxBodySize(100)) // 100 byte limit
	router.POST("/test", func(c *gin.Context) {
		// Try to read the entire oversized body
		buf := new(bytes.Buffer)
		_, err := buf.ReadFrom(c.Request.Body)
		if err != nil {
			c.JSON(http.StatusRequestEntityTooLarge, gin.H{"error": "body too large"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"size": buf.Len()})
	})

	// Send 1KB body against 100-byte limit
	largeBody := strings.NewReader(strings.Repeat("x", 1024))
	req := httptest.NewRequest("POST", "/test", largeBody)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusRequestEntityTooLarge, w.Code)
}

func TestHashFingerprintHMAC_IncludesIP(t *testing.T) {
	secret := []byte("test-secret-key-for-rate-limiting")

	// Two requests from different IPs with same headers should produce different fingerprints
	router := gin.New()
	var fingerprint1, fingerprint2 string

	router.GET("/test", func(c *gin.Context) {
		fp := hashFingerprintHMAC(c, secret)
		if fingerprint1 == "" {
			fingerprint1 = fp
		} else {
			fingerprint2 = fp
		}
		c.JSON(http.StatusOK, gin.H{})
	})

	// Request 1 from IP 1.1.1.1
	req1 := httptest.NewRequest("GET", "/test", nil)
	req1.Header.Set("User-Agent", "TestBrowser/1.0")
	req1.Header.Set("X-Forwarded-For", "1.1.1.1")
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, req1)

	// Request 2 from IP 2.2.2.2 with same UA
	req2 := httptest.NewRequest("GET", "/test", nil)
	req2.Header.Set("User-Agent", "TestBrowser/1.0")
	req2.Header.Set("X-Forwarded-For", "2.2.2.2")
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, req2)

	assert.NotEmpty(t, fingerprint1)
	assert.NotEmpty(t, fingerprint2)
	assert.NotEqual(t, fingerprint1, fingerprint2, "Different IPs should produce different fingerprints")
}

func TestHashFingerprintHMAC_Deterministic(t *testing.T) {
	secret := []byte("test-secret-key-for-rate-limiting")

	router := gin.New()
	var fp1, fp2 string

	router.GET("/test", func(c *gin.Context) {
		fp := hashFingerprintHMAC(c, secret)
		if fp1 == "" {
			fp1 = fp
		} else {
			fp2 = fp
		}
		c.JSON(http.StatusOK, gin.H{})
	})

	// Two identical requests should produce the same fingerprint
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest("GET", "/test", nil)
		req.Header.Set("User-Agent", "TestBrowser/1.0")
		req.Header.Set("Accept-Language", "en-US")
		req.Header.Set("X-Forwarded-For", "1.1.1.1")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
	}

	assert.Equal(t, fp1, fp2, "Same request metadata should produce the same fingerprint")
}
