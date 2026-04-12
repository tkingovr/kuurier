package bot

// RSSSource represents an RSS feed to aggregate from.
type RSSSource struct {
	URL      string
	Name     string
	Category string // maps to topic slugs where possible
	TopicIDs []string
}

// BotUserID is the well-known UUID for the news bot system user.
const BotUserID = "00000000-0000-0000-0000-000000000001"

// MaxPostsPerRun limits how many posts the bot creates in a single run
// to avoid flooding the feed.
const MaxPostsPerRun = 12

// NewsSources returns the configured RSS sources mixing general news with
// activist-focused outlets. Each source can be tagged with topic IDs that
// match the app's predefined topics.
func NewsSources() []RSSSource {
	return []RSSSource{
		// ── General / mainstream news ───────────────────────────────
		{
			URL:      "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml",
			Name:     "NY Times",
			Category: "general",
		},
		{
			URL:      "https://feeds.bbci.co.uk/news/world/rss.xml",
			Name:     "BBC News",
			Category: "world",
		},
		{
			URL:      "https://www.theguardian.com/world/rss",
			Name:     "The Guardian",
			Category: "world",
		},
		{
			URL:      "https://feeds.npr.org/1001/rss.xml",
			Name:     "NPR",
			Category: "general",
		},
		{
			URL:      "https://www.reutersagency.com/feed/?taxonomy=best-topics&post_type=best",
			Name:     "Reuters",
			Category: "breaking",
		},
		{
			URL:      "https://feeds.washingtonpost.com/rss/politics",
			Name:     "Washington Post",
			Category: "politics",
		},
		{
			URL:      "https://apnews.com/apf-topnews/feed",
			Name:     "AP News",
			Category: "general",
		},

		// ── Activist / social justice focused ──────────────────────
		{
			URL:      "https://www.democracynow.org/democracynow.rss",
			Name:     "Democracy Now",
			Category: "activism",
		},
		{
			URL:      "https://theintercept.com/feed/?rss",
			Name:     "The Intercept",
			Category: "accountability",
		},
		{
			URL:      "https://www.theguardian.com/environment/climate-crisis/rss",
			Name:     "Guardian Climate",
			Category: "climate",
			TopicIDs: []string{"climate"},
		},
		{
			URL:      "https://grist.org/feed/",
			Name:     "Grist",
			Category: "climate",
			TopicIDs: []string{"climate"},
		},
		{
			URL:      "https://www.theguardian.com/us-news/us-politics/rss",
			Name:     "Guardian US Politics",
			Category: "politics",
			TopicIDs: []string{"voting-rights"},
		},
		{
			URL:      "https://www.theguardian.com/inequality/rss",
			Name:     "Guardian Inequality",
			Category: "labor",
			TopicIDs: []string{"labor", "housing"},
		},
	}
}
