#!/bin/bash
set -e

# ============================================
# Kuurier Server Setup Script
# Run this on a fresh server to set up everything
# ============================================

echo ""
echo "╔════════════════════════════════════════╗"
echo "║     Kuurier Server Setup               ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    log_error "Don't run this as root. Run as a normal user with sudo access."
    exit 1
fi

# Step 1: Check Docker
log_info "Checking Docker installation..."
if ! command -v docker &> /dev/null; then
    log_warn "Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER
    log_warn "Please log out and back in, then run this script again."
    exit 0
fi

if ! docker info &> /dev/null; then
    log_error "Docker is installed but not running or you don't have permission."
    log_info "Try: sudo usermod -aG docker $USER && newgrp docker"
    exit 1
fi

log_info "Docker is ready: $(docker --version)"

# Step 2: Check Docker Compose
if ! docker compose version &> /dev/null; then
    log_error "Docker Compose plugin not found."
    log_info "Install with: sudo apt install docker-compose-plugin"
    exit 1
fi

log_info "Docker Compose is ready: $(docker compose version --short)"

# Step 3: Create directories
log_info "Creating directories..."
mkdir -p nginx certs

# Step 4: Check .env file
if [[ ! -f ".env" ]]; then
    log_warn ".env file not found. Creating template..."

    # Generate secrets
    JWT_SECRET=$(openssl rand -base64 32 | tr -d '\n')
    ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64 | head -c 32)
    DB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')

    cat > .env << EOF
# Database
DB_USER=kuurier
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=kuurier

# Security - KEEP THESE SECRET!
JWT_SECRET=${JWT_SECRET}
ENCRYPTION_KEY=${ENCRYPTION_KEY}

# CORS - Update with your domain
CORS_ALLOWED_ORIGINS=https://api.yourdomain.com
EOF

    chmod 600 .env
    log_warn "Created .env with generated secrets."
    log_warn "IMPORTANT: Save these values somewhere secure!"
    echo ""
    cat .env
    echo ""
    log_warn "Update CORS_ALLOWED_ORIGINS with your actual domain."
    log_info "Then run this script again."
    exit 0
fi

# Step 5: Validate .env
log_info "Validating .env..."
source .env

if [[ -z "$DB_PASSWORD" ]]; then
    log_error "DB_PASSWORD is not set in .env"
    exit 1
fi

if [[ -z "$JWT_SECRET" ]]; then
    log_error "JWT_SECRET is not set in .env"
    exit 1
fi

if [[ -z "$ENCRYPTION_KEY" ]]; then
    log_error "ENCRYPTION_KEY is not set in .env"
    exit 1
fi

# Check ENCRYPTION_KEY length
KEY_LEN=${#ENCRYPTION_KEY}
if [[ $KEY_LEN -ne 32 ]]; then
    log_error "ENCRYPTION_KEY must be exactly 32 characters (currently $KEY_LEN)"
    log_info "Generate new key: head -c 32 /dev/urandom | base64 | head -c 32"
    exit 1
fi

log_info ".env validation passed"

# Step 6: Build Docker image
log_info "Building Docker image..."
docker build -t kuurier-server:latest .

# Step 7: Start services
log_info "Starting services..."
docker compose -f docker-compose.prod.yml up -d

# Step 8: Wait for health
log_info "Waiting for services to be healthy..."
sleep 15

# Check health
ATTEMPTS=0
MAX_ATTEMPTS=30
while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
    if curl -sf http://localhost/health > /dev/null 2>&1; then
        echo ""
        log_info "Health check passed!"
        break
    fi
    echo -n "."
    sleep 2
    ((ATTEMPTS++))
done

if [[ $ATTEMPTS -eq $MAX_ATTEMPTS ]]; then
    echo ""
    log_error "Services failed to become healthy."
    log_info "Check logs: docker compose -f docker-compose.prod.yml logs"
    exit 1
fi

# Done
echo ""
echo "╔════════════════════════════════════════╗"
echo "║     Setup Complete!                    ║"
echo "╚════════════════════════════════════════╝"
echo ""
log_info "API is running at http://localhost"
log_info "Health check: curl http://localhost/health"
echo ""
log_info "Next steps:"
echo "  1. Point your domain to this server (A record)"
echo "  2. Get SSL certificate: sudo certbot certonly --standalone -d api.yourdomain.com"
echo "  3. Copy certs: sudo cp /etc/letsencrypt/live/yourdomain/fullchain.pem certs/"
echo "  4. Copy certs: sudo cp /etc/letsencrypt/live/yourdomain/privkey.pem certs/"
echo "  5. Update nginx/active.conf to enable HTTPS"
echo "  6. Restart: docker compose -f docker-compose.prod.yml restart nginx"
echo ""
