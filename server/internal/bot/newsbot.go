package bot

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/kuurier/server/internal/storage"
)

// NewsBot aggregates RSS news and posts them to the Kuurier feed
// on a configurable schedule (default: twice daily at 8 AM and 6 PM).
type NewsBot struct {
	db       *storage.Postgres
	client   *http.Client
	sources  []RSSSource
	stopCh   chan struct{}
	morningH int // hour (0-23) for morning run
	eveningH int // hour (0-23) for evening run
}

// NewNewsBot creates a new news bot instance.
func NewNewsBot(db *storage.Postgres) *NewsBot {
	return &NewsBot{
		db: db,
		client: &http.Client{
			Timeout: 15 * time.Second,
		},
		sources:  NewsSources(),
		stopCh:   make(chan struct{}),
		morningH: 8,  // 8 AM UTC
		eveningH: 18, // 6 PM UTC
	}
}

// Start begins the bot's scheduled loop. It runs the first aggregation
// immediately, then twice daily at the configured hours.
// Call Stop() to shut it down gracefully.
func (b *NewsBot) Start() {
	log.Println("[newsbot] Starting news aggregation bot (schedule: 08:00 and 18:00 UTC)")

	// Run immediately on startup to populate the feed. Panics here must
	// not bring down the process — if RSS parsing blows up on one source
	// we still want the scheduler to keep running.
	go func() {
		if err := safeRun(context.Background(), "newsbot", b.RunOnce); err != nil {
			log.Printf("[newsbot] Initial run failed: %v", err)
		}
	}()

	go b.scheduleLoop()
}

// Stop signals the bot to stop.
func (b *NewsBot) Stop() {
	close(b.stopCh)
}

// scheduleLoop runs the bot at the configured hours. A panic inside
// RunOnce is caught by safeRun so the next scheduled tick still fires.
func (b *NewsBot) scheduleLoop() {
	for {
		now := time.Now().UTC()
		nextRun := b.nextRunTime(now)
		wait := time.Until(nextRun)

		log.Printf("[newsbot] Next run scheduled at %s (in %s)", nextRun.Format(time.RFC3339), wait.Round(time.Second))

		select {
		case <-time.After(wait):
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
			if err := safeRun(ctx, "newsbot", b.RunOnce); err != nil {
				log.Printf("[newsbot] Scheduled run failed: %v", err)
			}
			cancel()
		case <-b.stopCh:
			log.Println("[newsbot] Shutting down")
			return
		}
	}
}

// nextRunTime calculates the next 8 AM or 6 PM UTC after `now`.
func (b *NewsBot) nextRunTime(now time.Time) time.Time {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)

	morning := today.Add(time.Duration(b.morningH) * time.Hour)
	evening := today.Add(time.Duration(b.eveningH) * time.Hour)

	// Find the soonest future run
	candidates := []time.Time{morning, evening, morning.Add(24 * time.Hour), evening.Add(24 * time.Hour)}
	for _, t := range candidates {
		if t.After(now) {
			return t
		}
	}
	return morning.Add(24 * time.Hour) // fallback
}

// RunOnce performs a single aggregation run: fetch RSS → deduplicate → post.
func (b *NewsBot) RunOnce(ctx context.Context) error {
	runID := uuid.New().String()
	log.Printf("[newsbot] Starting run %s", runID)

	// Log the run
	_, err := b.db.Pool().Exec(ctx,
		`INSERT INTO bot_run_log (id, run_type, started_at, status) VALUES ($1, 'news_aggregation', NOW(), 'running')`,
		runID,
	)
	if err != nil {
		log.Printf("[newsbot] Failed to log run start: %v", err)
	}

	// Fetch articles from all sources concurrently
	articles, fetchErrors := b.fetchAllSources(ctx)
	log.Printf("[newsbot] Fetched %d articles from %d sources (%d errors)", len(articles), len(b.sources), len(fetchErrors))

	// Deduplicate against already-posted articles
	newArticles, err := b.filterAlreadyPosted(ctx, articles)
	if err != nil {
		b.logRunComplete(ctx, runID, len(articles), 0, append(fetchErrors, err.Error()), "failed")
		return fmt.Errorf("dedup check failed: %w", err)
	}
	log.Printf("[newsbot] %d new articles after dedup", len(newArticles))

	// Sort by publish date (newest first) and limit
	sort.Slice(newArticles, func(i, j int) bool {
		return newArticles[i].PublishedAt.After(newArticles[j].PublishedAt)
	})
	if len(newArticles) > MaxPostsPerRun {
		newArticles = newArticles[:MaxPostsPerRun]
	}

	// Create posts for each article
	posted := 0
	var postErrors []string
	for _, article := range newArticles {
		if err := b.createPost(ctx, article); err != nil {
			postErrors = append(postErrors, fmt.Sprintf("post %q: %v", article.Title, err))
			continue
		}
		posted++
	}

	allErrors := append(fetchErrors, postErrors...)
	status := "completed"
	if posted == 0 && len(newArticles) > 0 {
		status = "failed"
	}

	b.logRunComplete(ctx, runID, len(articles), posted, allErrors, status)
	log.Printf("[newsbot] Run %s complete: %d/%d articles posted", runID, posted, len(newArticles))
	return nil
}

// rssArticle is an intermediate type for fetched articles before posting.
type rssArticle struct {
	Title       string
	Description string
	Link        string
	SourceName  string
	Category    string
	TopicIDs    []string
	PublishedAt time.Time
	ImageURL    string
}

// fetchAllSources fetches all configured RSS sources concurrently.
func (b *NewsBot) fetchAllSources(ctx context.Context) ([]rssArticle, []string) {
	var mu sync.Mutex
	var wg sync.WaitGroup
	var allArticles []rssArticle
	var errors []string

	for _, src := range b.sources {
		wg.Add(1)
		go func(s RSSSource) {
			defer wg.Done()

			articles, err := b.fetchSource(ctx, s)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", s.Name, err))
				return
			}
			allArticles = append(allArticles, articles...)
		}(src)
	}

	wg.Wait()
	return allArticles, errors
}

// fetchSource fetches and parses a single RSS feed.
func (b *NewsBot) fetchSource(ctx context.Context, src RSSSource) ([]rssArticle, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", src.URL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Kuurier-NewsBot/1.0")

	resp, err := b.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024)) // 2MB limit
	if err != nil {
		return nil, err
	}

	var feed rssFeed
	if err := xml.Unmarshal(body, &feed); err != nil {
		return nil, fmt.Errorf("XML parse: %w", err)
	}

	var articles []rssArticle
	for i, item := range feed.Channel.Items {
		if i >= 8 { // max 8 per source per run
			break
		}

		pubDate := parseDate(item.PubDate)

		// Skip articles older than 24 hours (only fresh news)
		if time.Since(pubDate) > 24*time.Hour {
			continue
		}

		desc := stripHTML(item.Description)
		if len(desc) > 280 {
			desc = desc[:277] + "..."
		}

		imageURL := item.Enclosure.URL
		if imageURL == "" {
			imageURL = item.MediaContent.URL
		}

		articles = append(articles, rssArticle{
			Title:       strings.TrimSpace(item.Title),
			Description: desc,
			Link:        strings.TrimSpace(item.Link),
			SourceName:  src.Name,
			Category:    src.Category,
			TopicIDs:    src.TopicIDs,
			PublishedAt: pubDate,
			ImageURL:    imageURL,
		})
	}

	return articles, nil
}

// filterAlreadyPosted removes articles whose URLs have already been posted.
func (b *NewsBot) filterAlreadyPosted(ctx context.Context, articles []rssArticle) ([]rssArticle, error) {
	if len(articles) == 0 {
		return nil, nil
	}

	// Collect all URLs
	urls := make([]string, len(articles))
	for i, a := range articles {
		urls[i] = a.Link
	}

	// Query which URLs already exist
	rows, err := b.db.Pool().Query(ctx,
		`SELECT article_url FROM bot_posted_articles WHERE article_url = ANY($1)`,
		urls,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	posted := make(map[string]bool)
	for rows.Next() {
		var url string
		if err := rows.Scan(&url); err == nil {
			posted[url] = true
		}
	}

	var newArticles []rssArticle
	for _, a := range articles {
		if !posted[a.Link] {
			newArticles = append(newArticles, a)
		}
	}

	return newArticles, nil
}

// createPost creates a feed post from an RSS article.
func (b *NewsBot) createPost(ctx context.Context, article rssArticle) error {
	postID := uuid.New().String()

	// Build post content: headline + summary + source link
	content := fmt.Sprintf("📰 %s\n\n%s\n\n🔗 %s — via %s",
		article.Title,
		article.Description,
		article.Link,
		article.SourceName,
	)

	if len(content) > 2000 {
		content = content[:1997] + "..."
	}

	// Insert the post
	_, err := b.db.Pool().Exec(ctx,
		`INSERT INTO posts (id, author_id, content, source_type, urgency, created_at, verification_score)
		 VALUES ($1, $2, $3, 'mainstream', 1, $4, 50)`,
		postID, BotUserID, content, article.PublishedAt,
	)
	if err != nil {
		return fmt.Errorf("insert post: %w", err)
	}

	// Attach topic associations if the source has mapped topics
	for _, topicID := range article.TopicIDs {
		_, _ = b.db.Pool().Exec(ctx,
			`INSERT INTO post_topics (post_id, topic_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
			postID, topicID,
		)
	}

	// Also try to auto-tag based on content keywords
	b.autoTagPost(ctx, postID, article)

	// Record that we posted this article
	_, err = b.db.Pool().Exec(ctx,
		`INSERT INTO bot_posted_articles (article_url, article_title, post_id, source_name, posted_at)
		 VALUES ($1, $2, $3, $4, NOW())
		 ON CONFLICT (article_url) DO NOTHING`,
		article.Link, article.Title, postID, article.SourceName,
	)
	if err != nil {
		log.Printf("[newsbot] Warning: failed to record posted article: %v", err)
	}

	return nil
}

// autoTagPost applies topic tags based on keyword matching in the title/description.
func (b *NewsBot) autoTagPost(ctx context.Context, postID string, article rssArticle) {
	text := strings.ToLower(article.Title + " " + article.Description)

	topicKeywords := map[string][]string{
		"climate":          {"climate", "carbon", "emissions", "global warming", "fossil fuel", "renewable", "wildfire", "drought"},
		"labor":            {"union", "worker", "strike", "wage", "labor", "labour", "gig economy"},
		"housing":          {"housing", "rent", "eviction", "homeless", "affordable housing", "tenant"},
		"healthcare":       {"healthcare", "health care", "medicaid", "medicare", "insurance", "hospital"},
		"education":        {"education", "school", "student", "university", "college", "teacher"},
		"immigration":      {"immigration", "immigrant", "migrant", "border", "asylum", "refugee", "deportation"},
		"police-reform":    {"police", "policing", "brutality", "accountability", "body camera", "use of force"},
		"voting-rights":    {"voting", "election", "ballot", "gerrymandering", "voter suppression", "democracy"},
		"lgbtq":            {"lgbtq", "lgbt", "transgender", "queer", "pride", "same-sex", "nonbinary"},
		"racial-justice":   {"racial", "racism", "discrimination", "equity", "civil rights", "hate crime"},
		"womens-rights":    {"women", "abortion", "reproductive", "gender equality", "title ix"},
		"disability-rights": {"disability", "disabled", "accessibility", "ada ", "ableism"},
		"indigenous":       {"indigenous", "native american", "tribal", "sovereignty"},
		"peace":            {"peace", "war", "conflict", "ceasefire", "diplomacy", "sanctions"},
		"mutual-aid":       {"mutual aid", "community", "solidarity", "volunteer", "donation drive"},
	}

	for topicID, keywords := range topicKeywords {
		for _, kw := range keywords {
			if strings.Contains(text, kw) {
				_, _ = b.db.Pool().Exec(ctx,
					`INSERT INTO post_topics (post_id, topic_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
					postID, topicID,
				)
				break
			}
		}
	}
}

// logRunComplete records the final state of a bot run.
func (b *NewsBot) logRunComplete(ctx context.Context, runID string, fetched, posted int, errors []string, status string) {
	_, err := b.db.Pool().Exec(ctx,
		`UPDATE bot_run_log
		 SET completed_at = NOW(), articles_fetched = $2, articles_posted = $3, errors = $4, status = $5
		 WHERE id = $1`,
		runID, fetched, posted, errors, status,
	)
	if err != nil {
		log.Printf("[newsbot] Failed to log run completion: %v", err)
	}
}

// ── RSS XML structures ─────────────────────────────────────────────────

type rssFeed struct {
	XMLName xml.Name   `xml:"rss"`
	Channel rssChannel `xml:"channel"`
}

type rssChannel struct {
	Items []rssItem `xml:"item"`
}

type rssItem struct {
	Title       string `xml:"title"`
	Link        string `xml:"link"`
	Description string `xml:"description"`
	PubDate     string `xml:"pubDate"`
	Enclosure   struct {
		URL  string `xml:"url,attr"`
		Type string `xml:"type,attr"`
	} `xml:"enclosure"`
	MediaContent struct {
		URL string `xml:"url,attr"`
	} `xml:"http://search.yahoo.com/mrss/ content"`
}

// ── Helpers ─────────────────────────────────────────────────────────────

func parseDate(s string) time.Time {
	formats := []string{
		time.RFC1123Z, time.RFC1123, time.RFC822Z, time.RFC822,
		"Mon, 02 Jan 2006 15:04:05 -0700",
		"Mon, 02 Jan 2006 15:04:05 MST",
		"2006-01-02T15:04:05Z",
		"2006-01-02T15:04:05-07:00",
	}
	for _, f := range formats {
		if t, err := time.Parse(f, s); err == nil {
			return t
		}
	}
	return time.Now().UTC()
}

func stripHTML(s string) string {
	var b strings.Builder
	inTag := false
	for _, r := range s {
		switch {
		case r == '<':
			inTag = true
		case r == '>':
			inTag = false
		case !inTag:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}
