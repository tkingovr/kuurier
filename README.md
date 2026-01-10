# Kuurier

**The pulse of the movement, delivered.**

Kuurier is a secure, privacy-first platform for activists to organize, communicate, and stay informed. Built with end-to-end encryption and anonymous authentication by design.

No email. No phone number. No tracking. Just cryptographic keys.

---

## Why Kuurier?

Activists face increasing surveillance and censorship on mainstream platforms. Group chats are noisy and overwhelming. Important information gets buried. There's no way to filter what matters to *you* in *your* area.

Kuurier solves this:

- **Subscribe to what matters** — Follow topics (climate, labor, housing) and locations. Get signal, not noise.
- **See the world** — A global map showing activist activity in real-time. Zoom into any hotspot.
- **Organize events** — Create and discover protests, strikes, fundraisers, mutual aid.
- **Emergency alerts** — SOS system for when help is needed. Trusted activists can broadcast to nearby users.
- **Web of trust** — Build credibility through community vouching, not corporate verification.

---

## Security Model

Kuurier is built for people whose safety depends on their privacy.

| Feature | Implementation |
|---------|----------------|
| **Anonymous accounts** | Ed25519 keypair authentication. No email, phone, or personal info required. |
| **End-to-end encryption** | Messages encrypted on-device before transmission. |
| **Minimal data** | We can't leak what we don't store. |
| **Panic button** | Instantly wipe all local data if needed. |
| **Duress mode** | Secondary PIN opens a fake empty account. |
| **No IP logging** | Request logs contain no identifying information. |
| **Open source** | Full transparency. Audit the code yourself. |

---

## Architecture

```
kuurier/
├── apps/
│   └── ios/                 # iOS app (Swift/SwiftUI)
├── server/                  # Backend API (Go)
│   ├── cmd/                 # Entry points
│   ├── internal/            # Core logic
│   └── migrations/          # Database schema
├── infra/                   # Docker, deployment
└── docs/                    # Documentation
```

### Tech Stack

| Layer | Technology |
|-------|------------|
| iOS | Swift, SwiftUI, CryptoKit |
| Backend | Go, Gin framework |
| Database | PostgreSQL + PostGIS |
| Cache | Redis |
| Maps | MapLibre + OpenStreetMap |

---

## Quick Start

### Prerequisites

- Docker & Docker Compose
- Go 1.22+
- Xcode 15+ (for iOS)

### 1. Clone the repo

```bash
git clone https://github.com/YOUR_USERNAME/kuurier.git
cd kuurier
```

### 2. Start the development environment

```bash
make dev
```

This starts PostgreSQL, Redis, and MinIO.

### 3. Run database migrations

```bash
make db-migrate
```

### 4. Start the server

```bash
make server
```

Server runs at `http://localhost:8080`

### 5. Open the iOS app

Open `apps/ios/Kuurier/Kuurier.xcodeproj` in Xcode, select a simulator, and run.

---

## API Overview

### Authentication

Kuurier uses challenge-response authentication with Ed25519 signatures. No passwords.

```
POST /api/v1/auth/register   # Submit public key, get challenge
POST /api/v1/auth/verify     # Submit signed challenge, get JWT
```

### Feed

```
GET  /api/v1/feed            # Personalized feed based on subscriptions
POST /api/v1/feed/posts      # Create a post
GET  /api/v1/topics          # List available topics
```

### Subscriptions

```
GET    /api/v1/subscriptions      # List your subscriptions
POST   /api/v1/subscriptions      # Subscribe to topic or location
DELETE /api/v1/subscriptions/:id  # Unsubscribe
```

### Map

```
GET /api/v1/map/heatmap      # Global activity heatmap
GET /api/v1/map/clusters     # Clustered posts for map view
GET /api/v1/map/nearby       # Posts near a location
```

### Events

```
GET    /api/v1/events            # List upcoming events
POST   /api/v1/events            # Create event (requires trust score 50+)
POST   /api/v1/events/:id/rsvp   # RSVP to event
GET    /api/v1/events/nearby     # Events near a location
```

### SOS Alerts

```
GET  /api/v1/alerts              # List active alerts
POST /api/v1/alerts              # Create alert (verified users only)
POST /api/v1/alerts/:id/respond  # Respond to alert
GET  /api/v1/alerts/nearby       # Alerts in your area
```

---

## Trust System

Users build credibility through community vouching:

| Trust Score | Capabilities |
|-------------|--------------|
| 0 | Browse only |
| 30+ | Can create posts |
| 50+ | Can create events |
| 100+ | Can broadcast SOS alerts |

Trust is earned by:
- Being vouched for by existing trusted users
- Active participation over time
- Verification by established organizations

---

## Contributing

Kuurier is built by and for activists. Contributions welcome.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Security is non-negotiable. Every PR is reviewed for security implications.
- Privacy by design. If you don't need to store data, don't.
- Keep it simple. Complexity is the enemy of security.

---

## Security Vulnerabilities

Found a security issue? **Do not open a public issue.**

Email security concerns to: [security contact to be added]

Please allow reasonable time for fixes before public disclosure.

---

## Roadmap

- [x] Core authentication system
- [x] Feed with topic/location subscriptions
- [x] Event creation and RSVP
- [x] SOS alert system
- [x] iOS app foundation
- [ ] Push notifications
- [ ] Android app
- [ ] E2E encrypted direct messages
- [ ] Offline mode with sync
- [ ] Decentralized federation

---

## License

[AGPL-3.0](LICENSE) — If you modify and deploy Kuurier, you must share your changes.

---

## Acknowledgments

Built with solidarity for everyone fighting for a better world.

*Stay safe. Stay connected. Stay organized.*
