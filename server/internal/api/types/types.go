// Package types defines typed API response structs.
//
// Phase 7 tactical step: migrate from untyped gin.H{} maps to named
// Go structs so:
//
//   1. Field names become grep-able (renaming a field now surfaces
//      every call site at compile time, not at iOS runtime).
//   2. OpenAPI codegen has something to annotate when we wire it up.
//   3. Clients (iOS, Rust desktop, web) can eventually be generated
//      from the same source instead of hand-maintained.
//
// The struct definitions here are the authoritative JSON shape of
// the API. Field ordering, json tags, and nullability all survive
// into the wire format as-is.
package types

import "time"

// VersionResponse is the body returned by GET /api/v1/version.
// Used by deploy scripts to verify the running binary matches the
// SHA that was just built.
type VersionResponse struct {
	Version   string `json:"version"`
	SHA       string `json:"sha"`
	BuildDate string `json:"built_at"`
}

// FeedV2Response is the body returned by GET /api/v1/feed/v2.
// Mirrors the structure the iOS client expects; changing fields
// here is a breaking change across mobile + desktop.
type FeedV2Response struct {
	Items      []FeedV2Item `json:"items"`
	Limit      int          `json:"limit"`
	Offset     int          `json:"offset"`
	NextOffset int          `json:"next_offset"` // -1 when no more pages
	// Source identifies whether the result came from the precomputed
	// materialized_feeds table or the live ranking path. Optional —
	// only set when FEED_MATERIALIZED is on and a hit occurred.
	Source string `json:"source,omitempty"`
}

// FeedV2Item is one entry in a feed response. All items are posts;
// news articles appear as posts with source_type='mainstream' since
// Phase 4.
type FeedV2Item struct {
	ID   string     `json:"id"`
	Type string     `json:"type"` // currently always "post"
	Post *PostBody  `json:"post,omitempty"`
	Why  []string   `json:"why,omitempty"`
}

// PostBody is a post in a feed response.
type PostBody struct {
	ID                string     `json:"id"`
	AuthorID          string     `json:"author_id"`
	Content           string     `json:"content"`
	SourceType        string     `json:"source_type"` // firsthand | aggregated | mainstream
	Urgency           int        `json:"urgency"`
	CreatedAt         time.Time  `json:"created_at"`
	VerificationScore int        `json:"verification_score"`
	Location          *LatLng    `json:"location,omitempty"`
	LocationName      string     `json:"location_name,omitempty"`
	Media             []Media    `json:"media,omitempty"`
}

type LatLng struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

type Media struct {
	ID        string    `json:"id"`
	URL       string    `json:"url"`
	Type      string    `json:"type"`
	CreatedAt time.Time `json:"created_at"`
}
