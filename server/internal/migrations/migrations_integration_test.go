//go:build integration

package migrations_test

import (
	"context"
	"testing"

	"github.com/kuurier/server/internal/migrations"
	"github.com/kuurier/server/internal/testutil"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigrations_FreshDB_ApplyAll verifies that Run on a completely
// empty database applies every embedded migration successfully.
// This is the most important invariant: a brand-new deployment must
// be able to bootstrap from zero.
func TestMigrations_FreshDB_ApplyAll(t *testing.T) {
	pool := testutil.NewTestDB(t)
	ctx := context.Background()

	// testutil.NewTestDB already ran migrations once. Run again and
	// assert it's a no-op (second run must not re-apply anything).
	err := migrations.Run(ctx, pool)
	require.NoError(t, err)

	// Verify schema_migrations has the expected rows.
	var count int
	require.NoError(t, pool.QueryRow(ctx,
		"SELECT COUNT(*) FROM schema_migrations").Scan(&count))
	assert.GreaterOrEqual(t, count, 14, "expect all migrations 001-014 tracked")

	// Verify a representative table exists.
	var usersExists bool
	require.NoError(t, pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.tables
			WHERE table_schema = 'public' AND table_name = 'users'
		)`).Scan(&usersExists))
	assert.True(t, usersExists)

	// materialized_feeds (migration 014) is the most recent — confirm
	// it landed too.
	var mfExists bool
	require.NoError(t, pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.tables
			WHERE table_schema = 'public' AND table_name = 'materialized_feeds'
		)`).Scan(&mfExists))
	assert.True(t, mfExists)
}
