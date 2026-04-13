package bot

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParseNextData_ValidHTML(t *testing.T) {
	// Build the JSON manually to avoid struct tag mismatch
	nextData := map[string]interface{}{
		"props": map[string]interface{}{
			"pageProps": map[string]interface{}{
				"events": []map[string]interface{}{
					{
						"_id":       "test-1",
						"title":     "Climate March",
						"date":      "2026-05-01",
						"time":      "14:00",
						"location":  "City Hall",
						"city":      "Portland",
						"state":     "OR",
						"country":   "United States",
						"organiser": "Climate Action",
						"coords":    map[string]interface{}{"lat": 45.5, "lng": -122.6},
						"recurrent": "No",
						"cause":     []map[string]string{{"label": "Climate Change", "value": "climate-change"}},
					},
				},
			},
		},
	}

	jsonBytes, err := json.Marshal(nextData)
	require.NoError(t, err)

	html := fmt.Sprintf(`<html><head><script id="__NEXT_DATA__" type="application/json">%s</script></head></html>`, string(jsonBytes))

	protests, err := parseNextData([]byte(html))
	require.NoError(t, err)
	assert.Len(t, protests, 1)
	assert.Equal(t, "test-1", protests[0].SourceID)
	assert.Equal(t, "Climate March", protests[0].Title)
	assert.Equal(t, 45.5, protests[0].Lat)
	assert.Equal(t, -122.6, protests[0].Lng)
	assert.Equal(t, "Climate Action", protests[0].Organizer)
	assert.Contains(t, protests[0].Causes, "Climate Change")
}

func TestParseNextData_SkipsEventsWithoutCoords(t *testing.T) {
	nextData := map[string]interface{}{
		"props": map[string]interface{}{
			"pageProps": map[string]interface{}{
				"events": []map[string]interface{}{
					{"_id": "no-coords", "title": "Online Rally"},
				},
			},
		},
	}

	jsonBytes, _ := json.Marshal(nextData)
	html := fmt.Sprintf(`<html><script id="__NEXT_DATA__" type="application/json">%s</script></html>`, string(jsonBytes))

	protests, err := parseNextData([]byte(html))
	require.NoError(t, err)
	assert.Empty(t, protests)
}

func TestParseNextData_MissingScript(t *testing.T) {
	_, err := parseNextData([]byte(`<html><body>No data here</body></html>`))
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "__NEXT_DATA__")
}

func TestResolveStartTime_FixedDate(t *testing.T) {
	now := time.Date(2026, 4, 10, 12, 0, 0, 0, time.UTC)
	p := scrapedProtest{
		Date: "2026-04-20",
		Time: "14:30",
	}

	result := resolveStartTime(p, now)
	assert.Equal(t, 2026, result.Year())
	assert.Equal(t, time.April, result.Month())
	assert.Equal(t, 20, result.Day())
	assert.Equal(t, 14, result.Hour())
	assert.Equal(t, 30, result.Minute())
}

func TestResolveStartTime_PastDate(t *testing.T) {
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	p := scrapedProtest{
		Date: "2026-04-01",
		Time: "10:00",
	}

	result := resolveStartTime(p, now)
	assert.True(t, result.IsZero(), "past events should return zero time")
}

func TestResolveStartTime_RecurringSaturday(t *testing.T) {
	// Wednesday April 15, 2026
	now := time.Date(2026, 4, 15, 12, 0, 0, 0, time.UTC)
	p := scrapedProtest{
		Recurrent: true,
		RecurDay:  "Saturday",
		Time:      "14:00",
	}

	result := resolveStartTime(p, now)
	assert.False(t, result.IsZero())
	assert.Equal(t, time.Saturday, result.Weekday())
	assert.Equal(t, 14, result.Hour())
	// Next Saturday after Wed Apr 15 is Apr 18
	assert.Equal(t, 18, result.Day())
}

func TestResolveStartTime_RecurringToday(t *testing.T) {
	// Saturday April 18, 2026 at 10 AM — recurring Saturday at 2 PM should be today
	now := time.Date(2026, 4, 18, 10, 0, 0, 0, time.UTC)
	p := scrapedProtest{
		Recurrent: true,
		RecurDay:  "Saturday",
		Time:      "14:00",
	}

	result := resolveStartTime(p, now)
	assert.Equal(t, 18, result.Day(), "should be today since the event hasn't happened yet")
}

func TestResolveStartTime_RecurringTodayPast(t *testing.T) {
	// Saturday April 18, 2026 at 5 PM — recurring Saturday at 2 PM should be next week
	now := time.Date(2026, 4, 18, 17, 0, 0, 0, time.UTC)
	p := scrapedProtest{
		Recurrent: true,
		RecurDay:  "Saturday",
		Time:      "14:00",
	}

	result := resolveStartTime(p, now)
	assert.Equal(t, 25, result.Day(), "should be next Saturday since today's already passed")
}

func TestResolveStartTime_NoDateNoRecurrence(t *testing.T) {
	now := time.Now().UTC()
	p := scrapedProtest{
		Title: "No date info",
	}
	result := resolveStartTime(p, now)
	assert.True(t, result.IsZero())
}

func TestParseTime_Valid(t *testing.T) {
	h, m := parseTime("14:30")
	assert.Equal(t, 14, h)
	assert.Equal(t, 30, m)
}

func TestParseTime_Invalid(t *testing.T) {
	h, m := parseTime("noon")
	assert.Equal(t, 12, h)
	assert.Equal(t, 0, m)
}

func TestParseDayOfWeek(t *testing.T) {
	tests := []struct {
		input    string
		expected time.Weekday
	}{
		{"Monday", time.Monday},
		{"friday", time.Friday},
		{"Saturday", time.Saturday},
		{"SUNDAY", time.Sunday},
		{"invalid", -1},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			assert.Equal(t, tt.expected, parseDayOfWeek(tt.input))
		})
	}
}

func TestFormatLocationArea(t *testing.T) {
	assert.Equal(t, "Portland, OR", formatLocationArea("Portland", "OR", "United States"))
	assert.Equal(t, "Vancouver, BC, Canada", formatLocationArea("Vancouver", "BC", "Canada"))
	assert.Equal(t, "Portland, OR", formatLocationArea("Portland", "OR", "US"))
	assert.Equal(t, "OR", formatLocationArea("", "OR", "United States"))
	assert.Equal(t, "", formatLocationArea("", "", ""))
}

func TestProtestBot_NextRunTime(t *testing.T) {
	bot := &ProtestBot{}

	// At 3 AM, next run should be 7 AM same day
	at3am := time.Date(2026, 4, 15, 3, 0, 0, 0, time.UTC)
	next := bot.nextRunTime(at3am)
	assert.Equal(t, 7, next.Hour())
	assert.Equal(t, 15, next.Day())

	// At 10 AM, next run should be 5 PM same day
	at10am := time.Date(2026, 4, 15, 10, 0, 0, 0, time.UTC)
	next = bot.nextRunTime(at10am)
	assert.Equal(t, 17, next.Hour())
	assert.Equal(t, 15, next.Day())

	// At 9 PM, next run should be 7 AM next day
	at9pm := time.Date(2026, 4, 15, 21, 0, 0, 0, time.UTC)
	next = bot.nextRunTime(at9pm)
	assert.Equal(t, 7, next.Hour())
	assert.Equal(t, 16, next.Day())
}

func TestParseProtestEvent_FullEvent(t *testing.T) {
	raw := json.RawMessage(`{
		"_id": "abc123",
		"title": "March for Justice",
		"date": "2026-05-01",
		"time": "10:00",
		"location": "Downtown Square",
		"city": "Seattle",
		"state": "WA",
		"country": "United States",
		"coords": {"_type": "geopoint", "lat": 47.6, "lng": -122.3},
		"organiser": "Justice Coalition",
		"recurrent": "No",
		"online": "No",
		"cause": [{"label": "Human Rights", "value": "human-rights"}],
		"eventTags": [{"label": "Protest", "value": "protest"}]
	}`)

	p, err := parseProtestEvent(raw)
	require.NoError(t, err)
	assert.Equal(t, "abc123", p.SourceID)
	assert.Equal(t, "March for Justice", p.Title)
	assert.Equal(t, "Seattle", p.City)
	assert.Equal(t, 47.6, p.Lat)
	assert.Equal(t, -122.3, p.Lng)
	assert.Equal(t, "Justice Coalition", p.Organizer)
	assert.False(t, p.Recurrent)
	assert.Contains(t, p.Causes, "Human Rights")
	assert.Contains(t, p.EventTags, "Protest")
}

func TestParseProtestEvent_EmptyTitle(t *testing.T) {
	raw := json.RawMessage(`{"_id": "xyz", "title": ""}`)
	_, err := parseProtestEvent(raw)
	assert.Error(t, err)
}
