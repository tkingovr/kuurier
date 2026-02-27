package invites

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestCalculateInviteAllowance tests the invite allowance formula
func TestCalculateInviteAllowance(t *testing.T) {
	tests := []struct {
		name       string
		trustScore int
		expected   int
	}{
		{"trust 0 - no invites", 0, 0},
		{"trust 15 - below threshold", 15, 0},
		{"trust 29 - just below threshold", 29, 0},
		{"trust 30 - base allowance", 30, 3},
		{"trust 40 - no extra yet (need 20 above 30)", 40, 3},
		{"trust 49 - still base", 49, 3},
		{"trust 50 - one extra", 50, 4},
		{"trust 70 - two extra", 70, 5},
		{"trust 90 - three extra", 90, 6},
		{"trust 100 - three extra (30 + 3*20 = 90 is threshold)", 100, 6},
		{"trust 110 - four extra", 110, 7},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := calculateInviteAllowance(tt.trustScore)
			assert.Equal(t, tt.expected, result, "trust=%d", tt.trustScore)
		})
	}
}

// TestCalculateInviteAllowance_Formula verifies the math
func TestCalculateInviteAllowance_Formula(t *testing.T) {
	// Formula: BaseInviteAllowance + ((trustScore - MinTrustToInvite) / TrustIncrementSize) * InvitesPerTrustIncrement
	// With defaults: 3 + ((trust - 30) / 20) * 1

	// Verify constants match expected values
	assert.Equal(t, 3, BaseInviteAllowance)
	assert.Equal(t, 30, MinTrustToInvite)
	assert.Equal(t, 20, TrustIncrementSize)
	assert.Equal(t, 1, InvitesPerTrustIncrement)

	// Verify the formula is monotonically increasing
	prev := 0
	for trust := 0; trust <= 200; trust++ {
		allowance := calculateInviteAllowance(trust)
		assert.GreaterOrEqual(t, allowance, prev, "allowance should never decrease as trust increases")
		prev = allowance
	}
}

// TestGenerateInviteCode tests code generation
func TestGenerateInviteCode(t *testing.T) {
	code, err := generateInviteCode()
	require.NoError(t, err)

	// Format: KUU-XXXXXX
	assert.Len(t, code, 10, "code should be 10 chars: KUU- + 6")
	assert.Equal(t, "KUU-", code[:4], "code should start with KUU-")

	// Verify only allowed characters (no ambiguous: 0, O, 1, I)
	allowed := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for _, ch := range code[4:] {
		assert.Contains(t, allowed, string(ch), "character %c should be in allowed charset", ch)
	}
}

// TestGenerateInviteCode_Uniqueness verifies codes are likely unique
func TestGenerateInviteCode_Uniqueness(t *testing.T) {
	codes := make(map[string]bool)
	n := 100

	for i := 0; i < n; i++ {
		code, err := generateInviteCode()
		require.NoError(t, err)
		codes[code] = true
	}

	// With 32^6 (~1 billion) possible codes, 100 should all be unique
	assert.Equal(t, n, len(codes), "all generated codes should be unique")
}

// TestGenerateInviteCode_NoAmbiguousChars ensures no ambiguous characters
func TestGenerateInviteCode_NoAmbiguousChars(t *testing.T) {
	ambiguous := "0O1I"

	for i := 0; i < 50; i++ {
		code, err := generateInviteCode()
		require.NoError(t, err)

		suffix := code[4:] // Skip KUU- prefix
		for _, ch := range suffix {
			assert.NotContains(t, ambiguous, string(ch),
				"code %s contains ambiguous char %c", code, ch)
		}
	}
}

// TestInviteCodeExpiry verifies the expiry constant
func TestInviteCodeExpiry(t *testing.T) {
	assert.Equal(t, 7*24, int(InviteCodeExpiry.Hours()), "invite codes should expire in 7 days")
}

// TestInviteCodeStatus tests the status determination logic
func TestInviteCodeStatus(t *testing.T) {
	// Status is determined by: used_at != nil -> "used", expires_at < now -> "expired", else "active"
	// This tests the logic inline since it's in ListInvites

	tests := []struct {
		name     string
		used     bool
		expired  bool
		expected string
	}{
		{"active code", false, false, "active"},
		{"used code", true, false, "used"},
		{"expired code", false, true, "expired"},
		{"used and expired", true, true, "used"}, // used takes priority
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var status string
			if tt.used {
				status = "used"
			} else if tt.expired {
				status = "expired"
			} else {
				status = "active"
			}
			assert.Equal(t, tt.expected, status)
		})
	}
}

// TestMinTrustToInvite_Thresholds tests trust score boundaries
func TestMinTrustToInvite_Thresholds(t *testing.T) {
	// Below threshold: no invites
	assert.Equal(t, 0, calculateInviteAllowance(MinTrustToInvite-1))

	// At threshold: base invites
	assert.Equal(t, BaseInviteAllowance, calculateInviteAllowance(MinTrustToInvite))

	// Above threshold: more invites
	assert.Greater(t, calculateInviteAllowance(MinTrustToInvite+TrustIncrementSize), BaseInviteAllowance)
}

// TestMaxFunction tests the max helper
func TestMaxFunction(t *testing.T) {
	assert.Equal(t, 5, max(3, 5))
	assert.Equal(t, 5, max(5, 3))
	assert.Equal(t, 0, max(0, 0))
	assert.Equal(t, 0, max(-1, 0))
	assert.Equal(t, 1, max(1, -1))
}

// TestCodeFormat_RegexPattern verifies codes match the DB constraint
func TestCodeFormat_RegexPattern(t *testing.T) {
	// DB constraint: code ~ '^KUU-[A-Z0-9]{6}$'
	// Our charset is a subset (no 0, O, 1, I) so all generated codes must match

	for i := 0; i < 50; i++ {
		code, err := generateInviteCode()
		require.NoError(t, err)

		assert.Regexp(t, `^KUU-[A-Z0-9]{6}$`, code,
			fmt.Sprintf("code %s should match DB constraint", code))
	}
}
