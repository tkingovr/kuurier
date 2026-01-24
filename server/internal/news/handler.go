package news

import (
	"encoding/xml"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// Handler handles news-related HTTP requests
type Handler struct {
	cache      []NewsArticle
	cacheMutex sync.RWMutex
	cacheTime  time.Time
	cacheTTL   time.Duration
}

// NewHandler creates a new news handler
func NewHandler() *Handler {
	return &Handler{
		cacheTTL: 15 * time.Minute, // Cache news for 15 minutes
	}
}

// NewsArticle represents a news article from RSS
type NewsArticle struct {
	ID          string    `json:"id"`
	Title       string    `json:"title"`
	Description string    `json:"description"`
	Link        string    `json:"link"`
	Source      string    `json:"source"`
	SourceIcon  string    `json:"source_icon"`
	PublishedAt time.Time `json:"published_at"`
	ImageURL    string    `json:"image_url,omitempty"`
	Category    string    `json:"category"`
	Location    *Location `json:"location,omitempty"`
}

// Location for news articles
type Location struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Name      string  `json:"name,omitempty"`
}

// RSS feed structures
type rssFeed struct {
	XMLName xml.Name   `xml:"rss"`
	Channel rssChannel `xml:"channel"`
}

type rssChannel struct {
	Title       string    `xml:"title"`
	Description string    `xml:"description"`
	Items       []rssItem `xml:"item"`
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

// News sources - RSS feeds focused on social justice, protests, activism
var newsSources = []struct {
	URL      string
	Name     string
	Icon     string
	Category string
}{
	// Major news with social/political focus
	{"https://rss.nytimes.com/services/xml/rss/nyt/Politics.xml", "NY Times", "newspaper", "politics"},
	{"https://feeds.bbci.co.uk/news/world/rss.xml", "BBC News", "globe", "world"},
	{"https://www.theguardian.com/world/rss", "The Guardian", "book", "world"},
	{"https://feeds.npr.org/1001/rss.xml", "NPR", "radio", "news"},
	// Democracy and rights focused
	{"https://www.democracynow.org/democracynow.rss", "Democracy Now", "megaphone", "activism"},
	// Reuters for breaking news
	{"https://www.reutersagency.com/feed/?taxonomy=best-topics&post_type=best", "Reuters", "bolt", "breaking"},
}

// GetNews returns cached or fresh news articles
func (h *Handler) GetNews(c *gin.Context) {
	// Check cache
	h.cacheMutex.RLock()
	if time.Since(h.cacheTime) < h.cacheTTL && len(h.cache) > 0 {
		articles := h.cache
		h.cacheMutex.RUnlock()
		c.JSON(http.StatusOK, gin.H{
			"articles": articles,
			"cached":   true,
		})
		return
	}
	h.cacheMutex.RUnlock()

	// Fetch fresh news
	articles := h.fetchAllNews()

	// Update cache
	h.cacheMutex.Lock()
	h.cache = articles
	h.cacheTime = time.Now()
	h.cacheMutex.Unlock()

	c.JSON(http.StatusOK, gin.H{
		"articles": articles,
		"cached":   false,
	})
}

// fetchAllNews fetches news from all sources concurrently
func (h *Handler) fetchAllNews() []NewsArticle {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var allArticles []NewsArticle

	client := &http.Client{
		Timeout: 10 * time.Second,
	}

	for _, source := range newsSources {
		wg.Add(1)
		go func(src struct {
			URL      string
			Name     string
			Icon     string
			Category string
		}) {
			defer wg.Done()

			articles, err := fetchRSSFeed(client, src.URL, src.Name, src.Icon, src.Category)
			if err != nil {
				// Log error but continue with other sources
				return
			}

			mu.Lock()
			allArticles = append(allArticles, articles...)
			mu.Unlock()
		}(source)
	}

	wg.Wait()

	// Sort by publication date (newest first)
	sort.Slice(allArticles, func(i, j int) bool {
		return allArticles[i].PublishedAt.After(allArticles[j].PublishedAt)
	})

	// Limit to most recent 50 articles
	if len(allArticles) > 50 {
		allArticles = allArticles[:50]
	}

	return allArticles
}

// fetchRSSFeed fetches and parses a single RSS feed
func fetchRSSFeed(client *http.Client, url, sourceName, sourceIcon, category string) ([]NewsArticle, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var feed rssFeed
	if err := xml.Unmarshal(body, &feed); err != nil {
		return nil, err
	}

	var articles []NewsArticle
	for i, item := range feed.Channel.Items {
		// Limit items per source
		if i >= 10 {
			break
		}

		pubDate := parseRSSDate(item.PubDate)

		// Extract image URL
		imageURL := item.Enclosure.URL
		if imageURL == "" {
			imageURL = item.MediaContent.URL
		}

		// Clean description (remove HTML tags)
		description := stripHTMLTags(item.Description)
		if len(description) > 300 {
			description = description[:297] + "..."
		}

		// Generate a simple ID from the link
		id := generateID(item.Link)

		articles = append(articles, NewsArticle{
			ID:          id,
			Title:       item.Title,
			Description: description,
			Link:        item.Link,
			Source:      sourceName,
			SourceIcon:  sourceIcon,
			PublishedAt: pubDate,
			ImageURL:    imageURL,
			Category:    category,
		})
	}

	return articles, nil
}

// parseRSSDate parses various RSS date formats
func parseRSSDate(dateStr string) time.Time {
	formats := []string{
		time.RFC1123Z,
		time.RFC1123,
		time.RFC822Z,
		time.RFC822,
		"Mon, 02 Jan 2006 15:04:05 -0700",
		"Mon, 02 Jan 2006 15:04:05 MST",
		"2006-01-02T15:04:05Z",
		"2006-01-02T15:04:05-07:00",
	}

	for _, format := range formats {
		if t, err := time.Parse(format, dateStr); err == nil {
			return t
		}
	}

	return time.Now()
}

// stripHTMLTags removes HTML tags from a string
func stripHTMLTags(s string) string {
	var result strings.Builder
	inTag := false
	for _, r := range s {
		if r == '<' {
			inTag = true
		} else if r == '>' {
			inTag = false
		} else if !inTag {
			result.WriteRune(r)
		}
	}
	return strings.TrimSpace(result.String())
}

// generateID creates a simple ID from a URL
func generateID(link string) string {
	// Use a hash of the URL as ID
	var hash uint64
	for _, c := range link {
		hash = hash*31 + uint64(c)
	}
	return "news-" + strings.ToLower(strings.ReplaceAll(link, "/", "-"))[:50]
}
