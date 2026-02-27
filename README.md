# Kuurier

**The Activist OS.**

Kuurier is an activist operating system — a secure platform to organize, communicate, and stay informed. Built with end-to-end encryption and anonymous authentication by design.

No email. No phone number. No tracking. Just cryptographic keys.

---

## Why Kuurier?

Activists face increasing surveillance and censorship on mainstream platforms. Group chats are noisy and overwhelming. Important information gets buried. There's no way to filter what matters to *you* in *your* area.

Kuurier solves this:

- **Subscribe to what matters** — Follow topics (climate, labor, housing) and locations. Get signal, not noise.
- **See the world** — A global map showing activist activity in real-time. Zoom into any hotspot.
- **Organize events** — Create and discover protests, strikes, fundraisers, mutual aid.
- **Emergency alerts** — SOS system for when help is needed. Trusted activists can broadcast to nearby users.
- **Web of trust** — Build credibility through community vouching. No central authority decides who's trustworthy.

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
| **Invite-only** | Web of trust — new users join through existing trusted members. |
| **Open source** | Full transparency. Audit the code yourself. |

---

## Architecture

```
kuurier/
├── apps/
│   ├── ios/                 # iOS app (Swift/SwiftUI)
│   ├── web/                 # Web app (SvelteKit SPA)
│   └── desktop/             # Desktop app (Tauri + SvelteKit)
├── server/                  # Backend API (Go) + deployment configs
│   ├── cmd/                 # Entry points
│   ├── internal/            # Core logic
│   ├── migrations/          # Database schema
│   ├── nginx/               # Nginx configs (API, website, web app)
│   └── setup.sh             # One-command server deployment
├── website/                 # Static project website (HTML)
└── README.md
```

### Tech Stack

| Layer | Technology |
|-------|------------|
| iOS | Swift, SwiftUI, CryptoKit |
| Web | SvelteKit, TypeScript |
| Desktop | Tauri, SvelteKit |
| Backend | Go, Gin framework |
| Database | PostgreSQL + PostGIS |
| Cache | Redis |
| Maps | Leaflet + OpenStreetMap |
| Proxy | Nginx (blue-green deployment) |
| TLS | Let's Encrypt (auto-renewal) |

---

## Deploy Your Own Server

Kuurier is designed to be self-hosted. One script gets you a full production deployment with HTTPS, blue-green deployments, and zero-downtime updates.

### Prerequisites

- A Linux server (Ubuntu/Debian recommended, 1GB+ RAM)
- A domain with 3 A records pointing to your server:
  - `yourdomain.com` → your server IP
  - `api.yourdomain.com` → your server IP
  - `app.yourdomain.com` → your server IP
- Ports 80 and 443 open

### One-command setup

```bash
# Clone the repo
git clone https://github.com/tkingovr/kuurier.git
cd kuurier/server

# Run setup (installs Docker if needed, generates secrets, gets TLS certs)
./setup.sh --domain yourdomain.com
```

That's it. The script handles everything:
1. Installs Docker and Docker Compose (if missing)
2. Generates secure `.env` with random secrets
3. Builds the API server Docker image
4. Starts PostgreSQL, Redis, Nginx, and the API (blue-green)
5. Obtains TLS certificates from Let's Encrypt for all 3 domains
6. Verifies all endpoints are working

### What you get

| URL | What |
|-----|------|
| `https://yourdomain.com` | Project website |
| `https://app.yourdomain.com` | Web application (SPA) |
| `https://api.yourdomain.com` | API server |

### Managing your deployment

```bash
# Check status
./deploy.sh --status

# Deploy a new version (zero-downtime blue-green)
./deploy.sh

# Rollback to previous version
./deploy.sh --rollback
```

---

## Local Development

### Prerequisites

- Go 1.22+
- Docker & Docker Compose
- Node.js 20+ (for web app)
- Xcode 15+ (for iOS)

### Start the dev environment

```bash
# Start database and Redis
cd server
docker compose up -d postgres redis

# Run the API server
go run cmd/server/main.go

# In another terminal — run the web app
cd apps/web
npm install
npm run dev
```

The API runs at `http://localhost:8080` and the web app at `http://localhost:5173`.

---

## API Overview

### Authentication

Kuurier uses challenge-response authentication with Ed25519 signatures. No passwords.

```
POST /api/v1/auth/register     # Submit public key + invite code
POST /api/v1/auth/challenge    # Request a challenge
POST /api/v1/auth/verify       # Sign challenge, get JWT
```

### Core Endpoints

```
GET  /api/v1/feed              # Personalized feed
POST /api/v1/feed/posts        # Create a post
GET  /api/v1/events            # List events
POST /api/v1/events            # Create event
GET  /api/v1/alerts            # Active SOS alerts
POST /api/v1/alerts            # Create alert
GET  /api/v1/map/clusters      # Map data
```

### Invites & Trust

```
POST /api/v1/invites           # Generate invite code (trust 30+)
GET  /api/v1/invites           # List your invites
GET  /api/v1/invites/validate/:code  # Check if code is valid
```

---

## Trust System

Users build credibility through community vouching:

| Trust Score | Capabilities |
|-------------|--------------|
| 0 | Browse only |
| 15 | New user (joined via invite) |
| 30+ | Can create posts, generate invites |
| 50+ | Can create events |
| 100 | Can broadcast SOS alerts |

Trust is earned through vouches from existing trusted users. The system is fully decentralized — no admin approvals.

---

## Contributing

Kuurier is built by and for activists. Contributions welcome.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Guidelines

- Security is non-negotiable. Every PR is reviewed for security implications.
- Privacy by design. If you don't need to store data, don't.
- Keep it simple. Complexity is the enemy of security.

---

## Security Vulnerabilities

Found a security issue? **Do not open a public issue.**

Please allow reasonable time for fixes before public disclosure.

---

## Roadmap

- [x] Anonymous Ed25519 authentication
- [x] Invite-only web of trust
- [x] Feed with topic/location subscriptions
- [x] Event creation and RSVP
- [x] SOS alert system
- [x] Real-time WebSocket messaging
- [x] News feed with RSS aggregation
- [x] iOS app
- [x] Web app (SvelteKit SPA)
- [x] Desktop app (Tauri)
- [x] One-command server deployment
- [x] Blue-green zero-downtime deploys
- [ ] Push notifications (APNs)
- [ ] Android app
- [ ] E2E encrypted direct messages
- [ ] Offline mode with sync
- [ ] Decentralized federation

---

## License

[AGPL-3.0](LICENSE) — If you modify and deploy Kuurier, you must share your changes.

---

*Stay safe. Stay connected. Stay organized.*
