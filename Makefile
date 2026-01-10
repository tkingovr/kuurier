.PHONY: help dev dev-down db-migrate db-reset server ios test lint clean

# Default target
help:
	@echo "Kuurier Development Commands"
	@echo ""
	@echo "Infrastructure:"
	@echo "  make dev          - Start development environment (Postgres, Redis, MinIO)"
	@echo "  make dev-down     - Stop development environment"
	@echo "  make db-migrate   - Run database migrations"
	@echo "  make db-reset     - Reset database (WARNING: destroys data)"
	@echo ""
	@echo "Development:"
	@echo "  make server       - Run the Go server locally"
	@echo "  make ios          - Open iOS project in Xcode"
	@echo "  make test         - Run all tests"
	@echo "  make lint         - Run linters"
	@echo ""
	@echo "Utilities:"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make deps         - Install dependencies"

# Start development infrastructure
dev:
	@echo "Starting development environment..."
	cd infra/docker && docker-compose up -d postgres redis minio
	@echo "Waiting for services to be ready..."
	@sleep 5
	@echo ""
	@echo "Development services running:"
	@echo "  PostgreSQL: localhost:5432"
	@echo "  Redis:      localhost:6379"
	@echo "  MinIO:      localhost:9000 (console: localhost:9001)"

# Stop development infrastructure
dev-down:
	@echo "Stopping development environment..."
	cd infra/docker && docker-compose down

# Run database migrations
db-migrate:
	@echo "Running database migrations..."
	docker exec -i kuurier-postgres psql -U kuurier -d kuurier < server/migrations/001_initial_schema.sql

# Reset database (destroys all data!)
db-reset:
	@echo "WARNING: This will destroy all data!"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	docker exec -i kuurier-postgres psql -U kuurier -d postgres -c "DROP DATABASE IF EXISTS kuurier;"
	docker exec -i kuurier-postgres psql -U kuurier -d postgres -c "CREATE DATABASE kuurier;"
	$(MAKE) db-migrate

# Run the Go server
server:
	@echo "Starting Kuurier server..."
	cd server && export $$(cat .env | xargs) && go run ./cmd/kuurier-server

# Open iOS project
ios:
	@echo "Opening iOS project in Xcode..."
	open apps/ios/Kuurier.xcodeproj 2>/dev/null || echo "No Xcode project found. Create one in Xcode first."

# Run tests
test:
	@echo "Running server tests..."
	cd server && go test -v ./...

# Run linters
lint:
	@echo "Running Go linter..."
	cd server && go vet ./...
	@echo "Running SwiftLint (if available)..."
	which swiftlint && swiftlint lint apps/ios || echo "SwiftLint not installed"

# Install dependencies
deps:
	@echo "Installing Go dependencies..."
	cd server && go mod download
	@echo "Installing development tools..."
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest || true

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	cd server && go clean
	rm -rf server/bin
	rm -rf apps/ios/build
