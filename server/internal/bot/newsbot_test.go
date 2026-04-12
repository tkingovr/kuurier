package bot

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestParseDate_RFC1123Z(t *testing.T) {
	dateStr := "Mon, 02 Jan 2006 15:04:05 -0700"
	result := parseDate(dateStr)
	assert.Equal(t, 2006, result.Year())
	assert.Equal(t, time.January, result.Month())
	assert.Equal(t, 2, result.Day())
}

func TestParseDate_ISO8601(t *testing.T) {
	dateStr := "2024-06-15T10:30:00Z"
	result := parseDate(dateStr)
	assert.Equal(t, 2024, result.Year())
	assert.Equal(t, time.June, result.Month())
}

func TestParseDate_Invalid(t *testing.T) {
	// Invalid date should fall back to now
	result := parseDate("not a date")
	assert.WithinDuration(t, time.Now().UTC(), result, 2*time.Second)
}

func TestStripHTML_RemovesTags(t *testing.T) {
	input := "<p>Hello <b>world</b></p>"
	assert.Equal(t, "Hello world", stripHTML(input))
}

func TestStripHTML_HandlesEmpty(t *testing.T) {
	assert.Equal(t, "", stripHTML(""))
}

func TestStripHTML_NoTags(t *testing.T) {
	assert.Equal(t, "plain text", stripHTML("plain text"))
}

func TestNewsSources_HasEntries(t *testing.T) {
	sources := NewsSources()
	assert.Greater(t, len(sources), 5, "Should have at least 5 news sources")
}

func TestNewsSources_HasActivistSources(t *testing.T) {
	sources := NewsSources()
	activistCount := 0
	for _, s := range sources {
		switch s.Category {
		case "activism", "climate", "labor":
			activistCount++
		}
	}
	assert.Greater(t, activistCount, 0, "Should have at least one activist source")
}

func TestNewsSources_HasGeneralSources(t *testing.T) {
	sources := NewsSources()
	generalCount := 0
	for _, s := range sources {
		switch s.Category {
		case "general", "world", "breaking", "politics":
			generalCount++
		}
	}
	assert.Greater(t, generalCount, 0, "Should have at least one general news source")
}

func TestNextRunTime_FutureMorning(t *testing.T) {
	bot := &NewsBot{morningH: 8, eveningH: 18}

	// At 3 AM, next run should be 8 AM same day
	at3am := time.Date(2024, 6, 15, 3, 0, 0, 0, time.UTC)
	next := bot.nextRunTime(at3am)
	assert.Equal(t, 8, next.Hour())
	assert.Equal(t, 15, next.Day())
}

func TestNextRunTime_FutureEvening(t *testing.T) {
	bot := &NewsBot{morningH: 8, eveningH: 18}

	// At 10 AM, next run should be 6 PM same day
	at10am := time.Date(2024, 6, 15, 10, 0, 0, 0, time.UTC)
	next := bot.nextRunTime(at10am)
	assert.Equal(t, 18, next.Hour())
	assert.Equal(t, 15, next.Day())
}

func TestNextRunTime_NextDayMorning(t *testing.T) {
	bot := &NewsBot{morningH: 8, eveningH: 18}

	// At 9 PM, next run should be 8 AM next day
	at9pm := time.Date(2024, 6, 15, 21, 0, 0, 0, time.UTC)
	next := bot.nextRunTime(at9pm)
	assert.Equal(t, 8, next.Hour())
	assert.Equal(t, 16, next.Day())
}

func TestBotUserID_Constant(t *testing.T) {
	assert.Equal(t, "00000000-0000-0000-0000-000000000001", BotUserID)
}

func TestMaxPostsPerRun_Reasonable(t *testing.T) {
	assert.LessOrEqual(t, MaxPostsPerRun, 20, "Should not flood the feed")
	assert.GreaterOrEqual(t, MaxPostsPerRun, 5, "Should post enough content to be useful")
}
