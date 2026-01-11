package storage

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// MinIO handles object storage operations
type MinIO struct {
	client     *minio.Client
	bucketName string
	publicURL  string
}

// NewMinIO creates a new MinIO client
func NewMinIO(endpoint, accessKey, secretKey, bucketName string, useSSL bool) (*MinIO, error) {
	client, err := minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: useSSL,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to create minio client: %w", err)
	}

	m := &MinIO{
		client:     client,
		bucketName: bucketName,
		publicURL:  fmt.Sprintf("http://%s/%s", endpoint, bucketName),
	}

	// Ensure bucket exists
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	exists, err := client.BucketExists(ctx, bucketName)
	if err != nil {
		return nil, fmt.Errorf("failed to check bucket: %w", err)
	}

	if !exists {
		err = client.MakeBucket(ctx, bucketName, minio.MakeBucketOptions{})
		if err != nil {
			return nil, fmt.Errorf("failed to create bucket: %w", err)
		}

		// Set bucket policy to allow public read
		policy := fmt.Sprintf(`{
			"Version": "2012-10-17",
			"Statement": [{
				"Effect": "Allow",
				"Principal": {"AWS": ["*"]},
				"Action": ["s3:GetObject"],
				"Resource": ["arn:aws:s3:::%s/*"]
			}]
		}`, bucketName)

		err = client.SetBucketPolicy(ctx, bucketName, policy)
		if err != nil {
			// Non-fatal, continue without public policy
			fmt.Printf("Warning: failed to set bucket policy: %v\n", err)
		}
	}

	return m, nil
}

// UploadFile uploads a file to MinIO and returns the public URL
func (m *MinIO) UploadFile(ctx context.Context, objectName string, reader io.Reader, size int64, contentType string) (string, error) {
	_, err := m.client.PutObject(ctx, m.bucketName, objectName, reader, size, minio.PutObjectOptions{
		ContentType: contentType,
	})
	if err != nil {
		return "", fmt.Errorf("failed to upload file: %w", err)
	}

	// Return the public URL
	return fmt.Sprintf("%s/%s", m.publicURL, objectName), nil
}

// DeleteFile deletes a file from MinIO
func (m *MinIO) DeleteFile(ctx context.Context, objectName string) error {
	return m.client.RemoveObject(ctx, m.bucketName, objectName, minio.RemoveObjectOptions{})
}

// GetPresignedURL generates a presigned URL for temporary access
func (m *MinIO) GetPresignedURL(ctx context.Context, objectName string, expiry time.Duration) (string, error) {
	url, err := m.client.PresignedGetObject(ctx, m.bucketName, objectName, expiry, nil)
	if err != nil {
		return "", err
	}
	return url.String(), nil
}

// HealthCheck verifies MinIO connection
func (m *MinIO) HealthCheck(ctx context.Context) error {
	_, err := m.client.BucketExists(ctx, m.bucketName)
	return err
}
