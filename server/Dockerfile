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

# Build with optimizations
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.Version=$(date +%Y%m%d)" \
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
