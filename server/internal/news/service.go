package news

import (
	"net/http"
	"sort"
	"sync"
	"time"
)

// Service provides cached access to RSS news articles.
type Service struct {
	cache      []NewsArticle
	cacheMutex sync.RWMutex
	cacheTime  time.Time
	cacheTTL   time.Duration
}

// NewService creates a news service with default cache TTL.
func NewService() *Service {
	return &Service{
		cacheTTL: 15 * time.Minute,
	}
}

// GetNews returns cached or freshly fetched news articles.
func (s *Service) GetNews() ([]NewsArticle, bool) {
	// Check cache
	s.cacheMutex.RLock()
	if time.Since(s.cacheTime) < s.cacheTTL && len(s.cache) > 0 {
		articles := s.cache
		s.cacheMutex.RUnlock()
		return articles, true
	}
	s.cacheMutex.RUnlock()

	// Fetch fresh news
	articles := s.fetchAllNews()

	// Update cache
	s.cacheMutex.Lock()
	s.cache = articles
	s.cacheTime = time.Now()
	s.cacheMutex.Unlock()

	return articles, false
}

// fetchAllNews fetches news from all sources concurrently.
func (s *Service) fetchAllNews() []NewsArticle {
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
