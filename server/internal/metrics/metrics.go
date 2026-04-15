// Package metrics exposes Prometheus metrics for the API and worker.
//
// Single package so api and worker instrument into the same registry
// and scrape endpoint configuration. Histograms pick buckets that
// match typical latencies for each measurement type (sub-ms to
// several seconds for HTTP; seconds to minutes for bot runs).
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	// HTTPDuration records request latency by method, route, and
	// status class ("2xx", "4xx", "5xx"). Route is a path template
	// (e.g. "/feed/v2"), NOT the raw URL — keeps cardinality bounded.
	HTTPDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "kuurier_http_request_duration_seconds",
			Help:    "HTTP request latency by method, route, and status class.",
			Buckets: prometheus.ExponentialBuckets(0.001, 2, 14), // 1ms → ~16s
		},
		[]string{"method", "route", "status_class"},
	)

	// FeedMaterializationDuration tracks how long the worker's
	// materialize pass takes end-to-end. Rising latency here is an
	// early signal that the ranking path is slowing down.
	FeedMaterializationDuration = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "kuurier_feed_materialization_duration_seconds",
			Help:    "Wall-clock duration of a full feed materialization pass.",
			Buckets: prometheus.ExponentialBuckets(1, 2, 10), // 1s → ~17min
		},
	)

	// BotRunDuration by bot name (news / protest). Histogram so we
	// can see p95 even when most runs are fast.
	BotRunDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "kuurier_bot_run_duration_seconds",
			Help:    "Wall-clock duration of a bot RunOnce invocation.",
			Buckets: prometheus.ExponentialBuckets(1, 2, 10),
		},
		[]string{"bot"},
	)

	// BotItemsPosted counts articles/events created by each bot run.
	BotItemsPosted = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "kuurier_bot_items_posted_total",
			Help: "Items (posts/events) created by a bot run.",
		},
		[]string{"bot"},
	)
)

func init() {
	prometheus.MustRegister(
		HTTPDuration,
		FeedMaterializationDuration,
		BotRunDuration,
		BotItemsPosted,
	)
}

// Handler returns the Prometheus scrape handler for /metrics.
func Handler() http.Handler {
	return promhttp.Handler()
}
