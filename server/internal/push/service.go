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
	apns  *storage.APNs
}

// NewService creates a new push notification service
func NewService(cfg *config.Config, db *storage.Postgres, redis *storage.Redis, apns *storage.APNs) *Service {
	return &Service{
		cfg:   cfg,
		db:    db,
		redis: redis,
		apns:  apns,
	}
}

// Notification represents a push notification
type Notification struct {
	Title    string            `json:"title"`
	Body     string            `json:"body"`
	Data     map[string]string `json:"data,omitempty"`
	Priority string            `json:"priority"` // "normal" or "high"
	Category string            `json:"category"` // For actionable notifications
	ThreadID string            `json:"thread_id"` // For grouping
}

// NotificationType defines the type of notification
type NotificationType string

const (
	NotificationTypeAlert       NotificationType = "alert"
	NotificationTypeMessage     NotificationType = "message"
	NotificationTypeEvent       NotificationType = "event"
	NotificationTypeEventRemind NotificationType = "event_reminder"
)

// SendToUser sends a notification to a specific user
func (s *Service) SendToUser(ctx context.Context, userID string, notification Notification) error {
	// Check quiet hours first (skip for high priority)
	if notification.Priority != "high" && s.isInQuietHours(ctx, userID) {
		log.Printf("Push: Skipping notification for %s (quiet hours)", userID)
		return nil
	}

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
				log.Printf("Push: Failed to send APNs to %s: %v", userID, err)
				// Check if token is invalid and should be removed
				if err == storage.ErrInvalidToken {
					s.removeInvalidToken(ctx, userID, token)
				}
			}
		case "android":
			if err := s.sendFCM(ctx, token, notification); err != nil {
				log.Printf("Push: Failed to send FCM to %s: %v", userID, err)
			}
		}
	}

	return nil
}

// SendToUsers sends a notification to multiple users
func (s *Service) SendToUsers(ctx context.Context, userIDs []string, notification Notification) error {
	for _, userID := range userIDs {
		if err := s.SendToUser(ctx, userID, notification); err != nil {
			log.Printf("Push: Failed to send to %s: %v", userID, err)
		}
	}
	return nil
}

// SendToNearbyUsers sends a notification to users near a location
func (s *Service) SendToNearbyUsers(ctx context.Context, lat, lon float64, radiusMeters int, notification Notification, excludeUserID string) error {
	// Find all users with push tokens who are near the location
	// Using the push_tokens table and checking user's last known location
	rows, err := s.db.Pool().Query(ctx, `
		SELECT DISTINCT pt.user_id, pt.token, pt.platform
		FROM push_tokens pt
		WHERE pt.user_id != $4
	`, lat, lon, radiusMeters, excludeUserID)

	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var userID, token, platform string
		if err := rows.Scan(&userID, &token, &platform); err != nil {
			continue
		}

		// Check quiet hours (skip for non-emergency)
		if notification.Priority != "high" && s.isInQuietHours(ctx, userID) {
			continue
		}

		switch platform {
		case "ios":
			if err := s.sendAPNs(ctx, token, notification); err != nil {
				if err == storage.ErrInvalidToken {
					s.removeInvalidToken(ctx, userID, token)
				}
			}
		case "android":
			s.sendFCM(ctx, token, notification)
		}
	}

	return nil
}

// SendAlertToNearbyUsers sends an SOS alert to nearby users
func (s *Service) SendAlertToNearbyUsers(ctx context.Context, alertID string, authorID string) error {
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

	// Build notification
	var emoji string
	switch severity {
	case 1:
		emoji = "ℹ️"
	case 2:
		emoji = "⚠️"
	case 3:
		emoji = "🚨"
	default:
		emoji = "🔔"
	}

	notification := Notification{
		Title:    emoji + " " + title,
		Body:     "Someone nearby needs help. Tap to respond.",
		Priority: priority,
		Category: "ALERT",
		ThreadID: "alert-" + alertID,
		Data: map[string]string{
			"type":     "alert",
			"alert_id": alertID,
		},
	}

	return s.SendToNearbyUsers(ctx, lat, lon, radiusMeters, notification, authorID)
}

// SendAlertResponseNotification notifies the alert author of a new response
func (s *Service) SendAlertResponseNotification(ctx context.Context, alertID, responderID string) error {
	// Get alert author and title
	var authorID, title string
	err := s.db.Pool().QueryRow(ctx,
		"SELECT author_id, title FROM alerts WHERE id = $1",
		alertID,
	).Scan(&authorID, &title)

	if err != nil {
		return err
	}

	// Get responder status
	var status string
	err = s.db.Pool().QueryRow(ctx,
		"SELECT status FROM alert_responses WHERE alert_id = $1 AND user_id = $2",
		alertID, responderID,
	).Scan(&status)

	if err != nil {
		return err
	}

	var body string
	switch status {
	case "acknowledged":
		body = "Someone has acknowledged your alert"
	case "en_route":
		body = "Someone is on their way to help!"
	case "arrived":
		body = "Help has arrived!"
	default:
		body = "Someone responded to your alert"
	}

	notification := Notification{
		Title:    "Response: " + title,
		Body:     body,
		Priority: "high",
		Category: "ALERT_RESPONSE",
		ThreadID: "alert-" + alertID,
		Data: map[string]string{
			"type":     "alert_response",
			"alert_id": alertID,
		},
	}

	return s.SendToUser(ctx, authorID, notification)
}

// SendMessageNotification sends a notification for a new message
func (s *Service) SendMessageNotification(ctx context.Context, channelID, senderID, senderName, messagePreview string) error {
	// Get channel members except sender
	rows, err := s.db.Pool().Query(ctx, `
		SELECT user_id FROM channel_members
		WHERE channel_id = $1 AND user_id != $2
	`, channelID, senderID)

	if err != nil {
		return err
	}
	defer rows.Close()

	// Get channel name
	var channelName string
	var channelType string
	s.db.Pool().QueryRow(ctx,
		"SELECT name, channel_type FROM channels WHERE id = $1",
		channelID,
	).Scan(&channelName, &channelType)

	// Build notification
	title := senderName
	if channelType != "dm" && channelName != "" {
		title = senderName + " in " + channelName
	}

	notification := Notification{
		Title:    title,
		Body:     messagePreview,
		Priority: "normal",
		Category: "MESSAGE",
		ThreadID: "channel-" + channelID,
		Data: map[string]string{
			"type":       "message",
			"channel_id": channelID,
		},
	}

	// Send to each member
	for rows.Next() {
		var userID string
		if err := rows.Scan(&userID); err != nil {
			continue
		}
		s.SendToUser(ctx, userID, notification)
	}

	return nil
}

// SendEventNotification sends a notification about an event
func (s *Service) SendEventNotification(ctx context.Context, eventID, eventTitle, body string, userIDs []string) error {
	notification := Notification{
		Title:    eventTitle,
		Body:     body,
		Priority: "normal",
		Category: "EVENT",
		ThreadID: "event-" + eventID,
		Data: map[string]string{
			"type":     "event",
			"event_id": eventID,
		},
	}

	return s.SendToUsers(ctx, userIDs, notification)
}

// sendAPNs sends a notification via Apple Push Notification service
func (s *Service) sendAPNs(ctx context.Context, token string, notification Notification) error {
	if s.apns == nil {
		log.Printf("APNs: Not configured, skipping notification to %s", truncateToken(token))
		return nil
	}

	// Convert priority
	priority := 10 // high
	if notification.Priority == "normal" {
		priority = 5
	}

	// Convert data map
	data := make(map[string]interface{})
	for k, v := range notification.Data {
		data[k] = v
	}

	apnsNotification := storage.APNsNotification{
		Title:    notification.Title,
		Body:     notification.Body,
		Sound:    "default",
		Data:     data,
		Category: notification.Category,
		ThreadID: notification.ThreadID,
		Priority: priority,
	}

	return s.apns.Send(ctx, token, apnsNotification)
}

// sendFCM sends a notification via Firebase Cloud Messaging
func (s *Service) sendFCM(ctx context.Context, token string, notification Notification) error {
	// TODO: Implement FCM sending when Android support is added
	log.Printf("FCM: Not implemented, skipping notification to %s", truncateToken(token))
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

// removeInvalidToken removes an invalid token from the database
func (s *Service) removeInvalidToken(ctx context.Context, userID, token string) {
	_, err := s.db.Pool().Exec(ctx,
		"DELETE FROM push_tokens WHERE user_id = $1 AND token = $2",
		userID, token,
	)
	if err != nil {
		log.Printf("Push: Failed to remove invalid token: %v", err)
	} else {
		log.Printf("Push: Removed invalid token for user %s", userID)
	}
}

// isInQuietHours checks if a user is in quiet hours
func (s *Service) isInQuietHours(ctx context.Context, userID string) bool {
	var isQuiet bool
	err := s.db.Pool().QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM quiet_hours
			WHERE user_id = $1
			  AND is_active = true
			  AND (
				(start_time <= CURRENT_TIME AND end_time >= CURRENT_TIME)
				OR (start_time > end_time AND (CURRENT_TIME >= start_time OR CURRENT_TIME <= end_time))
			  )
		)
	`, userID).Scan(&isQuiet)

	if err != nil {
		return false // On error, assume not in quiet hours
	}

	return isQuiet
}

// truncateToken returns first 20 chars of token for logging
func truncateToken(token string) string {
	if len(token) > 20 {
		return token[:20] + "..."
	}
	return token
}
