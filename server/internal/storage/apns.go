package storage

import (
	"context"
	"errors"
	"log"
	"time"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	"github.com/sideshow/apns2/token"
)

// APNs wraps the Apple Push Notification service client
type APNs struct {
	client   *apns2.Client
	bundleID string
}

// APNsConfig holds configuration for APNs
type APNsConfig struct {
	KeyPath    string // Path to .p8 auth key file
	KeyID      string // Key ID from Apple Developer
	TeamID     string // Team ID from Apple Developer
	BundleID   string // App bundle ID (e.g., com.kuurier.app)
	Production bool   // Use production or sandbox environment
}

// NewAPNs creates a new APNs client
// If keyPath is empty, returns a mock client that logs notifications
func NewAPNs(cfg APNsConfig) (*APNs, error) {
	// If no key path, return mock client for development
	if cfg.KeyPath == "" {
		log.Println("APNs: No key path configured, using mock client")
		return &APNs{
			client:   nil,
			bundleID: cfg.BundleID,
		}, nil
	}

	// Load the auth key
	authKey, err := token.AuthKeyFromFile(cfg.KeyPath)
	if err != nil {
		return nil, err
	}

	// Create token
	tok := &token.Token{
		AuthKey: authKey,
		KeyID:   cfg.KeyID,
		TeamID:  cfg.TeamID,
	}

	// Create client
	var client *apns2.Client
	if cfg.Production {
		client = apns2.NewTokenClient(tok).Production()
	} else {
		client = apns2.NewTokenClient(tok).Development()
	}

	return &APNs{
		client:   client,
		bundleID: cfg.BundleID,
	}, nil
}

// Notification represents a push notification to send
type APNsNotification struct {
	Title       string
	Body        string
	Sound       string
	Badge       int
	Data        map[string]interface{}
	Category    string // For actionable notifications
	ThreadID    string // For notification grouping
	Priority    int    // 5 = low, 10 = high
	ContentAvailable bool // For background updates
	MutableContent   bool // For notification service extension
}

// Send sends a push notification to a device
func (a *APNs) Send(ctx context.Context, deviceToken string, notification APNsNotification) error {
	if a.client == nil {
		// Mock mode - just log
		log.Printf("APNs Mock: Would send to %s: %s - %s",
			truncateToken(deviceToken), notification.Title, notification.Body)
		return nil
	}

	// Build the payload
	p := payload.NewPayload()

	if notification.Title != "" || notification.Body != "" {
		p.AlertTitle(notification.Title)
		p.AlertBody(notification.Body)
	}

	if notification.Sound != "" {
		p.Sound(notification.Sound)
	} else {
		p.Sound("default")
	}

	if notification.Badge > 0 {
		p.Badge(notification.Badge)
	}

	if notification.Category != "" {
		p.Category(notification.Category)
	}

	if notification.ThreadID != "" {
		p.ThreadID(notification.ThreadID)
	}

	if notification.ContentAvailable {
		p.ContentAvailable()
	}

	if notification.MutableContent {
		p.MutableContent()
	}

	// Add custom data
	for key, value := range notification.Data {
		p.Custom(key, value)
	}

	// Create the notification
	n := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       a.bundleID,
		Payload:     p,
		Expiration:  time.Now().Add(24 * time.Hour),
	}

	// Set priority
	if notification.Priority == 5 {
		n.Priority = apns2.PriorityLow
	} else {
		n.Priority = apns2.PriorityHigh
	}

	// Send
	res, err := a.client.PushWithContext(ctx, n)
	if err != nil {
		return err
	}

	if !res.Sent() {
		log.Printf("APNs: Failed to send to %s: %s (status %d)",
			truncateToken(deviceToken), res.Reason, res.StatusCode)

		// Check for invalid token
		if res.Reason == apns2.ReasonBadDeviceToken ||
		   res.Reason == apns2.ReasonUnregistered {
			return ErrInvalidToken
		}

		return errors.New(res.Reason)
	}

	log.Printf("APNs: Sent to %s: %s", truncateToken(deviceToken), notification.Title)
	return nil
}

// SendBatch sends notifications to multiple devices
func (a *APNs) SendBatch(ctx context.Context, tokens []string, notification APNsNotification) (sent int, failed int) {
	for _, token := range tokens {
		if err := a.Send(ctx, token, notification); err != nil {
			failed++
			if errors.Is(err, ErrInvalidToken) {
				// Token should be removed from database
				log.Printf("APNs: Invalid token, should be removed: %s", truncateToken(token))
			}
		} else {
			sent++
		}
	}
	return sent, failed
}

// ErrInvalidToken indicates the device token is no longer valid
var ErrInvalidToken = errors.New("invalid or unregistered device token")

// truncateToken returns first 20 chars of token for logging
func truncateToken(token string) string {
	if len(token) > 20 {
		return token[:20] + "..."
	}
	return token
}
