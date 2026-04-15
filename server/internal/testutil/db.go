// Package testutil provides helpers for integration tests that
// need a real database. Uses testcontainers-go to spin up a
// throwaway PostGIS container, run migrations, and hand back a
// connection pool scoped to the test's lifetime.
//
// Usage:
//
//	func TestSomething(t *testing.T) {
//	    pool := testutil.NewTestDB(t)
//	    // pool is ready; schema is migrated; container stops on t.Cleanup.
//	}
//
// Tests that need a database should be guarded by a build tag so
// `go test ./...` doesn't try to spin up Docker containers by
// default. Add `//go:build integration` at the top of the file.
package testutil

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/kuurier/server/internal/migrations"
	"github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

// NewTestDB starts a PostGIS container, runs all embedded migrations
// against it, and returns a pgxpool.Pool. The container is stopped
// automatically via t.Cleanup.
//
// Fails the test immediately if Docker isn't available or the
// container can't start — integration tests are expected to run
// in CI where Docker is present.
func NewTestDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	ctx := context.Background()

	container, err := tcpg.Run(ctx,
		"postgis/postgis:16-3.4",
		tcpg.WithDatabase("kuurier_test"),
		tcpg.WithUsername("kuurier_test"),
		tcpg.WithPassword("test_password"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(30*time.Second)),
	)
	if err != nil {
		t.Fatalf("start postgis container: %v", err)
	}
	t.Cleanup(func() {
		if err := container.Terminate(ctx); err != nil {
			t.Logf("terminate container: %v", err)
		}
	})

	connStr, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("connection string: %v", err)
	}

	pool, err := pgxpool.New(ctx, connStr)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	if err := migrations.Run(ctx, pool); err != nil {
		t.Fatalf("run migrations: %v", err)
	}
	return pool
}
