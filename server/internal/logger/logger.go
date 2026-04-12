// Package logger provides structured logging for the Kuurier server.
// Uses Go's built-in log/slog for JSON-structured output in production
// and human-readable text output in development.
package logger

import (
	"log/slog"
	"os"
)

// Init configures the global slog logger based on the environment.
// Call once at startup before any other logging.
func Init(environment string) {
	var handler slog.Handler

	if environment == "production" {
		// JSON output for production — easy to parse, index, and alert on
		handler = slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
			Level:     slog.LevelInfo,
			AddSource: false, // Don't include source file in production (security)
		})
	} else {
		// Human-readable text output for development
		handler = slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
			Level:     slog.LevelDebug,
			AddSource: true,
		})
	}

	slog.SetDefault(slog.New(handler))
}

// Convenience re-exports for the most common patterns.
// Callers can also use slog directly for more control.

func Info(msg string, args ...any)  { slog.Info(msg, args...) }
func Warn(msg string, args ...any)  { slog.Warn(msg, args...) }
func Error(msg string, args ...any) { slog.Error(msg, args...) }
func Debug(msg string, args ...any) { slog.Debug(msg, args...) }
