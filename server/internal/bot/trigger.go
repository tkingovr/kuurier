// This file wires bot-trigger requests from the API process to the
// worker process via Redis.
//
// Why Redis:
//   - We already have it connected in both processes.
//   - We don't need durability — missed triggers just mean the next
//     scheduled tick fires instead. The scheduled loop still runs
//     twice daily regardless.
//   - BLPOP with a timeout gives the worker a clean blocking read
//     without busy-polling.
//
// Queue names are versioned so future schema changes don't collide
// with in-flight payloads.

package bot

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/kuurier/server/internal/storage"
)

const (
	// TriggerQueueNews is the Redis list key the worker BLPOPs to
	// receive manual news-aggregation requests from the admin API.
	TriggerQueueNews = "kuurier:bot:trigger:news:v1"

	// TriggerQueueProtest is the same channel for protest scraping.
	TriggerQueueProtest = "kuurier:bot:trigger:protest:v1"

	// WorkerHeartbeatKey is a Redis key the worker updates every 30s
	// with the current UTC timestamp. The API can read it to detect a
	// dead worker for an admin-facing health endpoint.
	WorkerHeartbeatKey = "kuurier:worker:heartbeat:v1"

	// heartbeatTTL is the TTL on the heartbeat key. If the worker goes
	// away, the key expires and a read returns an empty string.
	heartbeatTTL = 90 * time.Second
)

// EnqueueTrigger pushes a trigger payload onto the named Redis list.
// Called by the API-side admin handler. The worker's BLPOP consumer
// picks it up and runs the corresponding bot's RunOnce.
func EnqueueTrigger(ctx context.Context, redis *storage.Redis, queue string) error {
	// Payload is just a timestamp right now; keeping the signature
	// flexible in case future triggers carry parameters.
	payload := fmt.Sprintf("%d", time.Now().Unix())
	if err := redis.Client().LPush(ctx, queue, payload).Err(); err != nil {
		return fmt.Errorf("lpush %s: %w", queue, err)
	}
	return nil
}

// RunTriggerConsumer is a long-running loop that BLPOPs both trigger
// queues and invokes `fn` with the queue name of the trigger that
// fired. Exits when ctx is cancelled.
//
// Blocking read keeps Redis load minimal — the worker is idle until
// a trigger arrives.
func RunTriggerConsumer(ctx context.Context, redis *storage.Redis, fn func(queue string)) {
	slog.InfoContext(ctx, "trigger consumer started",
		slog.String("news_queue", TriggerQueueNews),
		slog.String("protest_queue", TriggerQueueProtest))

	for ctx.Err() == nil {
		// BLPOP with a 5-second timeout so we can observe ctx.Err()
		// without being stuck forever.
		res, err := redis.Client().BLPop(ctx, 5*time.Second, TriggerQueueNews, TriggerQueueProtest).Result()
		if err != nil {
			// Timeout is expected and harmless.
			if err.Error() == "redis: nil" {
				continue
			}
			// Real error: log and back off briefly so we don't
			// hot-loop on a dead redis connection.
			slog.WarnContext(ctx, "trigger BLPOP error",
				slog.String("error", err.Error()))
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
			}
			continue
		}

		if len(res) < 2 {
			continue
		}
		queue := res[0]
		slog.InfoContext(ctx, "trigger received", slog.String("queue", queue))
		// Run the bot synchronously; the next BLPOP won't fire until
		// this returns, which is fine — admin triggers are rare.
		fn(queue)
	}
}

// RecordHeartbeat updates the worker heartbeat key with the current
// timestamp. Called on a 30-second cadence from the worker's main
// loop so the API can tell if the worker is alive.
func RecordHeartbeat(ctx context.Context, redis *storage.Redis) error {
	stamp := fmt.Sprintf("%d", time.Now().Unix())
	return redis.Client().Set(ctx, WorkerHeartbeatKey, stamp, heartbeatTTL).Err()
}
