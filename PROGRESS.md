# Kuurier Development Progress

**Last Updated:** January 11, 2026
**Current Branch:** `feature/invite-system`

---

## Overview

Kuurier is a secure activist platform with an iOS app (SwiftUI) and Go backend. The system uses Ed25519 keypair authentication (anonymous, no email/phone), PostgreSQL + PostGIS for storage, and an invite-only trust-based permission system.

---

## Completed Features

### 1. Invite-Only Registration System

**Backend (`/server/internal/invites/handler.go`):**
- `POST /invites` - Generate new invite code (requires trust 30+)
- `GET /invites` - List user's invite codes with stats
- `DELETE /invites/:code` - Revoke unused invite
- `GET /invites/validate/:code` - Check if code is valid (public)

**Database (`/server/migrations/002_invite_system.sql`):**
- `invite_codes` table with code, inviter_id, invitee_id, expires_at, used_at
- Code format: `KUU-XXXXXX` (6 alphanumeric chars)
- Codes expire after 7 days

**iOS (`/apps/ios/Kuurier/`):**
- Onboarding flow requires invite code input
- `InviteService.swift` - API calls for invite management
- `InvitesView.swift` - List/manage/share invite codes
- Invite stats display (available, active, used)

### 2. Trust Score System

**Trust Thresholds:**
| Score | Capability |
|-------|------------|
| 15 | Browse & view feed (default for new users) |
| 25 | Create posts |
| 30 | Generate invite codes |
| 50 | Create events |
| 100 | Send SOS alerts (or is_verified=true) |

**Trust Calculation:**
- Joining via invite: +15 points (auto-vouch from inviter)
- Each additional vouch: +10 points

**iOS Implementation:**
- Expandable trust score row in Settings showing all levels
- Locked states on Feed (compose), Events (create), Alerts (SOS)
- Informative alerts explaining what's needed to unlock features

### 3. Feed Feature

**Backend (`/server/internal/feed/handler.go`):**
- `GET /feed` - Fetch personalized feed with pagination
- `POST /feed/posts` - Create new post (requires trust 25+)
- `GET /feed/posts/:id` - Get single post
- `DELETE /feed/posts/:id` - Delete own post
- `POST /feed/posts/:id/verify` - Upvote post
- `POST /feed/posts/:id/flag` - Flag/downvote post

**iOS (`/apps/ios/Kuurier/`):**
- `FeedService.swift` - API calls for feed operations
- `FeedView` - Post list with pull-to-refresh and infinite scroll
- `PostRowView` - Post display with source badge, urgency dots, verify/flag
- `ComposePostView` - Create post form with:
  - Content with character count (500 max)
  - Source type picker (Firsthand/Aggregated/Mainstream)
  - Urgency level with stepper and 5-dot indicator
  - Location toggle with optional name field

### 4. Auth Improvements

- User profile now fetches on app launch (fixed trust score not showing)
- `AuthService.swift` fetches current user in `init()` if already authenticated

### 5. Bug Fixes

**Post Creation Double-Submit & Feed Refresh (Jan 11, 2026):**

*Problem:* After creating a post, the feed showed empty. Navigating away and back showed the post (sometimes duplicated).

*Root Causes:*
1. Feed refresh was being skipped - `createPost()` set `isLoading = true`, then called `fetchFeed()` which has `guard !isLoading else { return }`, causing the refresh to silently fail
2. No service-level double-submit protection - only view-level state that could race

*Fixes (`FeedService.swift` + `ContentView.swift`):*
- Added separate `isCreatingPost` published property for post creation state
- Added guard in `createPost()`: `guard !isCreatingPost else { return false }` to prevent double-submits
- Reset `isCreatingPost = false` BEFORE calling `fetchFeed()` so refresh isn't blocked
- `ComposePostView` now uses `feedService.isCreatingPost` instead of local state

---

## Project Structure

```
kuurier/
├── server/
│   ├── cmd/kuurier-server/      # Main entry point
│   ├── internal/
│   │   ├── api/router.go        # Route definitions
│   │   ├── auth/handler.go      # Auth endpoints
│   │   ├── feed/handler.go      # Feed endpoints
│   │   ├── invites/handler.go   # Invite endpoints
│   │   ├── config/              # Configuration
│   │   └── storage/             # Database connections
│   └── migrations/              # SQL migrations
├── apps/ios/Kuurier/
│   └── Kuurier/
│       ├── App/
│       │   ├── KuurierApp.swift
│       │   └── ContentView.swift    # Main views (Feed, Map, Events, Alerts, Settings)
│       ├── Core/
│       │   ├── Crypto/KeyManager.swift
│       │   ├── Network/APIClient.swift
│       │   ├── Models/Models.swift
│       │   └── Storage/SecureStorage.swift
│       └── Features/
│           ├── Auth/AuthService.swift
│           ├── Feed/FeedService.swift
│           └── Invites/
│               ├── InviteService.swift
│               └── InvitesView.swift
└── infra/docker/
    ├── docker-compose.yml
    └── Dockerfile.server
```

---

## Running the Project

### Backend (Docker)
```bash
cd /Users/aqubia/Documents/activist_os/kuurier/infra/docker
docker-compose up -d
```

Services:
- `kuurier-api` - Go server on port 8080
- `kuurier-postgres` - PostgreSQL on port 5432
- `kuurier-redis` - Redis on port 6379
- `kuurier-minio` - MinIO (S3) on ports 9000-9001

### iOS App
Open in Xcode:
```
/Users/aqubia/Documents/activist_os/kuurier/apps/ios/Kuurier/Kuurier.xcodeproj
```

Debug build connects to `http://localhost:8080/api/v1`

### Database Access
```bash
PGPASSWORD=kuurier_dev_password psql -h localhost -U kuurier_dev -d kuurier_dev
```

---

## Current Test User

Database has a test user with:
- `trust_score = 100` (manually set for testing)
- Can access all features

To update trust score:
```sql
UPDATE users SET trust_score = 100 WHERE id = 'your-user-id';
```

---

## Known Issues / TODO

### Bugs to Fix
- [ ] Debug logging still in code (remove before production)

### Features Not Yet Implemented
- [ ] **Map View** - MapKit integration, heatmap, clusters
- [ ] **Events** - Full CRUD, RSVP functionality
- [ ] **Alerts/SOS** - Full implementation with push notifications
- [ ] **Push Notifications** - APNs integration
- [ ] **Vouching UI** - Allow users to vouch for each other
- [ ] **Location Services** - Get current location in compose view
- [ ] **Subscriptions** - Topic and location-based feed filtering

### API Endpoints Exist But iOS Not Implemented
- Topics (`GET /topics`)
- Subscriptions (`GET/POST/PUT/DELETE /subscriptions`)
- Events (`/events/*`)
- Alerts (`/alerts/*`)
- Geo/Map (`/geo/*`)

---

## Git Status

**Branch:** `feature/invite-system`

Recent commits:
- Fix post double-submit and feed refresh after creation
- Fix post creation endpoint and feed nil array issue
- Add error display and debug logging to post creation
- Restore original compose post Form layout
- Implement feed feature with post creation and pagination
- Add trust UI with locked states and level breakdown
- Fix invite system JSON parsing and share functionality
- Implement invite-only registration system

**Note:** CLAUDE.md is in `.gitignore` - do not commit it.

---

## API Reference (Quick)

### Auth
- `POST /auth/register` - Register/login with public key + invite code
- `POST /auth/verify` - Verify signature, get JWT token
- `GET /me` - Get current user profile
- `DELETE /me` - Delete account

### Feed
- `GET /feed` - Get feed (query: limit, offset)
- `POST /feed/posts` - Create post
- `GET /feed/posts/:id` - Get post
- `DELETE /feed/posts/:id` - Delete post
- `POST /feed/posts/:id/verify` - Upvote
- `POST /feed/posts/:id/flag` - Flag

### Invites
- `GET /invites` - List user's invites
- `POST /invites` - Generate invite
- `DELETE /invites/:code` - Revoke invite
- `GET /invites/validate/:code` - Validate (public)

---

## Next Steps

1. ~~Test posting functionality end-to-end~~ (Done - fixed double-submit bug)
2. Merge `feature/invite-system` PR into main
3. Implement Map view with MapKit
4. Or continue with Events/Alerts features
