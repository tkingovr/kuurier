package middleware

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRequestID_GeneratesWhenMissing(t *testing.T) {
	router := gin.New()
	router.Use(RequestID())

	var observed string
	router.GET("/test", func(c *gin.Context) {
		observed = c.GetString(RequestIDContextKey)
		c.Status(http.StatusOK)
	})

	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.NotEmpty(t, observed, "request_id should be set on context")
	assert.Equal(t, observed, w.Header().Get(RequestIDHeader),
		"X-Request-ID response header should match the context value")
	// UUID v4 is 36 chars including dashes.
	assert.Len(t, observed, 36)
}

func TestRequestID_HonorsIncomingHeader(t *testing.T) {
	router := gin.New()
	router.Use(RequestID())

	var observed string
	router.GET("/test", func(c *gin.Context) {
		observed = c.GetString(RequestIDContextKey)
		c.Status(http.StatusOK)
	})

	req := httptest.NewRequest("GET", "/test", nil)
	req.Header.Set(RequestIDHeader, "client-supplied-id-123")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, "client-supplied-id-123", observed)
	assert.Equal(t, "client-supplied-id-123", w.Header().Get(RequestIDHeader))
}

func TestRequestID_RejectsOversizedHeader(t *testing.T) {
	router := gin.New()
	router.Use(RequestID())

	var observed string
	router.GET("/test", func(c *gin.Context) {
		observed = c.GetString(RequestIDContextKey)
		c.Status(http.StatusOK)
	})

	req := httptest.NewRequest("GET", "/test", nil)
	req.Header.Set(RequestIDHeader, strings.Repeat("x", 500))
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.NotEqual(t, strings.Repeat("x", 500), observed, "oversized ID must be replaced")
	assert.Len(t, observed, 36, "replacement should be a UUID")
}

func TestRequestIDFromContext_NonGinContext(t *testing.T) {
	ctx := context.WithValue(context.Background(), RequestIDContextKey, "direct-ctx-id")
	assert.Equal(t, "direct-ctx-id", RequestIDFromContext(ctx))
}

func TestRequestIDFromContext_Empty(t *testing.T) {
	assert.Equal(t, "", RequestIDFromContext(context.Background()))
}

// captureSlog redirects the default slog logger to a buffer for the
// duration of the test and restores it afterwards. Each log line is
// one JSON object we can assert against.
func captureSlog(t *testing.T) *bytes.Buffer {
	t.Helper()
	buf := &bytes.Buffer{}
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return buf
}

func parseLogLines(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		require.NoError(t, json.Unmarshal([]byte(line), &m), "each log line must be JSON: %s", line)
		out = append(out, m)
	}
	return out
}

func TestLogger_EmitsStructuredFields(t *testing.T) {
	buf := captureSlog(t)

	router := gin.New()
	router.Use(RequestID())
	router.Use(Logger())
	router.GET("/hello", func(c *gin.Context) {
		c.String(http.StatusOK, "hi")
	})

	req := httptest.NewRequest("GET", "/hello?q=1", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	lines := parseLogLines(t, buf)
	require.Len(t, lines, 1, "expected exactly one log record for the request")
	rec := lines[0]

	assert.Equal(t, "request", rec["msg"])
	assert.Equal(t, "GET", rec["method"])
	assert.Equal(t, "/hello", rec["path"])
	assert.Equal(t, "q=1", rec["query"])
	assert.Equal(t, float64(200), rec["status"])
	assert.NotEmpty(t, rec["request_id"])
	// privacy: must NOT log ip or user agent
	_, hasIP := rec["ip"]
	_, hasUA := rec["user_agent"]
	assert.False(t, hasIP, "privacy invariant: no ip in request logs")
	assert.False(t, hasUA, "privacy invariant: no user_agent in request logs")
}

func TestLogger_WarnsOn4xx(t *testing.T) {
	buf := captureSlog(t)

	router := gin.New()
	router.Use(RequestID())
	router.Use(Logger())
	router.GET("/bad", func(c *gin.Context) {
		c.String(http.StatusNotFound, "nope")
	})

	req := httptest.NewRequest("GET", "/bad", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	lines := parseLogLines(t, buf)
	require.Len(t, lines, 1)
	assert.Equal(t, "WARN", lines[0]["level"])
}

func TestLogger_ErrorsOn5xx(t *testing.T) {
	buf := captureSlog(t)

	router := gin.New()
	router.Use(RequestID())
	router.Use(Logger())
	router.GET("/boom", func(c *gin.Context) {
		c.String(http.StatusInternalServerError, "broken")
	})

	req := httptest.NewRequest("GET", "/boom", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	lines := parseLogLines(t, buf)
	require.Len(t, lines, 1)
	assert.Equal(t, "ERROR", lines[0]["level"])
}

func TestLogger_IncludesUserIDWhenSet(t *testing.T) {
	buf := captureSlog(t)

	router := gin.New()
	router.Use(RequestID())
	// Simulate the auth middleware setting user_id before Logger runs.
	// Logger reads user_id from context post-Next(), so we need a
	// middleware that sets it before c.Next() too.
	router.Use(func(c *gin.Context) { c.Set("user_id", "u-42"); c.Next() })
	router.Use(Logger())
	router.GET("/me", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest("GET", "/me", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	lines := parseLogLines(t, buf)
	require.Len(t, lines, 1)
	assert.Equal(t, "u-42", lines[0]["user_id"])
}
