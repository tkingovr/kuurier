# Kuurier Secrets Management

This project does **not** store secrets in the repository — not in plaintext, not encrypted, not at all. The canonical store is a GitHub Actions environment secret named `PRODUCTION_ENV` that holds the entire `.env` body.

## Why this approach

- **No `secrets.age` or similar encrypted blob in git** — removing that entire attack/leak surface.
- **One secret to manage**: rotating, viewing, or rebuilding the `.env` means touching one GitHub setting.
- **Access is already gated**: the `production` GitHub Actions environment requires manual approval or restricted branches, and GitHub keeps an audit log of secret reads.
- **Zero new tools**: we already use `secrets.SERVER_HOST` / `secrets.SERVER_USER` / `secrets.SERVER_SSH_KEY`. This is the same mechanism.

## Required secret keys

Set these inside the single `PRODUCTION_ENV` secret (one `KEY=value` per line, no quotes).

| Key | Required | Format | Notes |
|-----|----------|--------|-------|
| `DB_USER` | yes | string | Postgres user; usually `kuurier` |
| `DB_NAME` | yes | string | Postgres database; usually `kuurier` |
| `DB_PASSWORD` | yes | string (≥16 chars) | Generate: `openssl rand -base64 32` |
| `REDIS_PASSWORD` | yes | string (≥16 chars) | Same generator |
| `JWT_SECRET` | yes | string, **≥32 chars** | Prod refuses to boot if shorter |
| `ENCRYPTION_KEY` | yes | string, **exactly 32 chars** | AES-256 key, rotation requires re-encrypting stored data |
| `CORS_ALLOWED_ORIGINS` | yes | comma-separated URLs | e.g. `https://kuurier.com,https://app.kuurier.com` |
| `APNS_KEY_PATH` | no | file path | Apple Push Notification auth key path, if push enabled |
| `APNS_KEY_ID` | no | string | APNs key ID |
| `APNS_TEAM_ID` | no | string | Apple team ID |
| `APNS_BUNDLE_ID` | no | string | iOS bundle ID |
| `APNS_PRODUCTION` | no | `true`/`false` | Whether to use the production APNs endpoint |
| `MINIO_ENDPOINT` | no | host:port | MinIO endpoint if media uploads enabled |
| `MINIO_ACCESS_KEY` | no | string | MinIO access key |
| `MINIO_SECRET_KEY` | no | string | MinIO secret key |
| `MINIO_BUCKET` | no | string | Bucket name |
| `MINIO_USE_SSL` | no | `true`/`false` | TLS to MinIO |
| `FEED_MATERIALIZED` | no | `true`/`false` | Serve for_you feed from precomputed materialized_feeds table (worker populates every ~5 min). Default false. |

## One-time setup

1. **Capture the current `.env` from the production server:**
   ```
   ssh -p 2222 <your-user>@<server-host> 'cat ~/kuurier/.env'
   ```
   Copy the output.

2. **Add the secret in GitHub:**
   - Go to `Settings` → `Environments` → `production` on the `tkingovr/kuurier` repo.
   - Click `Add secret`.
   - Name: `PRODUCTION_ENV`
   - Value: paste the full `.env` content from step 1.
   - Save.

3. **Trigger a deploy** (manual dispatch or push anything to `main`). The deploy will now write `.env` from the GitHub secret, overwriting whatever was there.

4. **Keep a password-manager copy** of the same content (1Password/Bitwarden) as a disaster-recovery backup in case the GitHub secret is lost.

## Rotating a single secret

1. SSH is not required. Open the `PRODUCTION_ENV` secret in GitHub, edit the single line, save.
2. Trigger a deploy.
3. The new `.env` lands on the server and the API containers restart with the new values.

## Rotating `ENCRYPTION_KEY`

`ENCRYPTION_KEY` is special — it's used to encrypt data at rest (device-link payloads in the `devices` table; any other at-rest ciphertext). Rotating it requires re-encrypting that data or old ciphertext becomes unreadable.

Don't rotate `ENCRYPTION_KEY` casually. If you must:
1. Write a migration that reads all affected rows, decrypts with the old key, re-encrypts with the new key, writes them back.
2. Ship the migration + the new key together in one deploy.
3. Verify the migration ran cleanly before rolling out.

## Disaster recovery

If the GitHub secret is lost AND the server `.env` is lost:
- Restore from your password-manager backup (step 4 above). Paste it back into the GitHub secret.
- If neither backup exists: you will need to rotate every secret. JWT tokens become invalid (all users must re-authenticate). Encrypted device link payloads become unreadable (minor — they expire in 5 minutes anyway).

## Previous approach (deprecated)

Earlier deploys pulled `.env` values by inspecting the running containers' environment and parsing them back out. That was a one-time transition hack — it worked because the old containers from Feb 2026 retained their env at runtime. With Phase 1.5 that code is removed; the GitHub Actions secret is the sole source of truth.
