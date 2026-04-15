// Package migrations applies SQL files embedded in the binary against
// a PostgreSQL database on startup.
//
// Design choices:
//   - Rolled our own instead of pulling in goose or golang-migrate.
//     Both use a version-tracking table schema (integer version_id)
//     that differs from the existing schema_migrations(version VARCHAR)
//     we've already populated in production. A dependency plus a
//     state-migration PR exceeded the cost of ~150 lines of Go here.
//
//   - Advisory lock (pg_advisory_lock) serializes concurrent runs
//     across blue/green containers during deploy. The second caller
//     waits for the first to finish, then observes the applied set
//     and returns with nothing to do.
//
//   - Bootstrap shortcut: if schema_migrations is empty but the users
//     table exists, we treat that as "existing DB, predates tracking"
//     and mark every embedded file as already-applied. This handles
//     the transition case where the production DB had migrations
//     applied ad-hoc before we introduced the tracking table.
//
//   - Each pending migration runs in its own transaction alongside
//     its tracking INSERT. A failure rolls back both — we never
//     record a version that didn't actually apply.
package migrations

import (
	"context"
	"embed"
	"fmt"
	"log/slog"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed sql/*.sql
var migrationFS embed.FS

// advisoryLockKey is an arbitrary int64 used with pg_advisory_lock so
// only one process runs migrations at a time. The value has no meaning
// beyond being project-specific and unlikely to collide with
// application-level advisory locks.
const advisoryLockKey int64 = 4242424242

// Run applies any pending SQL files in the embedded sql/ directory.
// Safe to call concurrently; the advisory lock serializes execution.
//
// On entry, pool must be connected and healthy. On return, the
// database schema is up-to-date with the embedded files or an error
// describes what failed.
func Run(ctx context.Context, pool *pgxpool.Pool) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire connection: %w", err)
	}
	defer conn.Release()

	// Acquire advisory lock. Blocks until the previous holder releases
	// (or their connection closes, which also releases the lock).
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", advisoryLockKey); err != nil {
		return fmt.Errorf("acquire advisory lock: %w", err)
	}
	// Always release on exit, even if ctx is cancelled.
	defer func() {
		releaseCtx := context.Background()
		_, _ = conn.Exec(releaseCtx, "SELECT pg_advisory_unlock($1)", advisoryLockKey)
	}()

	if _, err := conn.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    VARCHAR(255) PRIMARY KEY,
			applied_at TIMESTAMPTZ  DEFAULT NOW()
		)`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	filenames, err := listEmbeddedMigrations()
	if err != nil {
		return fmt.Errorf("list embedded migrations: %w", err)
	}

	applied, err := loadAppliedVersions(ctx, conn.Conn())
	if err != nil {
		return fmt.Errorf("load applied versions: %w", err)
	}

	// Bootstrap: existing DB with no tracking table history.
	if len(applied) == 0 {
		existing, err := hasExistingSchema(ctx, conn.Conn())
		if err != nil {
			return fmt.Errorf("detect existing schema: %w", err)
		}
		if existing {
			slog.InfoContext(ctx, "bootstrap: schema_migrations empty but DB already has tables — marking all embedded migrations as applied")
			for _, name := range filenames {
				version := versionFromFilename(name)
				if _, err := conn.Exec(ctx,
					`INSERT INTO schema_migrations (version) VALUES ($1) ON CONFLICT DO NOTHING`,
					version); err != nil {
					return fmt.Errorf("bootstrap insert %s: %w", version, err)
				}
				applied[version] = true
			}
		}
	}

	appliedCount := 0
	for _, name := range filenames {
		version := versionFromFilename(name)
		if applied[version] {
			continue
		}

		sqlBytes, err := migrationFS.ReadFile("sql/" + name)
		if err != nil {
			return fmt.Errorf("read %s: %w", name, err)
		}

		if err := applyOne(ctx, conn.Conn(), version, string(sqlBytes)); err != nil {
			return err
		}
		slog.InfoContext(ctx, "migration applied", slog.String("version", version))
		appliedCount++
	}

	slog.InfoContext(ctx, "migrations complete",
		slog.Int("applied", appliedCount),
		slog.Int("total_embedded", len(filenames)))
	return nil
}

// listEmbeddedMigrations returns .sql filenames from the embedded
// sql/ directory, sorted lexicographically (which matches numeric
// order as long as we zero-pad the prefix).
func listEmbeddedMigrations() ([]string, error) {
	entries, err := migrationFS.ReadDir("sql")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, ".sql") {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names, nil
}

// versionFromFilename strips the .sql suffix. "013_protest_bot.sql"
// becomes "013_protest_bot", which is what's stored in
// schema_migrations.version so it lines up with the Phase 1.2 tracking.
func versionFromFilename(name string) string {
	return strings.TrimSuffix(name, ".sql")
}

func loadAppliedVersions(ctx context.Context, conn *pgx.Conn) (map[string]bool, error) {
	rows, err := conn.Query(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	applied := map[string]bool{}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		applied[v] = true
	}
	return applied, rows.Err()
}

// hasExistingSchema returns true if the public.users table exists.
// Its presence is our proxy for "this is a populated database that
// predates migration tracking".
func hasExistingSchema(ctx context.Context, conn *pgx.Conn) (bool, error) {
	var exists bool
	err := conn.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM information_schema.tables
			WHERE table_schema = 'public' AND table_name = 'users'
		)`).Scan(&exists)
	return exists, err
}

// applyOne runs a single migration inside a transaction together with
// its schema_migrations INSERT. Failure rolls back both.
func applyOne(ctx context.Context, conn *pgx.Conn, version, sqlText string) error {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin tx for %s: %w", version, err)
	}
	// Ensure rollback on any failure path.
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	if _, err := tx.Exec(ctx, sqlText); err != nil {
		return fmt.Errorf("apply %s: %w", version, err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO schema_migrations (version) VALUES ($1)`, version); err != nil {
		return fmt.Errorf("record %s: %w", version, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit %s: %w", version, err)
	}
	committed = true
	return nil
}
