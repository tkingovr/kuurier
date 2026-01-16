#!/bin/bash
set -e

# ============================================
# Kuurier Blue-Green Deployment Script
# ============================================
#
# Usage:
#   ./deploy.sh                    # Deploy to idle environment
#   ./deploy.sh --rollback         # Switch back to previous environment
#   ./deploy.sh --status           # Show current status
#   ./deploy.sh --build            # Build image only (no deploy)
#
# ============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# State file to track active environment
STATE_FILE="$SCRIPT_DIR/.deploy-state"
COMPOSE_FILE="docker-compose.prod.yml"

# ============================================
# Helper Functions
# ============================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

get_active_env() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "blue"  # Default to blue
    fi
}

get_idle_env() {
    local active=$(get_active_env)
    if [[ "$active" == "blue" ]]; then
        echo "green"
    else
        echo "blue"
    fi
}

set_active_env() {
    echo "$1" > "$STATE_FILE"
}

health_check() {
    local env=$1
    local max_attempts=30
    local attempt=1
    local container="kuurier-api-${env}"

    log_info "Health checking $env environment..."

    while [[ $attempt -le $max_attempts ]]; do
        if docker exec "$container" wget -qO- http://localhost:8080/health 2>/dev/null; then
            log_success "$env is healthy!"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done

    echo ""
    log_error "$env failed health check after $max_attempts attempts"
    return 1
}

switch_traffic() {
    local target=$1
    local nginx_conf="$SCRIPT_DIR/nginx/active.conf"

    log_info "Switching traffic to $target..."

    # Generate new nginx config
    cat > "$nginx_conf" << EOF
# Active environment: ${target^^}
# Switched at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# This file is managed by deploy.sh - do not edit manually

server {
    listen 80;
    server_name _;

    location /health {
        proxy_pass http://api-${target}/health;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    location / {
        proxy_pass http://api-${target};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";

        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF

    # Reload nginx (no downtime)
    if docker exec kuurier-nginx nginx -t 2>/dev/null; then
        docker exec kuurier-nginx nginx -s reload
        set_active_env "$target"
        log_success "Traffic switched to $target"
    else
        log_error "Nginx config validation failed!"
        return 1
    fi
}

# ============================================
# Commands
# ============================================

show_status() {
    local active=$(get_active_env)
    local idle=$(get_idle_env)

    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║       Kuurier Deployment Status        ║"
    echo "╠════════════════════════════════════════╣"
    echo "║                                        ║"
    printf "║  Active Environment:  ${GREEN}%-16s${NC} ║\n" "${active^^}"
    printf "║  Idle Environment:    ${YELLOW}%-16s${NC} ║\n" "${idle^^}"
    echo "║                                        ║"
    echo "╠════════════════════════════════════════╣"
    echo "║  Container Status:                     ║"
    echo "╚════════════════════════════════════════╝"
    echo ""

    docker ps --filter "name=kuurier" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
    echo ""
}

build_image() {
    local version=${1:-$(date +%Y%m%d-%H%M%S)}

    log_info "Building kuurier-server:$version..."

    docker build -t kuurier-server:$version -t kuurier-server:latest .

    log_success "Built kuurier-server:$version"
    echo "$version"
}

deploy() {
    local active=$(get_active_env)
    local idle=$(get_idle_env)
    local version=${1:-latest}

    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║     Kuurier Blue-Green Deployment      ║"
    echo "╚════════════════════════════════════════╝"
    echo ""

    log_info "Active: $active | Deploying to: $idle"

    # Step 1: Build new image if Dockerfile exists
    if [[ -f "$SCRIPT_DIR/Dockerfile" ]] && [[ "$version" == "latest" ]]; then
        version=$(build_image)
    fi

    # Step 2: Update idle environment
    log_info "Updating $idle environment with version $version..."

    if [[ "$idle" == "blue" ]]; then
        BLUE_VERSION=$version docker compose -f "$COMPOSE_FILE" up -d api-blue
    else
        GREEN_VERSION=$version docker compose -f "$COMPOSE_FILE" up -d api-green
    fi

    # Step 3: Health check
    if ! health_check "$idle"; then
        log_error "Deployment failed - $idle is unhealthy"
        log_warning "Rolling back..."
        docker compose -f "$COMPOSE_FILE" restart "api-$idle"
        exit 1
    fi

    # Step 4: Switch traffic
    switch_traffic "$idle"

    echo ""
    log_success "Deployment complete!"
    log_info "Previous environment ($active) is now idle and available for rollback"
    echo ""
}

rollback() {
    local active=$(get_active_env)
    local idle=$(get_idle_env)

    echo ""
    log_warning "Rolling back from $active to $idle..."

    # Health check the rollback target first
    if ! health_check "$idle"; then
        log_error "Rollback target ($idle) is unhealthy! Manual intervention required."
        exit 1
    fi

    switch_traffic "$idle"

    log_success "Rollback complete! Now serving from $idle"
    echo ""
}

# ============================================
# Initial Setup (first deployment)
# ============================================

init() {
    echo ""
    echo "╔════════════════════════════════════════╗"
    echo "║     Kuurier Initial Setup              ║"
    echo "╚════════════════════════════════════════╝"
    echo ""

    # Check for .env file
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        log_error ".env file not found!"
        log_info "Create .env with required variables:"
        echo ""
        echo "  DB_PASSWORD=your_secure_password"
        echo "  JWT_SECRET=your_jwt_secret_32_chars"
        echo "  ENCRYPTION_KEY=exactly_32_characters!"
        echo "  CORS_ALLOWED_ORIGINS=https://yourdomain.com"
        echo ""
        exit 1
    fi

    # Validate ENCRYPTION_KEY length
    local enc_key=$(grep ENCRYPTION_KEY .env | cut -d= -f2)
    local key_len=${#enc_key}
    if [[ $key_len -ne 32 ]]; then
        log_error "ENCRYPTION_KEY must be exactly 32 characters (currently $key_len)"
        exit 1
    fi

    log_info "Building Docker image..."
    build_image

    log_info "Starting all services..."
    docker compose -f "$COMPOSE_FILE" up -d

    log_info "Waiting for services to be healthy..."
    sleep 10

    # Check health
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -sf http://localhost/health > /dev/null 2>&1; then
            echo ""
            log_success "Kuurier is running!"
            log_info "Health check: http://localhost/health"
            show_status
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempts++))
    done

    echo ""
    log_error "Services failed to start. Check logs:"
    log_info "  docker compose -f $COMPOSE_FILE logs"
    exit 1
}

# ============================================
# Main
# ============================================

case "${1:-}" in
    --init|-i)
        init
        ;;
    --status|-s)
        show_status
        ;;
    --rollback|-r)
        rollback
        ;;
    --build|-b)
        build_image "${2:-}"
        ;;
    --help|-h)
        echo ""
        echo "Kuurier Blue-Green Deployment"
        echo ""
        echo "Usage:"
        echo "  ./deploy.sh --init         First-time setup (build & start all)"
        echo "  ./deploy.sh                Deploy to idle environment"
        echo "  ./deploy.sh --status       Show deployment status"
        echo "  ./deploy.sh --rollback     Switch to previous environment"
        echo "  ./deploy.sh --build [tag]  Build Docker image only"
        echo "  ./deploy.sh --help         Show this help"
        echo ""
        ;;
    *)
        deploy "${2:-latest}"
        ;;
esac
