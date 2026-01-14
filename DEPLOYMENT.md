# Kuurier Deployment Guide

This guide covers deploying Kuurier to a production server.

## Prerequisites

- Ubuntu 22.04+ or Debian 12+ server (4GB+ RAM recommended)
- Domain name pointing to your server
- Apple Developer account (for push notifications)

## Quick Start

```bash
# 1. Clone repository
git clone https://github.com/your-org/kuurier.git
cd kuurier

# 2. Configure environment
cd infra/docker
cp .env.production.example .env.production
nano .env.production  # Fill in all values

# 3. Generate secrets
echo "JWT_SECRET=$(openssl rand -base64 32)"
echo "ENCRYPTION_KEY=$(openssl rand -base64 32 | head -c 32)"
echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
echo "MINIO_ACCESS_KEY=$(openssl rand -hex 16)"
echo "MINIO_SECRET_KEY=$(openssl rand -base64 32)"

# 4. Start services
docker-compose -f docker-compose.prod.yml up -d

# 5. Run migrations
docker-compose -f docker-compose.prod.yml --profile migrate up migrate

# 6. Set up SSL (see below)
```

## Detailed Setup

### 1. Server Preparation

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo apt install docker-compose-plugin

# Install Nginx
sudo apt install nginx certbot python3-certbot-nginx

# Logout and login for docker group to take effect
```

### 2. Configure Environment

Copy and edit the production environment file:

```bash
cd /opt/kuurier/infra/docker
cp .env.production.example .env.production
```

Required settings:

| Variable | Description | How to Generate |
|----------|-------------|-----------------|
| `POSTGRES_PASSWORD` | Database password | `openssl rand -base64 24` |
| `JWT_SECRET` | JWT signing key | `openssl rand -base64 32` |
| `ENCRYPTION_KEY` | Data encryption key | `openssl rand -base64 32 \| head -c 32` |
| `MINIO_ACCESS_KEY` | S3 access key | `openssl rand -hex 16` |
| `MINIO_SECRET_KEY` | S3 secret key | `openssl rand -base64 32` |

### 3. Deploy Application

```bash
# Build and start all services
docker-compose -f docker-compose.prod.yml up -d --build

# Check status
docker-compose -f docker-compose.prod.yml ps

# View logs
docker-compose -f docker-compose.prod.yml logs -f api
```

### 4. Run Database Migrations

```bash
# First time setup
docker-compose -f docker-compose.prod.yml --profile migrate up migrate

# Or manually
docker exec -it kuurier-api sh -c "
  for f in /app/migrations/*.sql; do
    psql \$DATABASE_URL -f \$f
  done
"
```

### 5. Configure SSL with Nginx

```bash
# Copy nginx config
sudo cp /opt/kuurier/infra/nginx/kuurier.conf /etc/nginx/sites-available/kuurier

# Edit and replace YOUR_DOMAIN
sudo nano /etc/nginx/sites-available/kuurier

# Enable site
sudo ln -s /etc/nginx/sites-available/kuurier /etc/nginx/sites-enabled/

# Remove default site
sudo rm /etc/nginx/sites-enabled/default

# Test config
sudo nginx -t

# Get SSL certificate
sudo certbot --nginx -d your-domain.com

# Reload nginx
sudo systemctl reload nginx
```

### 6. Configure Push Notifications

1. Go to [Apple Developer Portal](https://developer.apple.com)
2. Create an APNs Auth Key (Keys > Create Key > Apple Push Notifications service)
3. Download the .p8 file
4. Upload to server:

```bash
sudo mkdir -p /opt/kuurier/keys
sudo cp AuthKey_XXXXXXXX.p8 /opt/kuurier/keys/
sudo chmod 600 /opt/kuurier/keys/AuthKey_XXXXXXXX.p8
```

5. Update `.env.production`:

```bash
APNS_KEY_PATH=/opt/kuurier/keys/AuthKey_XXXXXXXX.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_BUNDLE_ID=com.yourcompany.kuurier
APNS_PRODUCTION=true
```

6. Restart API:

```bash
docker-compose -f docker-compose.prod.yml restart api
```

## iOS App Configuration

Before building for production:

1. Edit `apps/ios/Kuurier/Kuurier/Core/Config/AppConfig.swift`
2. Change `productionAPIURL` to your server URL:

```swift
private static let productionAPIURL = "https://api.yourdomain.com/api/v1"
```

3. Build with Release configuration in Xcode

## Maintenance

### View Logs

```bash
# All services
docker-compose -f docker-compose.prod.yml logs -f

# Specific service
docker-compose -f docker-compose.prod.yml logs -f api

# Nginx
sudo tail -f /var/log/nginx/kuurier_access.log
sudo tail -f /var/log/nginx/kuurier_error.log
```

### Backup Database

```bash
# Create backup
docker exec kuurier-postgres pg_dump -U kuurier kuurier > backup_$(date +%Y%m%d).sql

# Restore backup
docker exec -i kuurier-postgres psql -U kuurier kuurier < backup_20240115.sql
```

### Update Application

```bash
cd /opt/kuurier
git pull

# Rebuild and restart
docker-compose -f infra/docker/docker-compose.prod.yml up -d --build

# Run new migrations if any
docker-compose -f infra/docker/docker-compose.prod.yml --profile migrate up migrate
```

### Monitor Resources

```bash
# Container stats
docker stats

# Database connections
docker exec kuurier-postgres psql -U kuurier -c "SELECT count(*) FROM pg_stat_activity;"

# Redis memory
docker exec kuurier-redis redis-cli info memory | grep used_memory_human
```

## Troubleshooting

### API Not Starting

```bash
# Check logs
docker-compose -f docker-compose.prod.yml logs api

# Common issues:
# - Database not ready: wait for postgres healthcheck
# - Missing environment variables: check .env.production
# - Port conflict: check if 8080 is in use
```

### WebSocket Connection Failed

```bash
# Check nginx config has WebSocket support
# Ensure these headers in nginx:
#   proxy_set_header Upgrade $http_upgrade;
#   proxy_set_header Connection "upgrade";

# Check API logs
docker-compose -f docker-compose.prod.yml logs api | grep -i websocket
```

### Push Notifications Not Working

```bash
# Check APNs configuration
docker exec kuurier-api env | grep APNS

# Verify key file exists and is readable
docker exec kuurier-api ls -la /opt/kuurier/keys/

# Check API logs for APNs errors
docker-compose -f docker-compose.prod.yml logs api | grep -i apns
```

### Database Connection Issues

```bash
# Check postgres is healthy
docker-compose -f docker-compose.prod.yml ps postgres

# Check connection count
docker exec kuurier-postgres psql -U kuurier -c "SELECT count(*) FROM pg_stat_activity;"

# If too many connections, adjust DB_MAX_CONNS in .env.production
```

## Security Checklist

- [ ] Strong passwords generated for all services
- [ ] SSL/TLS enabled with valid certificate
- [ ] Firewall configured (only 80, 443 open)
- [ ] SSH key authentication (disable password auth)
- [ ] Regular backups configured
- [ ] Log rotation enabled
- [ ] Environment file permissions restricted (chmod 600)
- [ ] APNs key file permissions restricted

## Scaling

For higher load:

1. **Vertical scaling**: Upgrade server (more CPU/RAM)
2. **Database**: Add read replicas, increase `DB_MAX_CONNS`
3. **Redis**: Upgrade to Redis Cluster
4. **API**: Run multiple containers behind load balancer
5. **Storage**: Move to AWS S3 or similar

See architecture documentation for scaling recommendations.
