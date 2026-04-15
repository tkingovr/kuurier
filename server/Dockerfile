# ============================================
# Kuurier Server - Production Dockerfile
# Multi-stage build for minimal image size
# ============================================

# Stage 1: Build
FROM golang:1.23-alpine AS builder

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

# Build with optimizations. Version info is injected into the binary
# via ldflags so /version can report what's running.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.Version=${VERSION} -X main.GitSHA=${GIT_SHA} -X main.BuildDate=${BUILD_DATE}" \
    -o kuurier-server \
    ./cmd/kuurier-server

# Stage 2: Runtime
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata wget

# Create non-root user
RUN addgroup -g 1000 kuurier && \
    adduser -u 1000 -G kuurier -s /bin/sh -D kuurier

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/kuurier-server .

# Set ownership
RUN chown -R kuurier:kuurier /app

USER kuurier

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["./kuurier-server"]
