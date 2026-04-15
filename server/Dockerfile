# ============================================
# Kuurier Server - Production Dockerfile
# Multi-stage build for minimal image size
# ============================================

# Stage 1: Build
FROM golang:1.25-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

# Copy go mod files first (better layer caching)
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build args for version identity. Default to "unknown" when built locally
# so the /version endpoint still works for development.
ARG GIT_SHA=unknown
ARG VERSION=dev
ARG BUILD_DATE=unknown

# Build both binaries from the same source tree. Version info is
# injected into each via ldflags so `--version` / `/version` can
# report what's running.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.Version=${VERSION} -X main.GitSHA=${GIT_SHA} -X main.BuildDate=${BUILD_DATE}" \
    -o kuurier-server \
    ./cmd/kuurier-server && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.Version=${VERSION} -X main.GitSHA=${GIT_SHA} -X main.BuildDate=${BUILD_DATE}" \
    -o kuurier-worker \
    ./cmd/kuurier-worker

# Stage 2: Runtime
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata wget

# Create non-root user
RUN addgroup -g 1000 kuurier && \
    adduser -u 1000 -G kuurier -s /bin/sh -D kuurier

WORKDIR /app

# Copy both binaries from the builder stage. docker-compose picks
# which one to run via `command:` per service definition.
COPY --from=builder /app/kuurier-server .
COPY --from=builder /app/kuurier-worker .

# Set ownership
RUN chown -R kuurier:kuurier /app

USER kuurier

EXPOSE 8080

# Healthcheck targets the API; the worker service overrides this
# because it has no HTTP listener.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

# Default to the API binary. Worker service specifies `command:
# ["./kuurier-worker"]` to override.
ENTRYPOINT ["./kuurier-server"]
