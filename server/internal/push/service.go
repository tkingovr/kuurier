package push

import (
	"context"
	"log"

	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Service handles push notifications
type Service struct {
	cfg   *config.Config
	db    *storage.Postgres
	redis *storage.Redis
}

// NewService creates a new push notification service
func NewService(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *Service {
	return &Service{cfg: cfg, db: db, redis: redis}
}

// Notification represents a push notification
type Notification struct {
	Title    string            `json:"title"`
	Body     string            `json:"body"`
	Data     map[string]string `json:"data,omitempty"`
	Priority string            `json:"priority"` // "normal" or "high"
}

// SendToUser sends a notification to a specific user
func (s *Service) SendToUser(ctx context.Context, userID string, notification Notification) error {
	// Get user's push tokens
	rows, err := s.db.Pool().Query(ctx,
		"SELECT token, platform FROM push_tokens WHERE user_id = $1",
		userID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var token, platform string
		if err := rows.Scan(&token, &platform); err != nil {
			continue
		}

		switch platform {
		case "ios":
			if err := s.sendAPNs(ctx, token, notification); err != nil {
				log.Printf("Failed to send APNs notification: %v", err)
			}
		case "android":
			if err := s.sendFCM(ctx, token, notification); err != nil {
				log.Printf("Failed to send FCM notification: %v", err)
			}
		}
	}

	return nil
}

// SendToNearbyUsers sends a notification to users near a location
func (s *Service) SendToNearbyUsers(ctx context.Context, lat, lon float64, radiusMeters int, notification Notification) error {
	// Find users with subscriptions in the area
	// This is a simplified version - in production you'd want to batch this
	rows, err := s.db.Pool().Query(ctx, `
		SELECT DISTINCT pt.token, pt.platform
		FROM push_tokens pt
		JOIN subscriptions sub ON pt.user_id = sub.user_id
		WHERE sub.is_active = true
		  AND sub.location IS NOT NULL
		  AND ST_DWithin(sub.location, ST_MakePoint($2, $1)::geography, $3)
	`, lat, lon, radiusMeters)

	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var token, platform string
		if err := rows.Scan(&token, &platform); err != nil {
			continue
		}

		switch platform {
		case "ios":
			s.sendAPNs(ctx, token, notification)
		case "android":
			s.sendFCM(ctx, token, notification)
		}
	}

	return nil
}

// SendAlertToNearbyUsers sends an SOS alert to nearby users
func (s *Service) SendAlertToNearbyUsers(ctx context.Context, alertID string) error {
	// Get alert details
	var title string
	var severity int
	var lat, lon float64
	var radiusMeters int

	err := s.db.Pool().QueryRow(ctx, `
		SELECT title, severity, ST_Y(location::geometry), ST_X(location::geometry), radius_meters
		FROM alerts WHERE id = $1
	`, alertID).Scan(&title, &severity, &lat, &lon, &radiusMeters)

	if err != nil {
		return err
	}

	// Determine priority based on severity
	priority := "normal"
	if severity >= 2 {
		priority = "high"
	}

	notification := Notification{
		Title:    "🚨 " + title,
		Body:     "Someone nearby needs help. Tap to respond.",
		Priority: priority,
		Data: map[string]string{
			"type":     "alert",
			"alert_id": alertID,
		},
	}

	return s.SendToNearbyUsers(ctx, lat, lon, radiusMeters, notification)
}

// sendAPNs sends a notification via Apple Push Notification service
func (s *Service) sendAPNs(ctx context.Context, token string, notification Notification) error {
	// TODO: Implement APNs sending
	// Use a library like github.com/sideshow/apns2
	log.Printf("APNs notification to %s: %s", token[:20], notification.Title)
	return nil
}

// sendFCM sends a notification via Firebase Cloud Messaging
func (s *Service) sendFCM(ctx context.Context, token string, notification Notification) error {
	// TODO: Implement FCM sending
	// Use Firebase Admin SDK
	log.Printf("FCM notification to %s: %s", token[:20], notification.Title)
	return nil
}

// RegisterToken registers a push token for a user
func (s *Service) RegisterToken(ctx context.Context, userID, token, platform string) error {
	_, err := s.db.Pool().Exec(ctx, `
		INSERT INTO push_tokens (user_id, token, platform)
		VALUES ($1, $2, $3)
		ON CONFLICT (user_id, token) DO UPDATE SET platform = $3
	`, userID, token, platform)
	return err
}

// UnregisterToken removes a push token
func (s *Service) UnregisterToken(ctx context.Context, userID, token string) error {
	_, err := s.db.Pool().Exec(ctx,
		"DELETE FROM push_tokens WHERE user_id = $1 AND token = $2",
		userID, token,
	)
	return err
}
