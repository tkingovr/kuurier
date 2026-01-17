#!/bin/bash
# Local development runner for Kuurier server

export PORT=8080
export ENVIRONMENT=development
export DATABASE_URL="postgres://kuurier:kuurier_dev_password@localhost:5432/kuurier?sslmode=disable"
export REDIS_URL="redis://localhost:6379"
export MINIO_ENDPOINT="localhost:9000"
export MINIO_ACCESS_KEY="kuurier_admin"
export MINIO_SECRET_KEY="kuurier_minio_password"
export MINIO_BUCKET="kuurier-media"
export MINIO_USE_SSL="false"
export JWT_SECRET="dev_secret_change_me_in_production_32chars"
export ENCRYPTION_KEY="dev_encrypt_key_exactly_32_char!"

echo "Starting Kuurier server..."
go run ./cmd/kuurier-server/main.go
