package feed

import (
	"math"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestRecencyScore_RecentPostScoresHigher(t *testing.T) {
	now := time.Now()
	oneHourAgo := now.Add(-1 * time.Hour)
	oneDayAgo := now.Add(-24 * time.Hour)

	scoreNow := recencyScore(now)
	scoreOneHour := recencyScore(oneHourAgo)
	scoreOneDay := recencyScore(oneDayAgo)

	assert.Greater(t, scoreNow, scoreOneHour)
	assert.Greater(t, scoreOneHour, scoreOneDay)
}

func TestRecencyScore_HalfLife(t *testing.T) {
	now := time.Now()
	eightHoursAgo := now.Add(-8 * time.Hour)

	scoreNow := recencyScore(now)
	scoreHalfLife := recencyScore(eightHoursAgo)

	// After one half-life (8 hours), score should be ~50% of current
	ratio := scoreHalfLife / scoreNow
	assert.InDelta(t, 0.5, ratio, 0.01)
}

func TestRecencyScore_NeverNegative(t *testing.T) {
	veryOld := time.Now().Add(-365 * 24 * time.Hour)
	score := recencyScore(veryOld)

	assert.GreaterOrEqual(t, score, 0.0)
}

func TestConfidenceScore_HighTrustFirsthand(t *testing.T) {
	highTrust := postCandidate{
		authorTrustScore:  100,
		verificationScore: 10,
		sourceType:        "firsthand",
	}

	lowTrust := postCandidate{
		authorTrustScore:  10,
		verificationScore: -3,
		sourceType:        "mainstream",
	}

	assert.Greater(t, confidenceScore(highTrust), confidenceScore(lowTrust))
}

func TestConfidenceScore_Bounded(t *testing.T) {
	extreme := postCandidate{
		authorTrustScore:  10000,
		verificationScore: 10000,
		sourceType:        "firsthand",
	}

	score := confidenceScore(extreme)
	assert.LessOrEqual(t, score, 1.0)
	assert.GreaterOrEqual(t, score, 0.0)
}

func TestDistanceMeters_SamePoint(t *testing.T) {
	dist := distanceMeters(40.7128, -74.0060, 40.7128, -74.0060)
	assert.Equal(t, 0.0, dist)
}

func TestDistanceMeters_KnownDistance(t *testing.T) {
	// NYC to LA is approximately 3,944 km
	dist := distanceMeters(40.7128, -74.0060, 34.0522, -118.2437)
	distKm := dist / 1000.0

	assert.InDelta(t, 3944, distKm, 100) // Within 100km tolerance
}

func TestPostMatchesTopics_MatchFound(t *testing.T) {
	postTopics := []string{"climate", "labor"}
	subTopics := map[string]int{"climate": 1, "housing": 2}

	match, matchedTopic := postMatchesTopics(postTopics, subTopics, 1)
	assert.True(t, match)
	assert.NotNil(t, matchedTopic)
	assert.Equal(t, "climate", *matchedTopic)
}

func TestPostMatchesTopics_NoMatch(t *testing.T) {
	postTopics := []string{"climate", "labor"}
	subTopics := map[string]int{"housing": 1, "education": 1}

	match, matchedTopic := postMatchesTopics(postTopics, subTopics, 1)
	assert.False(t, match)
	assert.Nil(t, matchedTopic)
}

func TestPostMatchesTopics_UrgencyFilter(t *testing.T) {
	postTopics := []string{"climate"}
	subTopics := map[string]int{"climate": 3} // Requires urgency 3

	// Urgency 1 post should not match subscription requiring urgency 3
	match, _ := postMatchesTopics(postTopics, subTopics, 1)
	assert.False(t, match)

	// Urgency 3 post should match
	match, _ = postMatchesTopics(postTopics, subTopics, 3)
	assert.True(t, match)
}

func TestPostMatchesLocation_InRadius(t *testing.T) {
	lat := 40.7128
	lon := -74.0060
	post := postCandidate{latitude: &lat, longitude: &lon, urgency: 1}

	nearbyLat := 40.7200
	nearbyLon := -74.0100
	radius := 5000 // 5km
	subs := []feedSubscription{{
		latitude:     &nearbyLat,
		longitude:    &nearbyLon,
		radiusMeters: &radius,
		minUrgency:   1,
	}}

	assert.True(t, postMatchesLocation(post, subs))
}

func TestPostMatchesLocation_OutOfRadius(t *testing.T) {
	lat := 40.7128
	lon := -74.0060
	post := postCandidate{latitude: &lat, longitude: &lon, urgency: 1}

	farLat := 34.0522
	farLon := -118.2437
	radius := 5000 // 5km — LA is way too far from NYC
	subs := []feedSubscription{{
		latitude:     &farLat,
		longitude:    &farLon,
		radiusMeters: &radius,
		minUrgency:   1,
	}}

	assert.False(t, postMatchesLocation(post, subs))
}

func TestRankFeedCandidates_CrisisFiltering(t *testing.T) {
	now := time.Now()
	lat := 40.7128
	lon := -74.0060

	candidates := []postCandidate{
		{id: "urgent", authorID: "a", urgency: 3, createdAt: now.Add(-1 * time.Hour), latitude: &lat, longitude: &lon, authorTrustScore: 50},
		{id: "normal", authorID: "b", urgency: 1, createdAt: now.Add(-1 * time.Hour), latitude: &lat, longitude: &lon, authorTrustScore: 50},
		{id: "old-urgent", authorID: "c", urgency: 3, createdAt: now.Add(-96 * time.Hour), latitude: &lat, longitude: &lon, authorTrustScore: 50},
	}

	scored := (&Handler{}).rankFeedCandidates(
		FeedTypeCrisis, candidates, nil, nil, &lat, &lon, 50000, 0,
	)

	// Only urgency >= 2 and within 72 hours should appear
	assert.Len(t, scored, 1)
	assert.Equal(t, "urgent", scored[0].post.id)
}

func TestBuildWhyList_MaxThree(t *testing.T) {
	why := buildWhyList(FeedTypeCrisis, true, strPtr("climate"), map[string]string{"climate": "Climate"}, 0.9, 0.9, 0.9)
	assert.LessOrEqual(t, len(why), 3)
}

func TestBuildWhyList_NearYou(t *testing.T) {
	why := buildWhyList(FeedTypeLocal, false, nil, nil, 0.8, 0.1, 0.1)
	assert.Contains(t, why, "Near you")
}

func TestDistanceMeters_Symmetry(t *testing.T) {
	d1 := distanceMeters(40.7128, -74.0060, 34.0522, -118.2437)
	d2 := distanceMeters(34.0522, -118.2437, 40.7128, -74.0060)
	assert.InDelta(t, d1, d2, 0.001)
}

func TestRecencyScore_Monotonic(t *testing.T) {
	prev := math.Inf(1)
	for hours := 0; hours <= 72; hours += 4 {
		score := recencyScore(time.Now().Add(-time.Duration(hours) * time.Hour))
		assert.LessOrEqual(t, score, prev, "Score should decrease monotonically with age")
		prev = score
	}
}

func strPtr(s string) *string { return &s }
