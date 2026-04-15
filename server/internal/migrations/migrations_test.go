package migrations

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListEmbeddedMigrations_ReturnsSortedSQLFiles(t *testing.T) {
	files, err := listEmbeddedMigrations()
	require.NoError(t, err)
	require.NotEmpty(t, files, "should have at least one embedded migration")

	// All entries must be .sql files.
	for _, f := range files {
		assert.True(t, strings.HasSuffix(f, ".sql"), "non-SQL file in listing: %s", f)
	}

	// Must be sorted — migrations are applied in this order.
	for i := 1; i < len(files); i++ {
		assert.Less(t, files[i-1], files[i],
			"migrations out of order: %s before %s", files[i-1], files[i])
	}
}

func TestListEmbeddedMigrations_IncludesKnownFiles(t *testing.T) {
	files, err := listEmbeddedMigrations()
	require.NoError(t, err)

	// At minimum we expect these from the Phase 2 import.
	set := map[string]bool{}
	for _, f := range files {
		set[f] = true
	}
	for _, expected := range []string{
		"001_initial_schema.sql",
		"013_protest_bot.sql",
	} {
		assert.True(t, set[expected], "missing expected migration %s", expected)
	}
}

func TestVersionFromFilename(t *testing.T) {
	cases := map[string]string{
		"001_initial_schema.sql":       "001_initial_schema",
		"013_protest_bot.sql":          "013_protest_bot",
		"100_something.sql":            "100_something",
		"no_extension":                 "no_extension",
		"multiple.dots.in.name.sql":    "multiple.dots.in.name",
	}
	for input, expected := range cases {
		assert.Equal(t, expected, versionFromFilename(input),
			"versionFromFilename(%q)", input)
	}
}

func TestAdvisoryLockKey_Stable(t *testing.T) {
	// Don't change this value — if deploys of two different versions
	// acquire different advisory lock keys, blue/green migration
	// serialization breaks. Changing the value is only safe after
	// confirming no two server versions with different values can
	// run simultaneously.
	assert.Equal(t, int64(4242424242), advisoryLockKey)
}
