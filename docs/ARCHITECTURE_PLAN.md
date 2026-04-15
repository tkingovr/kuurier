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

### 1.3 Bot panic recovery ✅
- [x] Added `safeRun` helper in `server/internal/bot/safe.go` — catches panics, logs stack trace via `runtime/debug.Stack()`, converts to an error.
- [x] News bot `Start()` initial-run goroutine and `scheduleLoop()` both route through `safeRun` so a panic in `RunOnce` no longer kills the scheduler.
- [x] Protest bot updated with same pattern.
- [x] Tests (`safe_test.go`): success passthrough, error passthrough, panic recovery, nil-map panic, and multi-call-after-panic scheduler pattern.

### 1.4 Structured request logging middleware ✅
- [x] `middleware.RequestID()` generates a UUID per request (honoring a client-supplied `X-Request-ID` when reasonable), stores it on `gin.Context`, and echoes it back as a response header. `RequestIDFromContext()` helper lets downstream code reach it.
- [x] `middleware.Logger()` rewritten to emit a structured `slog` record with `request_id`, `method`, `path`, `query`, `status`, `latency_ms`, `response_bytes`, and `user_id` (when set). Uses `LogAttrs` at Info/Warn/Error level based on HTTP status class so 5xx requests stand out.
- [x] **Deliberate deviation from the plan**: did NOT include `ip` or `user_agent` because the existing codebase has a pre-existing privacy stance against logging those. The Phase 1.4 plan item is adjusted accordingly.
- [x] Router chain updated to run `RequestID` before `Logger`.
- [x] Migrated the `log.Printf` in the rate-limit fallback to `slog.WarnContext` while touching the file.
- [x] Confirmed `logger.Init()` runs in `main.go:42` before `NewRouter()` is called later in the function.
- [x] 10 new tests in `request_id_test.go` cover ID generation, header passthrough, oversized-header rejection, context extraction, structured field emission, level selection for 4xx/5xx, user_id inclusion, and the no-ip/no-ua privacy invariant.

### 1.5 Secrets in GitHub Actions environment (not in repo) ✅
**Revised approach:** the user wants nothing secret-adjacent in the public repo, even encrypted. Use GitHub Actions environment secrets (which we already use for `SERVER_HOST`, `SERVER_USER`, `SERVER_SSH_KEY`) as the canonical store. One big `PRODUCTION_ENV` secret holds the entire `.env` body.

- [x] `docs/SECRETS.md` documents required keys, one-time setup, rotation, `ENCRYPTION_KEY` caveats, disaster recovery.
- [x] `deploy.yml` base64-encodes `secrets.PRODUCTION_ENV` (log-masked), forwards via SSH, atomically writes to `~/kuurier/.env` with `umask 077`.
- [x] User added the `PRODUCTION_ENV` secret to the `production` environment. Verified deploy shows `.env written from GitHub secret (6 lines)`.
- [x] Fallback container-introspection path removed — deploy now **fails loudly** if `PRODUCTION_ENV` is missing instead of silently regenerating from running containers.
- [x] Side discovery: `appleboy/ssh-action`'s `script_stop: true` option mis-handles `if [ ... ]` conditions (treats the test's exit status as a top-level failure). Disabled, documented inline, relying on `set -e` inside the script instead.

### 1.6 Remove `.DS_Store` and audit for accidentally-committed secrets ✅
- [x] Verified: `.DS_Store` is already in `.gitignore` (line 61). Same for `.env`, `.env.*`, `*.pem`, `*.key`, `secrets/`.
- [x] Verified: **no `.DS_Store` files are currently tracked** (`git ls-files` clean).
- [x] Verified: **git history is clean** — no historical commits of `.env`, `.DS_Store`, `.pem`, or `.key` files.
- [x] Verified: no private keys (`BEGIN PRIVATE KEY`) or AWS-style keys (`AKIA...`) in history.
- [x] Content scan found only dev-only placeholders in `run-local.sh` and `config.go` — both clearly marked `INSECURE_DEV_SECRET` / `change_me`. Production rejects missing/short `JWT_SECRET` at startup (`config.go:89-98`), so the placeholder cannot reach prod.
- [x] `.env.production.example` files are tracked as templates (no real values).

**Outcome:** no secrets to rotate, no files to remove. This phase was a verification pass.

---

## Phase 2 — Migration Infrastructure in the Binary
**Goal:** migrations become part of the application, not a side-channel script. No more silent drift.
**Depends on:** Phase 1.2 (migration table populated and consistent).
**Estimated effort:** 1 week.

### 2.1 Adopt `pressly/goose` or equivalent ✅
**Decision: roll our own (~80 lines).** Both goose and golang-migrate use their own version-tracking table schemas (integer `version_id` vs our existing `version VARCHAR(255)`), meaning we'd need to migrate state in production. Our requirements are minimal (apply ordered SQL files, track applied set, advisory lock), the pure-Go migrator fits in one file, and staying with our existing `schema_migrations(version, applied_at)` table avoids a state migration. Custom code beats dependency + state migration here.
- [x] No dependency added — `database/sql` and `jackc/pgx/v5` (already present) are enough.
- [x] Keep existing file naming (`NNN_name.sql`); no goose markers needed.

### 2.2 Embed migrations into the binary ✅
- [x] `server/internal/migrations/migrations.go` uses `//go:embed sql/*.sql` and exposes `Run(ctx, pool)`.
- [x] Advisory lock via `pg_advisory_lock(4242424242)` — blocks the second caller, which then observes the applied set and no-ops.
- [x] 13 migration files moved to `server/internal/migrations/sql/`; `000_complete_schema.sql` deleted (no longer authoritative).
- [x] Bootstrap shortcut preserved: if `schema_migrations` is empty but `public.users` exists, mark all embedded migrations as applied (the existing prod state).
- [x] Each migration + its tracking INSERT runs in one transaction.

### 2.3 Call on startup ✅
- [x] `cmd/kuurier-server/main.go` runs `migrations.Run(ctx, db.Pool())` with a 2-minute timeout immediately after the DB pool is created, before any other initialization.
- [x] `--migrate-only` flag added so the same binary can be invoked in a one-shot mode for CI and out-of-band ops.
- [ ] Worker binary will call the same function when Phase 3 ships.

### 2.4 Remove the legacy bootstrap path ✅
- [x] Deleted `./migrations/000_complete_schema.sql:/docker-entrypoint-initdb.d/...` mount from both `docker-compose.prod.yml` and `docker-compose.yml`.
- [x] Deleted `000_complete_schema.sql` — embedded migrations 001-013 are authoritative.
- [x] Deleted the in-deploy shell migration block from `deploy.yml` — app handles it on startup.

### 2.5 CI coverage ✅
- [x] New CI job `test-migrations`: starts PostGIS service, runs `go run ./cmd/kuurier-server --migrate-only` against a fresh DB, verifies exit code 0.
- [x] Second run of the same command must NOT emit a `"migration applied"` log line — catches non-idempotent migrations by failing the CI job.
- [x] Final step `psql` queries `schema_migrations` and fails if fewer than 10 rows are present (sanity check that the embed actually ran).

---

## Phase 3 — Extract the Worker Process ✅
**Goal:** bots stop running inside the API container. One worker, not two.
**Depends on:** Phase 2 (so the worker can run its own migrations on startup without conflict).
**Estimated effort:** 1–2 weeks.

### 3.1 New binary ✅
- [x] `server/cmd/kuurier-worker/main.go` loads config, runs migrations (same advisory-lock-guarded `migrations.Run` as the API — whoever wins the lock applies, the other observes), starts `NewsBot` + `ProtestBot` schedulers, consumes Redis-backed admin triggers, runs a 30-second heartbeat loop.
- [x] No HTTP server, no Gin router, no WebSocket hub — just goroutines.

### 3.2 Remove bots from the API process ✅
- [x] Deleted `newsBot := bot.NewNewsBot(db)` and friends from `cmd/kuurier-server/main.go`.
- [x] Deleted `api.SetNewsBot()` / `api.SetProtestBot()` and the package-level globals; `bot.NewHandler` now takes `(db, redis)` instead of bot instances.
- [x] Dropped the unused `bot` import from the API binary.

### 3.3 Admin bot-trigger endpoints ✅
- [x] Chose Redis lists (`BLPOP`) — clean blocking read without busy-polling, no subscriber-lost-while-disconnected issue.
- [x] `server/internal/bot/trigger.go` has `EnqueueTrigger`, `RunTriggerConsumer`, `RecordHeartbeat`; queue names versioned (`kuurier:bot:trigger:news:v1`).
- [x] `TriggerRun` / `TriggerProtestScrape` now enqueue instead of calling `RunOnce` directly.
- [x] New `GET /admin/bot/worker-status` returns the last worker heartbeat so admins can spot a stuck worker.

### 3.4 Docker + compose ✅
- [x] Added `worker` service to `docker-compose.prod.yml` — same image, `command: ["./kuurier-worker"]`, healthcheck disabled (no HTTP listener).
- [x] Single instance, `restart: unless-stopped`, shares the same env block as the API.
- [x] Deploy now force-recreates `api-blue api-green worker` together.

### 3.5 Build pipeline ✅
- [x] Dockerfile builds both `kuurier-server` and `kuurier-worker` with identical ldflags so `/version` reports the same SHA across the cluster.
- [x] Single image contains both binaries — compose picks the entrypoint via `command:`. Simpler than two image tags.

### 3.6 Observability for the worker ✅
- [x] Worker logs go to `docker logs kuurier-worker` (structured slog from the same `logger.Init`).
- [x] Heartbeat key `kuurier:worker:heartbeat:v1` with 90s TTL lets the API's `/admin/bot/worker-status` detect a dead worker.
- [x] `bot_run_log` already tracked all bot runs; that continues to work unchanged since the SQL is identical.

---

## Phase 4 — Consolidate RSS, Delete `news.Service` ✅
**Goal:** one RSS code path, one source of truth. The news bot already writes to `posts`; everything should read from there.
**Depends on:** Phase 3 (so we're not removing code the API needs while the bot is still in-process).
**Estimated effort:** 1 week.

### 4.1 Verify the news bot is producing what the feed needs
- Deferred verification — Phase 3 just shipped the worker split, so the news bot has only been running in its new home for a few hours. If there's a delivery issue, it'll surface in `bot_run_log` and the feed; still a no-code action, not a blocker.

### 4.2 `respondWithNewsFeed` rewritten ✅
- [x] Queries `posts WHERE source_type='mainstream' AND is_flagged=false AND created_at > NOW() - INTERVAL '7 days'` ordered by recency, paginated. No live RSS at request time.
- [x] `newsService==nil` branch gone.

### 4.3 `mixNewsItems` removed from `GetFeedV2` ✅
- [x] The in-flight RSS mix-in block is deleted. News naturally enters the ranked for-you feed via `fetchFeedCandidates` since it's just posts.

### 4.4 `/news` endpoint redirects ✅
- [x] `GET /api/v1/news` returns 301 to `/api/v1/feed/v2?type=news`. Old clients don't break silently.

### 4.5 Package deletion ✅
- [x] `server/internal/news/` directory deleted entirely (two files).
- [x] `news` import removed from `feed/handler.go` and `api/router.go`.
- [x] `*news.Service` field and constructor parameter removed from `feed.Handler`.
- [x] `article` field on `scoredFeedItem` removed — all feed items are posts now.

### 4.6 Tests
- No news-package tests existed to delete. The feed's existing unit tests still pass. Integration-test coverage of the rewritten `respondWithNewsFeed` is deferred to Phase 8 (testcontainers harness).

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
