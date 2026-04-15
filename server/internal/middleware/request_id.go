package middleware

import (
	"context"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// Context keys and HTTP header names for request correlation.
const (
	// RequestIDContextKey is the gin.Context key under which the
	// request ID is stored. Use c.GetString(RequestIDContextKey) to read it.
	RequestIDContextKey = "request_id"

	// RequestIDHeader is the incoming/outgoing HTTP header name.
	// Clients may supply their own ID; if so, we honor it so a
	// distributed trace can span multiple hops.
	RequestIDHeader = "X-Request-ID"
)

// RequestID ensures every request has a unique identifier. If the
// incoming request supplies X-Request-ID, we use it (trusting the
// upstream caller). Otherwise we generate a UUID.
//
// The ID is stored on gin.Context under RequestIDContextKey and echoed
// back in the X-Request-ID response header so clients can correlate
// log lines with their requests when reporting issues.
func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		id := c.GetHeader(RequestIDHeader)
		if id == "" || len(id) > 128 {
			// Either missing or unreasonably long — generate our own.
			id = uuid.NewString()
		}
		c.Set(RequestIDContextKey, id)
		c.Writer.Header().Set(RequestIDHeader, id)
		c.Next()
	}
}

// RequestIDFromContext extracts the request ID from a standard
// context.Context. Used by downstream code (DB access, background
// goroutines spawned from a request) to include the ID in their own
// logs via slog.InfoContext.
func RequestIDFromContext(ctx context.Context) string {
	if gc, ok := ctx.(*gin.Context); ok {
		return gc.GetString(RequestIDContextKey)
	}
	if v := ctx.Value(RequestIDContextKey); v != nil {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}
