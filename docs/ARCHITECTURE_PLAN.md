# Kuurier Architecture Improvement Plan

This document tracks the incremental work to evolve the current architecture into one that scales to ~100k users without a big-bang rewrite. Each phase is independently shippable. Check off TODOs as they land.

Background: full architecture review lives in the session log; the gaps this plan addresses are summarized at the top of each phase.

---

## Phase 1 — Make the Floor Safe
**Goal:** stop the bleeding. No new features, just stability fixes for the blocking problems that caused 6 weeks of silent deploy failures and the `ea51e92`-style schema drift crash.
**Depends on:** nothing.
**Estimated effort:** 1–2 weeks.

### 1.1 Deploy verification (`/version` endpoint + SHA check) ✅
- [x] Add `Version` and `GitSHA` vars to `server/cmd/kuurier-server/main.go`, populated via `-ldflags="-X main.Version=... -X main.GitSHA=..."`.
- [x] Update `server/Dockerfile` to pass `GIT_SHA` as a build arg and into the ldflags.
- [x] Update `.github/workflows/deploy.yml` to pass `GIT_SHA=${{ github.sha }}` to `docker build`.
- [x] Add `GET /api/v1/version` handler returning `{"version": "...", "sha": "...", "built_at": "..."}`. Public, no auth.
- [x] Update deploy script's health check to call `/version` and assert the SHA matches the expected value; fail the deploy if it doesn't.

### 1.2 Wire `scripts/migrate.sh` into every deploy ✅
- [x] Read `server/scripts/migrate.sh` and confirm it uses `schema_migrations` tracking table.
- [x] In `.github/workflows/deploy.yml`, replace the current hardcoded `for migration in migrations/010_*.sql ...` loop with tracked-migration logic executed via `docker exec kuurier-postgres psql`.
- [x] Backfill inlined into the deploy: if `schema_migrations` is empty but `users` table exists (existing prod DB), mark all existing numbered migrations as already-applied automatically. No separate one-shot SQL file needed.
- [x] Verified: second consecutive deploy shows `No pending migrations` with no bootstrap firing. Idempotent.

### 1.3 Bot panic recovery
- [ ] Wrap the body of `scheduleLoop()` in `server/internal/bot/newsbot.go:66` with `defer recover()` that logs the panic and restarts the loop after a 30-second backoff.
- [ ] Do the same for `server/internal/bot/protestbot.go:62`.
- [ ] Add a test that panics inside a mocked `RunOnce` and asserts the loop restarts.

### 1.4 Structured request logging middleware
- [ ] Add a `RequestID` middleware in `server/internal/middleware/` that generates a UUID per request and stores it in `gin.Context` under key `"request_id"` and as a response header `X-Request-ID`.
- [ ] Replace the `log.Printf` in `server/internal/middleware/middleware.go:31` (the existing Logger middleware) with a `slog.InfoContext` call that includes: `request_id`, `method`, `path`, `status`, `latency_ms`, `user_id` (if auth context is set), `ip`, and `user_agent`.
- [ ] Confirm `logger.Init()` is called before the router is created in `main.go`.

### 1.5 Secrets move to `age`-encrypted file
- [ ] Install `age` locally, generate a key pair. Store the private key in a password manager AND on an offline backup (USB, paper).
- [ ] Write a new `server/scripts/secrets-decrypt.sh` that runs `age -d -i $AGE_KEY_FILE secrets.age > .env`.
- [ ] Commit the age public key as `server/age-recipients.txt` so anyone can re-encrypt.
- [ ] Export current production secrets (from the running containers — we already have the recovery logic in the deploy script) into a plain `.env`, encrypt to `server/secrets.age`, commit the encrypted file.
- [ ] Add `server/.env*` to `.gitignore` (verify it's already there).
- [ ] Update `deploy.yml` to decrypt `secrets.age` via an `AGE_KEY` GitHub Actions secret before `docker compose up`.
- [ ] Remove the env-recovery block in `deploy.yml` once the encrypted path is proven.

### 1.6 Remove `.DS_Store` and audit for accidentally-committed secrets
- [ ] Add `**/.DS_Store` to `.gitignore`.
- [ ] Run `git log --all --full-history -- server/.env` to check if the env file was ever committed. If yes, rotate every secret.

---

## Phase 2 — Migration Infrastructure in the Binary
**Goal:** migrations become part of the application, not a side-channel script. No more silent drift.
**Depends on:** Phase 1.2 (migration table populated and consistent).
**Estimated effort:** 1 week.

### 2.1 Adopt `pressly/goose` or equivalent
- [ ] Decision: `pressly/goose` vs `golang-migrate/migrate`. Goose is simpler for embedded files; migrate has more drivers. Pick one and note the decision in this file.
- [ ] Add the chosen library to `go.mod`.
- [ ] Rename migration files from `013_protest_bot.sql` to goose format if needed (goose accepts `NNN_name.sql` with `-- +goose Up` / `-- +goose Down` markers).

### 2.2 Embed migrations into the binary
- [ ] Create `server/internal/migrations/migrations.go` with a `//go:embed migrations/*.sql` directive and a `RunMigrations(ctx, pool)` function.
- [ ] Wrap the migration run in a `pg_try_advisory_lock(<constant>)` so only one process runs them when blue+green start simultaneously.
- [ ] Move the physical `.sql` files to `server/internal/migrations/sql/` (or adjust the embed path) so they're included in the Go binary.

### 2.3 Call on startup
- [ ] Add `if err := migrations.RunMigrations(ctx, db.Pool()); err != nil { log.Fatalf(...) }` at the top of `cmd/kuurier-server/main.go`, right after DB connection.
- [ ] Also call it from the future `cmd/kuurier-worker/main.go` once Phase 3 lands.

### 2.4 Remove the legacy bootstrap path
- [ ] Delete the `./migrations/000_complete_schema.sql:/docker-entrypoint-initdb.d/001_schema.sql:ro` mount from `docker-compose.prod.yml`.
- [ ] Keep `000_complete_schema.sql` as documentation only (add a header comment making this clear), or delete it entirely — team decision.

### 2.5 CI coverage
- [ ] Add a CI job that spins up a fresh PostGIS container, runs the API binary in migrate-only mode (add a `--migrate-only` flag), and asserts exit code 0.
- [ ] Add a second CI job that runs migrations twice to catch idempotency regressions.

---

## Phase 3 — Extract the Worker Process
**Goal:** bots stop running inside the API container. One worker, not two.
**Depends on:** Phase 2 (so the worker can run its own migrations on startup without conflict).
**Estimated effort:** 1–2 weeks.

### 3.1 New binary
- [ ] Create `server/cmd/kuurier-worker/main.go` that initializes DB + Redis (same `config.Load()` path), runs migrations, and starts `NewsBot` + `ProtestBot`.
- [ ] No HTTP server, no Gin router, no WebSocket hub.
- [ ] Add a minimal health check: a goroutine that writes the current timestamp to a known Redis key every 30 seconds, for the API to monitor worker liveness.

### 3.2 Remove bots from the API process
- [ ] Delete `newsBot := bot.NewNewsBot(db)`, `newsBot.Start()`, `defer newsBot.Stop()`, and same for `protestBot`, from `cmd/kuurier-server/main.go`.
- [ ] Delete `api.SetNewsBot()` and `api.SetProtestBot()` calls.
- [ ] Delete the `activeNewsBot`/`activeProtestBot` globals from `router.go` and the `SetNewsBot`/`SetProtestBot` functions.

### 3.3 Admin bot-trigger endpoints
- [ ] Decision: simplest path is a Redis-backed job queue. Pick one of:
  - (a) Redis pub/sub: API publishes `kuurier:bot:trigger:news`, worker subscribes and runs `RunOnce`.
  - (b) Redis list: API `LPUSH`es, worker `BRPOP`s.
- [ ] Implement the chosen approach.
- [ ] Update `bot.Handler.TriggerRun` and `TriggerProtestScrape` to enqueue jobs instead of calling the bot directly.
- [ ] The admin handler can still live in the API process.

### 3.4 Docker + compose
- [ ] Add a `kuurier-worker` service to `docker-compose.prod.yml` using the same image tag as the API but a different `command`.
- [ ] Set `replicas: 1` or use a service with no replication by design.
- [ ] Set `restart: unless-stopped`.

### 3.5 Build pipeline
- [ ] Update `Dockerfile` to build both binaries. Options: (a) multi-target build with `--target server` / `--target worker`, or (b) a single image that contains both binaries and selects via `CMD`.
- [ ] Push both images (or one image with two entrypoints) to the registry with the same SHA tag.

### 3.6 Observability for the worker
- [ ] Worker logs go to `docker logs kuurier-worker` — confirm it's captured in whatever log aggregation we stand up in Phase 6.
- [ ] The shared `bot_run_log` table already tracks worker activity.

---

## Phase 4 — Consolidate RSS, Delete `news.Service`
**Goal:** one RSS code path, one source of truth. The news bot already writes to `posts`; everything should read from there.
**Depends on:** Phase 3 (so we're not removing code the API needs while the bot is still in-process).
**Estimated effort:** 1 week.

### 4.1 Verify the news bot is producing what the feed needs
- [ ] Query production `posts` table after Phase 3 is live for a week: `SELECT source_type, COUNT(*) FROM posts WHERE created_at > NOW() - INTERVAL '7 days' GROUP BY 1`. Confirm `mainstream` count is healthy.
- [ ] If counts are low, fix the news bot BEFORE deleting `news.Service` as a safety net.

### 4.2 Replace `respondWithNewsFeed`
- [ ] In `server/internal/feed/handler.go`, rewrite `respondWithNewsFeed` to query posts filtered by `source_type = 'mainstream'` ordered by `created_at DESC`, paginated. No RSS fetch.
- [ ] Remove the `h.newsService == nil` branch.

### 4.3 Remove `mixNewsItems` from `GetFeedV2`
- [ ] Delete the block at `feed/handler.go:~246–249` that calls `h.newsService.GetNews()` and `h.mixNewsItems()`.
- [ ] News articles appear naturally in the ranked feed because they're posts with `source_type='mainstream'` — already handled by `fetchFeedCandidates`.

### 4.4 Redirect or remove the `/news` endpoint
- [ ] If clients still call `GET /api/v1/news`, add a 301 redirect to `/api/v1/feed/v2?type=news`.
- [ ] Otherwise, delete the route from `router.go`.

### 4.5 Delete the package
- [ ] Delete `server/internal/news/service.go`, `server/internal/news/handler.go`.
- [ ] Remove `news.NewService()`, `news.NewHandler()`, and `newsService` parameter from `feed.NewHandler()`.
- [ ] Remove the `news` import everywhere.
- [ ] Remove `*news.Service` field from `feed.Handler`.

### 4.6 Update tests
- [ ] Delete any news.Service tests.
- [ ] Add a test for the rewritten `respondWithNewsFeed` against a seeded DB.

---

## Phase 5 — Feed Materialization
**Goal:** feed reads stop loading 1200 rows into Go memory per request. Precompute scores.
**Depends on:** Phase 3 (worker owns the materialization job).
**Estimated effort:** 2–3 weeks.

### 5.1 Schema
- [ ] Write migration `014_materialized_feeds.sql`:
  ```
  CREATE TABLE materialized_feeds (
    user_id UUID NOT NULL,
    feed_type TEXT NOT NULL,
    post_id UUID NOT NULL,
    score DOUBLE PRECISION NOT NULL,
    item_type TEXT NOT NULL,
    why TEXT[],
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, feed_type, post_id)
  );
  CREATE INDEX idx_mf_read ON materialized_feeds (user_id, feed_type, score DESC);
  ```
- [ ] Write migration `015_users_last_active.sql`: `ALTER TABLE users ADD COLUMN last_active_at TIMESTAMPTZ;`.

### 5.2 Update last_active_at
- [ ] In `auth.VerifyChallenge` handler, set `last_active_at = NOW()` on successful auth.
- [ ] Consider also updating on every feed request (rate-limited to once per 5 minutes per user via Redis).

### 5.3 Worker job
- [ ] Create `server/internal/worker/feed_materializer.go` with a `RunOnce(ctx)` method.
- [ ] Logic: `SELECT id FROM users WHERE last_active_at > NOW() - INTERVAL '7 days'` → for each user, call the existing `fetchFeedCandidates` + `rankFeedCandidates` (moved/exported from `feed/handler.go`) → `UPSERT` into `materialized_feeds`.
- [ ] Delete stale rows: `DELETE FROM materialized_feeds WHERE computed_at < NOW() - INTERVAL '1 hour' AND user_id NOT IN (active users)`.
- [ ] Schedule: every 5 minutes. Add to the worker's main loop.

### 5.4 Refactor feed ranking into a reusable package
- [ ] Extract the ranking/scoring logic from `feed.Handler.rankFeedCandidates` into a `feed.Ranker` struct or package-level functions that take a DB pool and don't depend on `*gin.Context`. Both the handler and the worker import this.

### 5.5 Read path refactor
- [ ] In `GetFeedV2`, check `materialized_feeds` first: `SELECT ... WHERE user_id = $1 AND feed_type = $2 ORDER BY score DESC LIMIT $3 OFFSET $4`.
- [ ] If result is empty (new user) OR `MAX(computed_at) < NOW() - INTERVAL '10 minutes'`, fall back to live compute AND enqueue a materialization job for that user.
- [ ] Crisis feed and SOS alerts bypass materialization — query live.

### 5.6 Rollout
- [ ] Ship behind a feature flag: `FEED_MATERIALIZED=true|false` env var.
- [ ] Roll out to 10% of users first (hash user_id to bucket).
- [ ] Monitor feed latency and freshness complaints for a week. Then flip globally.

---

## Phase 6 — Observability
**Goal:** metrics, traces, structured logs, error aggregation. Debugging stops requiring `docker logs | grep`.
**Depends on:** Phase 1.4 (request ID middleware).
**Estimated effort:** 1 week. Can run parallel with Phase 5.

### 6.1 Migrate `log.Printf` → `slog`
- [ ] Grep all 85 call sites: `grep -rn "log\.\(Printf\|Println\|Fatalf\)" server/internal/`.
- [ ] Replace in batches (one package at a time): `log.Printf(fmt, args)` → `slog.Info("message", "key", value)`.
- [ ] Use `slog.ErrorContext(ctx, ...)` anywhere a request context is available so the request ID is propagated.
- [ ] Standardize field names: `error`, `user_id`, `event_id`, `post_id`, `channel_id`, `duration_ms`, `request_id`.

### 6.2 Prometheus metrics
- [ ] Add `github.com/prometheus/client_golang` to `go.mod`.
- [ ] Create `server/internal/metrics/metrics.go` with the core metrics:
  - `kuurier_http_request_duration_seconds` (histogram, labels: method, path_template, status)
  - `kuurier_db_pool_open_connections` (gauge)
  - `kuurier_bot_run_duration_seconds` (histogram, label: bot_name)
  - `kuurier_bot_articles_posted_total` (counter, label: bot_name)
  - `kuurier_feed_materialization_duration_seconds` (histogram)
- [ ] Add a `promhttp.Handler()` on port 9090 (separate from the public API port).
- [ ] Update middleware to record request duration into the histogram.

### 6.3 Prometheus + Grafana in compose
- [ ] Add `prometheus` service to `docker-compose.prod.yml` with a scrape config pointing to `api-blue:9090`, `api-green:9090`, `kuurier-worker:9090`.
- [ ] Add `grafana` service on an internal-only port (reverse-proxied through nginx with basic auth).
- [ ] Commit `infra/grafana/dashboards/kuurier.json` with initial dashboards: request rate, p95 latency, error rate, bot runs, DB connections.

### 6.4 Error aggregation
- [ ] Decision: self-hosted Glitchtip (Sentry-compatible, lighter) vs SaaS Sentry free tier. Note decision here.
- [ ] Add `sentry-go` SDK.
- [ ] Add `sentry.CaptureException(err)` in the Gin recovery middleware for 5xx responses.
- [ ] Add Sentry DSN to the encrypted secrets file.

### 6.5 Bot run dashboard
- [ ] Grafana panel querying `bot_run_log` directly (Postgres data source): runs by day, success rate, articles posted per run, errors over time.

---

## Phase 7 — OpenAPI Codegen
**Goal:** client-server schema drift becomes a CI failure, not a user-visible crash.
**Depends on:** nothing (can run anytime after Phase 1).
**Estimated effort:** 2–3 weeks.

### 7.1 Tactical first: typed response structs
- [ ] Create `server/internal/api/types/` package.
- [ ] For the top 5 handlers by API traffic (auth, feed, events, messaging, devices), replace `gin.H{}` with named structs, starting with the highest-drift-risk endpoints.
- [ ] Example: `type FeedV2Response struct { Items []FeedV2Item \`json:"items"\`; Limit int \`json:"limit"\`; Offset int \`json:"offset"\`; NextOffset int \`json:"next_offset"\` }`.
- [ ] Keep the same JSON output; this is purely internal.

### 7.2 Add OpenAPI annotations
- [ ] Add `github.com/swaggo/swag` and `github.com/swaggo/gin-swagger`.
- [ ] Annotate each handler with `@Summary`, `@Param`, `@Success`, `@Router`.
- [ ] Start with the auth package, then feed, then events.
- [ ] Run `swag init -g cmd/kuurier-server/main.go -o docs/openapi`.

### 7.3 CI for OpenAPI
- [ ] Add a `make generate` target that runs `swag init` and also runs the client codegen steps below.
- [ ] Add a CI step that runs `make generate` and fails if `git diff` is non-empty — meaning someone changed handlers without regenerating.

### 7.4 iOS codegen
- [ ] Install `CreateAPI` (Swift codegen tool).
- [ ] Generate Swift structs from `docs/openapi/swagger.json` into `apps/ios/Kuurier/Kuurier/Core/Models/Generated/`.
- [ ] Replace hand-written models in `Models.swift` one struct at a time, verifying decoding with real production responses.

### 7.5 Rust codegen
- [ ] Install `openapi-generator-cli`.
- [ ] Generate Rust structs into `apps/desktop/src-tauri/src/api/generated/`.
- [ ] Replace hand-written structs in `client.rs` one type at a time.

### 7.6 Web client (if applicable)
- [ ] If the web app makes API calls, generate TypeScript types the same way.

---

## Phase 8 — Integration Test Harness
**Goal:** catch cross-layer bugs before they reach production.
**Depends on:** Phase 2 (need a reliable way to migrate the test DB).
**Estimated effort:** 1–2 weeks.

### 8.1 Test container setup
- [ ] Add `github.com/testcontainers/testcontainers-go` and `github.com/testcontainers/testcontainers-go/modules/postgres`.
- [ ] Create `server/internal/testutil/db.go` with a `NewTestDB(t *testing.T) *pgxpool.Pool` helper that:
  - Starts a PostGIS container (`postgis/postgis:16-3.4`).
  - Runs migrations via `migrations.RunMigrations`.
  - Returns a pool scoped to the test's lifetime.
- [ ] Add a `TestMain` that reuses the container across tests in a package for speed.

### 8.2 Core flow tests
- [ ] Write `server/internal/auth/integration_test.go` covering: register → challenge → verify → token works → token expires correctly.
- [ ] Write `server/internal/feed/integration_test.go` covering: seed 30 posts with varied topics/locations/urgencies → `GET /feed/v2?type=for_you` → verify ranking order.
- [ ] Write `server/internal/messaging/integration_test.go` covering: create channel → post message → verify WebSocket broadcast.

### 8.3 CI integration
- [ ] Add a separate CI job `integration-tests` that runs these. Mark them with `//go:build integration` to keep unit tests fast.
- [ ] Run on every PR. Allow up to 5 minutes.

### 8.4 Bot integration test
- [ ] Mock the RSS upstream (use `httptest.Server`) and assert the bot correctly dedups, writes to `posts`, and updates `bot_run_log`.
- [ ] Same for protest bot with a mocked findaprotest.info response.

---

## Non-Goals (do NOT do without explicit reason)

- **Microservices** — the worker split in Phase 3 is the maximum appropriate decomposition.
- **Kubernetes** — docker-compose on a VPS is right-sized for this project.
- **Event sourcing / CQRS** — feed materialization is a cache, not an event log.
- **GraphQL** — OpenAPI codegen gives us schema contracts without the resolver complexity.
- **Redis Cluster** — single Redis is sufficient for rate limits and pub/sub.
- **Read replica** — deferred until Phase 5 (materialized feed) proves insufficient.
- **Changes to the Signal E2E implementation** — out of scope; requires cryptographic review.

---

## Change log

- `2026-04-15` — initial plan created from architecture review.
