package bot

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/kuurier/server/internal/storage"
)

// ProtestBot scrapes findaprotest.info and creates events in the Kuurier events table.
type ProtestBot struct {
	db     *storage.Postgres
	client *http.Client
	stopCh chan struct{}
	mu     sync.Mutex
}

const (
	findAProtestURL     = "https://www.findaprotest.info"
	maxEventsPerRun     = 50
	protestBotRunType   = "protest_scrape"
)

// NewProtestBot creates a new protest scraper bot instance.
func NewProtestBot(db *storage.Postgres) *ProtestBot {
	return &ProtestBot{
		db: db,
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
		stopCh: make(chan struct{}),
	}
}

// Start begins the bot's scheduled loop.
// Runs immediately on startup, then twice daily at 7 AM and 5 PM UTC.
// A panic in RunOnce is caught by safeRun so the scheduler survives
// malformed findaprotest.info payloads and keeps ticking.
func (b *ProtestBot) Start() {
	log.Println("[protestbot] Starting protest scraper bot (schedule: 07:00 and 17:00 UTC)")

	go func() {
		if err := safeRun(context.Background(), "protestbot", b.RunOnce); err != nil {
			log.Printf("[protestbot] Initial run failed: %v", err)
		}
	}()

	go b.scheduleLoop()
}

// Stop signals the bot to stop.
func (b *ProtestBot) Stop() {
	close(b.stopCh)
}

func (b *ProtestBot) scheduleLoop() {
	for {
		now := time.Now().UTC()
		nextRun := b.nextRunTime(now)
		wait := time.Until(nextRun)

		log.Printf("[protestbot] Next run scheduled at %s (in %s)", nextRun.Format(time.RFC3339), wait.Round(time.Second))

		select {
		case <-time.After(wait):
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
			if err := safeRun(ctx, "protestbot", b.RunOnce); err != nil {
				log.Printf("[protestbot] Scheduled run failed: %v", err)
			}
			cancel()
		case <-b.stopCh:
			log.Println("[protestbot] Shutting down")
			return
		}
	}
}

func (b *ProtestBot) nextRunTime(now time.Time) time.Time {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)

	morning := today.Add(7 * time.Hour)  // 7 AM UTC
	evening := today.Add(17 * time.Hour) // 5 PM UTC

	candidates := []time.Time{morning, evening, morning.Add(24 * time.Hour), evening.Add(24 * time.Hour)}
	for _, t := range candidates {
		if t.After(now) {
			return t
		}
	}
	return morning.Add(24 * time.Hour)
}

// RunOnce performs a single scrape: fetch page → parse JSON → deduplicate → create events.
func (b *ProtestBot) RunOnce(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	runID := uuid.New().String()
	log.Printf("[protestbot] Starting run %s", runID)

	_, _ = b.db.Pool().Exec(ctx,
		`INSERT INTO bot_run_log (id, run_type, started_at, status) VALUES ($1, $2, NOW(), 'running')`,
		runID, protestBotRunType,
	)

	// 1. Fetch and parse the page
	protests, err := b.fetchProtests(ctx)
	if err != nil {
		b.logRunComplete(ctx, runID, 0, 0, []string{err.Error()}, "failed")
		return fmt.Errorf("fetch protests: %w", err)
	}
	log.Printf("[protestbot] Parsed %d protests from findaprotest.info", len(protests))

	// 2. Filter to future events only and resolve recurring dates
	upcoming := b.resolveUpcoming(protests)
	log.Printf("[protestbot] %d upcoming protests after date resolution", len(upcoming))

	// 3. Deduplicate against already-scraped events
	newEvents, err := b.filterAlreadyScraped(ctx, upcoming)
	if err != nil {
		b.logRunComplete(ctx, runID, len(upcoming), 0, []string{err.Error()}, "failed")
		return fmt.Errorf("dedup check: %w", err)
	}
	log.Printf("[protestbot] %d new protests after dedup", len(newEvents))

	// Sort by date (soonest first) and cap
	sort.Slice(newEvents, func(i, j int) bool {
		return newEvents[i].StartsAt.Before(newEvents[j].StartsAt)
	})
	if len(newEvents) > maxEventsPerRun {
		newEvents = newEvents[:maxEventsPerRun]
	}

	// 4. Create events
	created := 0
	var postErrors []string
	for _, p := range newEvents {
		if err := b.createEvent(ctx, p); err != nil {
			postErrors = append(postErrors, fmt.Sprintf("%q: %v", p.Title, err))
			continue
		}
		created++
	}

	status := "completed"
	if created == 0 && len(newEvents) > 0 {
		status = "failed"
	}

	b.logRunComplete(ctx, runID, len(upcoming), created, postErrors, status)
	log.Printf("[protestbot] Run %s complete: %d/%d events created", runID, created, len(newEvents))
	return nil
}

// ── Fetch & parse ──────────────────────────────────────────────────────

// scrapedProtest is the intermediate parsed representation.
type scrapedProtest struct {
	SourceID    string
	Title       string
	Date        string // YYYY-MM-DD or empty for recurring-only
	Time        string // HH:MM
	Timezone    string
	Location    string
	City        string
	State       string
	Country     string
	Lat         float64
	Lng         float64
	Organizer   string
	Recurrent   bool
	RecurDay    string // e.g. "Saturday"
	Causes      []string
	EventTags   []string
	StartsAt    time.Time // resolved absolute time
	OnlineLink  string
}

// nextDataRegex matches the __NEXT_DATA__ script tag content.
var nextDataRegex = regexp.MustCompile(`<script id="__NEXT_DATA__" type="application/json">(.*?)</script>`)

func (b *ProtestBot) fetchProtests(ctx context.Context) ([]scrapedProtest, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", findAProtestURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Kuurier-ProtestBot/1.0")

	resp, err := b.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 5*1024*1024)) // 5MB limit
	if err != nil {
		return nil, err
	}

	return parseNextData(body)
}

// parseNextData extracts protest events from the __NEXT_DATA__ JSON blob.
func parseNextData(html []byte) ([]scrapedProtest, error) {
	matches := nextDataRegex.FindSubmatch(html)
	if len(matches) < 2 {
		return nil, fmt.Errorf("__NEXT_DATA__ script tag not found")
	}

	// The structure is: { props: { pageProps: { events: [...] } } }
	// We use a flexible approach to find the events array.
	var root map[string]json.RawMessage
	if err := json.Unmarshal(matches[1], &root); err != nil {
		return nil, fmt.Errorf("parse root JSON: %w", err)
	}

	propsRaw, ok := root["props"]
	if !ok {
		return nil, fmt.Errorf("missing 'props' key")
	}

	var props map[string]json.RawMessage
	if err := json.Unmarshal(propsRaw, &props); err != nil {
		return nil, fmt.Errorf("parse props: %w", err)
	}

	pagePropsRaw, ok := props["pageProps"]
	if !ok {
		return nil, fmt.Errorf("missing 'pageProps' key")
	}

	var pageProps map[string]json.RawMessage
	if err := json.Unmarshal(pagePropsRaw, &pageProps); err != nil {
		return nil, fmt.Errorf("parse pageProps: %w", err)
	}

	// Try common key names for the events array
	var eventsRaw json.RawMessage
	for _, key := range []string{"events", "protests", "items", "data"} {
		if raw, found := pageProps[key]; found {
			eventsRaw = raw
			break
		}
	}
	if eventsRaw == nil {
		// Fallback: look for any array in pageProps
		for _, v := range pageProps {
			trimmed := strings.TrimSpace(string(v))
			if len(trimmed) > 0 && trimmed[0] == '[' {
				eventsRaw = v
				break
			}
		}
	}
	if eventsRaw == nil {
		return nil, fmt.Errorf("no events array found in pageProps")
	}

	var rawEvents []json.RawMessage
	if err := json.Unmarshal(eventsRaw, &rawEvents); err != nil {
		return nil, fmt.Errorf("parse events array: %w", err)
	}

	var protests []scrapedProtest
	for _, raw := range rawEvents {
		p, err := parseProtestEvent(raw)
		if err != nil {
			continue // skip unparseable events
		}
		if p.Lat == 0 && p.Lng == 0 {
			continue // skip events without coordinates
		}
		protests = append(protests, p)
	}

	return protests, nil
}

// findAProtestEvent mirrors the JSON shape from the site.
type findAProtestEvent struct {
	ID        string `json:"_id"`
	Title     string `json:"title"`
	Date      string `json:"date"` // "YYYY-MM-DD" or null
	Time      string `json:"time"` // "HH:MM"
	Timezone  string `json:"timezone"`
	Location  string `json:"location"`
	City      string `json:"city"`
	State     string `json:"state"`
	Country   string `json:"country"`
	Coords    *struct {
		Lat float64 `json:"lat"`
		Lng float64 `json:"lng"`
	} `json:"coords"`
	Organiser string `json:"organiser"`
	Online    string `json:"online"`    // "Yes" / "No"
	OnlineLink string `json:"onlineLink"`
	Recurrent string `json:"recurrent"` // "Yes" / "No"
	Every     string `json:"every"`     // "Friday", "Saturday", etc.
	EventTags []struct {
		Label string `json:"label"`
		Value string `json:"value"`
	} `json:"eventTags"`
	Cause []struct {
		Label string `json:"label"`
		Value string `json:"value"`
	} `json:"cause"`
}

func parseProtestEvent(raw json.RawMessage) (scrapedProtest, error) {
	var e findAProtestEvent
	if err := json.Unmarshal(raw, &e); err != nil {
		return scrapedProtest{}, err
	}

	if e.Title == "" {
		return scrapedProtest{}, fmt.Errorf("empty title")
	}

	p := scrapedProtest{
		SourceID:  e.ID,
		Title:     e.Title,
		Date:      e.Date,
		Time:      e.Time,
		Timezone:  e.Timezone,
		Location:  e.Location,
		City:      e.City,
		State:     e.State,
		Country:   e.Country,
		Organizer: e.Organiser,
		Recurrent: strings.EqualFold(e.Recurrent, "Yes"),
		RecurDay:  e.Every,
		OnlineLink: e.OnlineLink,
	}

	if e.Coords != nil {
		p.Lat = e.Coords.Lat
		p.Lng = e.Coords.Lng
	}

	for _, t := range e.EventTags {
		p.EventTags = append(p.EventTags, t.Label)
	}
	for _, c := range e.Cause {
		p.Causes = append(p.Causes, c.Label)
	}

	return p, nil
}

// ── Date resolution ────────────────────────────────────────────────────

// resolveUpcoming converts raw scraped data into events with concrete start times.
// For recurring events, it computes the next occurrence.
// Skips events that are in the past.
func (b *ProtestBot) resolveUpcoming(protests []scrapedProtest) []scrapedProtest {
	now := time.Now().UTC()
	var upcoming []scrapedProtest

	for _, p := range protests {
		resolved := resolveStartTime(p, now)
		if resolved.IsZero() {
			continue
		}
		// Only include events up to 30 days out
		if resolved.After(now.Add(30 * 24 * time.Hour)) {
			continue
		}
		p.StartsAt = resolved
		upcoming = append(upcoming, p)
	}

	return upcoming
}

// resolveStartTime computes the absolute start time for an event.
func resolveStartTime(p scrapedProtest, now time.Time) time.Time {
	hour, minute := parseTime(p.Time)

	// Non-recurring with a specific date
	if p.Date != "" {
		t, err := time.Parse("2006-01-02", p.Date)
		if err == nil {
			startsAt := time.Date(t.Year(), t.Month(), t.Day(), hour, minute, 0, 0, time.UTC)
			if startsAt.After(now.Add(-2 * time.Hour)) { // allow 2h grace for timezone differences
				return startsAt
			}
			return time.Time{} // past event
		}
	}

	// Recurring: find the next occurrence of the given weekday
	if p.Recurrent && p.RecurDay != "" {
		targetDay := parseDayOfWeek(p.RecurDay)
		if targetDay < 0 {
			return time.Time{}
		}

		// Find the next occurrence (today or later)
		candidate := time.Date(now.Year(), now.Month(), now.Day(), hour, minute, 0, 0, time.UTC)
		daysUntil := (int(targetDay) - int(candidate.Weekday()) + 7) % 7
		if daysUntil == 0 && candidate.Before(now) {
			daysUntil = 7
		}
		return candidate.Add(time.Duration(daysUntil) * 24 * time.Hour)
	}

	return time.Time{}
}

func parseTime(s string) (int, int) {
	var h, m int
	if _, err := fmt.Sscanf(s, "%d:%d", &h, &m); err != nil {
		return 12, 0 // default to noon
	}
	return h, m
}

func parseDayOfWeek(s string) time.Weekday {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "sunday":
		return time.Sunday
	case "monday":
		return time.Monday
	case "tuesday":
		return time.Tuesday
	case "wednesday":
		return time.Wednesday
	case "thursday":
		return time.Thursday
	case "friday":
		return time.Friday
	case "saturday":
		return time.Saturday
	default:
		return -1
	}
}

// ── Deduplication ──────────────────────────────────────────────────────

func (b *ProtestBot) filterAlreadyScraped(ctx context.Context, protests []scrapedProtest) ([]scrapedProtest, error) {
	if len(protests) == 0 {
		return nil, nil
	}

	ids := make([]string, len(protests))
	for i, p := range protests {
		ids[i] = p.SourceID
	}

	rows, err := b.db.Pool().Query(ctx,
		`SELECT source_id FROM bot_scraped_events WHERE source_id = ANY($1)`,
		ids,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	existing := make(map[string]bool)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err == nil {
			existing[id] = true
		}
	}

	var newProtests []scrapedProtest
	for _, p := range protests {
		if !existing[p.SourceID] {
			newProtests = append(newProtests, p)
		}
	}

	return newProtests, nil
}

// ── Event creation ─────────────────────────────────────────────────────

func (b *ProtestBot) createEvent(ctx context.Context, p scrapedProtest) error {
	eventID := uuid.New().String()

	// Build description
	var desc strings.Builder
	if p.Organizer != "" {
		desc.WriteString("Organized by: ")
		desc.WriteString(p.Organizer)
		desc.WriteString("\n\n")
	}
	if len(p.Causes) > 0 {
		desc.WriteString("Causes: ")
		desc.WriteString(strings.Join(p.Causes, ", "))
		desc.WriteString("\n")
	}
	if len(p.EventTags) > 0 {
		desc.WriteString("Tags: ")
		desc.WriteString(strings.Join(p.EventTags, ", "))
		desc.WriteString("\n")
	}
	if p.Recurrent {
		desc.WriteString(fmt.Sprintf("\nRecurring every %s", p.RecurDay))
	}
	if p.OnlineLink != "" {
		desc.WriteString(fmt.Sprintf("\n\nOnline: %s", p.OnlineLink))
	}
	desc.WriteString("\n\nSource: findaprotest.info")

	// Build location name
	locationName := p.Location
	if locationName == "" {
		parts := []string{}
		if p.City != "" {
			parts = append(parts, p.City)
		}
		if p.State != "" {
			parts = append(parts, p.State)
		}
		if p.Country != "" {
			parts = append(parts, p.Country)
		}
		locationName = strings.Join(parts, ", ")
	}

	locationSQL := fmt.Sprintf("SRID=4326;POINT(%f %f)", p.Lng, p.Lat)

	// Insert event — bot user is the organizer, location is always public
	_, err := b.db.Pool().Exec(ctx,
		`INSERT INTO events (id, organizer_id, title, description, event_type, location, location_name,
		                     location_area, location_visibility, starts_at)
		 VALUES ($1, $2, $3, $4, 'protest', ST_GeogFromText($5), $6, $7, 'public', $8)`,
		eventID, BotUserID, p.Title, desc.String(), locationSQL, locationName,
		formatLocationArea(p.City, p.State, p.Country), p.StartsAt,
	)
	if err != nil {
		return fmt.Errorf("insert event: %w", err)
	}

	// Auto-tag with topics based on causes
	b.autoTagEvent(ctx, eventID, p)

	// Record that we scraped this event
	_, err = b.db.Pool().Exec(ctx,
		`INSERT INTO bot_scraped_events (source_id, event_id, title, scraped_at)
		 VALUES ($1, $2, $3, NOW())
		 ON CONFLICT (source_id) DO NOTHING`,
		p.SourceID, eventID, p.Title,
	)
	if err != nil {
		log.Printf("[protestbot] Warning: failed to record scraped event: %v", err)
	}

	return nil
}

func formatLocationArea(city, state, country string) string {
	parts := []string{}
	if city != "" {
		parts = append(parts, city)
	}
	if state != "" {
		parts = append(parts, state)
	}
	if country != "" && country != "United States" && country != "US" {
		parts = append(parts, country)
	}
	return strings.Join(parts, ", ")
}

// autoTagEvent maps findaprotest.info causes to Kuurier topic IDs.
func (b *ProtestBot) autoTagEvent(ctx context.Context, eventID string, p scrapedProtest) {
	causeToTopics := map[string][]string{
		"palestine":        {"peace"},
		"defend democracy": {"voting-rights"},
		"anti-war":         {"peace"},
		"workers' rights":  {"labor"},
		"climate change":   {"climate"},
		"human rights":     {"racial-justice"},
		"anti-fascism":     {"racial-justice"},
		"immigrant rights": {"immigration"},
		"civil rights":     {"racial-justice"},
		"lgbtq+":           {"lgbtq"},
		"women's rights":   {"womens-rights"},
		"racial justice":   {"racial-justice"},
		"housing":          {"housing"},
		"healthcare":       {"healthcare"},
		"education":        {"education"},
		"disability rights": {"disability-rights"},
		"indigenous rights": {"indigenous"},
	}

	tagged := make(map[string]bool)
	for _, cause := range p.Causes {
		if topicIDs, ok := causeToTopics[strings.ToLower(cause)]; ok {
			for _, tid := range topicIDs {
				if tagged[tid] {
					continue
				}
				tagged[tid] = true
				_, _ = b.db.Pool().Exec(ctx,
					`INSERT INTO event_topics (event_id, topic_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
					eventID, tid,
				)
			}
		}
	}
}

func (b *ProtestBot) logRunComplete(ctx context.Context, runID string, fetched, created int, errors []string, status string) {
	_, err := b.db.Pool().Exec(ctx,
		`UPDATE bot_run_log
		 SET completed_at = NOW(), articles_fetched = $2, articles_posted = $3, errors = $4, status = $5
		 WHERE id = $1`,
		runID, fetched, created, errors, status,
	)
	if err != nil {
		log.Printf("[protestbot] Failed to log run completion: %v", err)
	}
}
