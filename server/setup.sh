#!/bin/bash
set -e

# ============================================
# Kuurier Server - One-Command Setup
# ============================================
#
# Deploys the full Kuurier stack on any fresh Linux server:
#   API + Website + Web App + PostgreSQL + Redis + Nginx + TLS
#
# Usage:
#   ./setup.sh                         # Interactive setup
#   ./setup.sh --domain example.com    # Non-interactive with domain
#
# Requirements:
#   - Ubuntu/Debian server with sudo access
#   - Domain pointed to this server (A records)
#   - Ports 80 and 443 open
#
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.prod.yml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${BOLD}==> $1${NC}"; }

# ============================================
# Parse args
# ============================================

DOMAIN=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain|-d) DOMAIN="$2"; shift 2 ;;
        --help|-h)
            echo ""
            echo "Kuurier Server Setup"
            echo ""
            echo "Usage:"
            echo "  ./setup.sh                         Interactive setup"
            echo "  ./setup.sh --domain example.com    Set base domain"
            echo ""
            echo "The script will configure:"
            echo "  api.DOMAIN    - API server"
            echo "  DOMAIN        - Project website"
            echo "  app.DOMAIN    - Web application"
            echo ""
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================
# Banner
# ============================================

echo ""
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║                                           ║"
echo "  ║          Kuurier Server Setup              ║"
echo "  ║                                           ║"
echo "  ║   API + Website + Web App + TLS            ║"
echo "  ║                                           ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# Don't run as root
if [[ $EUID -eq 0 ]]; then
    log_error "Don't run as root. Use a normal user with sudo access."
    exit 1
fi

# ============================================
# Step 1: Dependencies
# ============================================

log_step "Checking dependencies..."

# Docker
if ! command -v docker &> /dev/null; then
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    log_warn "Docker installed. Log out and back in, then re-run this script."
    exit 0
fi

if ! docker info &> /dev/null 2>&1; then
    log_error "Docker not running or no permission. Try: sudo usermod -aG docker $USER && newgrp docker"
    exit 1
fi
log_success "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"

# Docker Compose
if ! docker compose version &> /dev/null 2>&1; then
    log_error "Docker Compose plugin not found. Install: sudo apt install docker-compose-plugin"
    exit 1
fi
log_success "Docker Compose $(docker compose version --short)"

# Certbot
if ! command -v certbot &> /dev/null; then
    log_info "Installing Certbot..."
    sudo apt-get update -qq && sudo apt-get install -y -qq certbot > /dev/null
fi
log_success "Certbot installed"

# ============================================
# Step 2: Domain configuration
# ============================================

log_step "Domain configuration..."

if [[ -z "$DOMAIN" ]]; then
    echo ""
    read -p "  Enter your base domain (e.g. kuurier.com): " DOMAIN
fi

if [[ -z "$DOMAIN" ]]; then
    log_error "Domain is required."
    exit 1
fi

API_DOMAIN="api.${DOMAIN}"
APP_DOMAIN="app.${DOMAIN}"

echo ""
log_info "Domains:"
echo "  API:     $API_DOMAIN"
echo "  Website: $DOMAIN"
echo "  Web App: $APP_DOMAIN"
echo ""

# Verify DNS
log_info "Checking DNS records..."
FAILS=0
for d in "$DOMAIN" "$API_DOMAIN" "$APP_DOMAIN"; do
    IP=$(dig +short "$d" A 2>/dev/null | head -1)
    if [[ -z "$IP" ]]; then
        log_error "$d has no A record"
        FAILS=1
    else
        log_success "$d -> $IP"
    fi
done

if [[ $FAILS -eq 1 ]]; then
    echo ""
    log_error "DNS not ready. Create A records pointing all 3 domains to this server's IP."
    SERVER_IP=$(curl -sf https://ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
    echo ""
    echo "  ${DOMAIN}       A  ${SERVER_IP}"
    echo "  api.${DOMAIN}   A  ${SERVER_IP}"
    echo "  app.${DOMAIN}   A  ${SERVER_IP}"
    echo ""
    log_info "After adding DNS records (wait 1-5 min), re-run this script."
    exit 1
fi

# ============================================
# Step 3: Environment file
# ============================================

log_step "Environment configuration..."

mkdir -p nginx certs certbot-webroot website webapp-build

if [[ ! -f ".env" ]]; then
    log_info "Generating .env with secure random secrets..."

    DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+\n' | head -c 32)
    JWT_SECRET=$(openssl rand -base64 32 | tr -d '/+\n' | head -c 44)
    ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '/+\n' | head -c 32)
    REDIS_PASSWORD=$(openssl rand -hex 32)

    cat > .env << EOF
# Database
DB_USER=kuurier
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=kuurier

# Security
JWT_SECRET=${JWT_SECRET}
ENCRYPTION_KEY=${ENCRYPTION_KEY}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}

# CORS
CORS_ALLOWED_ORIGINS=https://${API_DOMAIN},https://${DOMAIN},https://${APP_DOMAIN}

# Blue-Green (managed by deploy.sh)
BLUE_VERSION=latest
GREEN_VERSION=latest
EOF

    chmod 600 .env
    log_success ".env created with generated secrets"
else
    log_success ".env already exists"

    # Ensure CORS includes all domains
    if ! grep -q "$APP_DOMAIN" .env; then
        sed -i "s|CORS_ALLOWED_ORIGINS=.*|CORS_ALLOWED_ORIGINS=https://${API_DOMAIN},https://${DOMAIN},https://${APP_DOMAIN}|" .env
        log_info "Updated CORS_ALLOWED_ORIGINS with all domains"
    fi
fi

# ============================================
# Step 4: Update nginx configs with actual domain
# ============================================

log_step "Configuring nginx for ${DOMAIN}..."

# Update server_name in configs
for conf in nginx/active.conf nginx/website.conf nginx/webapp.conf; do
    if [[ -f "$conf" ]]; then
        case "$(basename "$conf")" in
            active.conf)
                sed -i "s|server_name api\..*\.com;|server_name ${API_DOMAIN};|" "$conf"
                sed -i "s|server_name api\..*\.org;|server_name ${API_DOMAIN};|" "$conf"
                ;;
            website.conf)
                sed -i "s|server_name .*\.com;|server_name ${DOMAIN};|" "$conf"
                sed -i "s|server_name .*\.org;|server_name ${DOMAIN};|" "$conf"
                ;;
            webapp.conf)
                sed -i "s|server_name app\..*\.com;|server_name ${APP_DOMAIN};|" "$conf"
                sed -i "s|server_name app\..*\.org;|server_name ${APP_DOMAIN};|" "$conf"
                ;;
        esac
    fi
done

log_success "Nginx configs updated"

# ============================================
# Step 5: Build & start services
# ============================================

log_step "Building Docker image..."
docker build -t kuurier-server:latest .
log_success "Image built"

log_step "Starting services..."
docker compose -f "$COMPOSE_FILE" up -d
log_success "Services starting"

# Wait for health
log_info "Waiting for API to be healthy..."
ATTEMPTS=0
while [[ $ATTEMPTS -lt 30 ]]; do
    if docker exec kuurier-api-blue wget -qO- http://localhost:8080/health > /dev/null 2>&1; then
        log_success "API is healthy"
        break
    fi
    echo -n "."
    sleep 2
    ((ATTEMPTS++))
done

if [[ $ATTEMPTS -eq 30 ]]; then
    echo ""
    log_error "API failed health check. Check: docker compose -f $COMPOSE_FILE logs api-blue"
    exit 1
fi

# ============================================
# Step 6: TLS certificates
# ============================================

log_step "Setting up TLS certificates..."

if [[ -f "certs/fullchain.pem" ]]; then
    EXISTING_DOMAINS=$(openssl x509 -in certs/fullchain.pem -noout -ext subjectAltName 2>/dev/null | grep -oP 'DNS:\K[^,\s]+' | tr '\n' ' ')
    log_info "Existing cert covers: $EXISTING_DOMAINS"

    # Check if all domains are covered
    ALL_COVERED=true
    for d in "$DOMAIN" "$API_DOMAIN" "$APP_DOMAIN"; do
        if ! echo "$EXISTING_DOMAINS" | grep -q "$d"; then
            ALL_COVERED=false
        fi
    done

    if $ALL_COVERED; then
        log_success "TLS cert already covers all domains"
    else
        log_info "Expanding cert to cover all domains..."
        docker compose -f "$COMPOSE_FILE" stop nginx
        sudo certbot certonly --standalone \
            --cert-name "$API_DOMAIN" \
            -d "$API_DOMAIN" -d "$DOMAIN" -d "$APP_DOMAIN" \
            --expand --non-interactive --agree-tos
        sudo cp "/etc/letsencrypt/live/${API_DOMAIN}/fullchain.pem" certs/fullchain.pem
        sudo cp "/etc/letsencrypt/live/${API_DOMAIN}/privkey.pem" certs/privkey.pem
        sudo chown "$USER:$USER" certs/*.pem
        docker compose -f "$COMPOSE_FILE" up -d nginx
        log_success "TLS cert expanded"
    fi
else
    log_info "Obtaining TLS certificate..."
    docker compose -f "$COMPOSE_FILE" stop nginx

    sudo certbot certonly --standalone \
        -d "$API_DOMAIN" -d "$DOMAIN" -d "$APP_DOMAIN" \
        --non-interactive --agree-tos \
        --register-unsafely-without-email

    sudo cp "/etc/letsencrypt/live/${API_DOMAIN}/fullchain.pem" certs/fullchain.pem
    sudo cp "/etc/letsencrypt/live/${API_DOMAIN}/privkey.pem" certs/privkey.pem
    sudo chown "$USER:$USER" certs/*.pem
    docker compose -f "$COMPOSE_FILE" up -d nginx
    log_success "TLS cert obtained"
fi

# ============================================
# Step 7: Verify
# ============================================

log_step "Verifying deployment..."

sleep 3

PASS=0
FAIL=0

check() {
    local label=$1 url=$2 expect=$3
    CODE=$(curl -sf -o /dev/null -w "%{http_code}" --resolve "${url##https://}:443:127.0.0.1" "$url" 2>/dev/null || echo "000")
    if [[ "$CODE" == "$expect" ]]; then
        log_success "$label ($CODE)"
        ((PASS++))
    else
        log_error "$label (got $CODE, expected $expect)"
        ((FAIL++))
    fi
}

check "API health"     "https://${API_DOMAIN}/health"  "200"
check "Website"        "https://${DOMAIN}/"            "200"
check "Web App"        "https://${APP_DOMAIN}/"        "200"
check "SPA fallback"   "https://${APP_DOMAIN}/events"  "200"
check "API via app"    "https://${APP_DOMAIN}/health"  "200"

echo ""

# ============================================
# Done
# ============================================

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║                                           ║"
echo "  ║          Setup Complete!                   ║"
echo "  ║                                           ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

echo "  Endpoints:"
echo "    API:      https://${API_DOMAIN}"
echo "    Website:  https://${DOMAIN}"
echo "    Web App:  https://${APP_DOMAIN}"
echo ""
echo "  Manage:"
echo "    ./deploy.sh --status       Show status"
echo "    ./deploy.sh                Deploy new version"
echo "    ./deploy.sh --rollback     Rollback"
echo ""

if [[ $FAIL -gt 0 ]]; then
    log_warn "$FAIL checks failed. Review the output above."
else
    log_success "All $PASS checks passed!"
fi

echo ""
