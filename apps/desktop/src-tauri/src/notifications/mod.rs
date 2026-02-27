use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct NotificationPayload {
    pub title: String,
    pub body: String,
    pub channel_id: Option<String>,
}

/// Desktop notification manager using Tauri's notification plugin.
pub struct NotificationManager;

impl NotificationManager {
    /// Send a desktop notification for a new message.
    pub fn notify_message(sender_name: &str, content: &str, channel_id: &str) -> NotificationPayload {
        NotificationPayload {
            title: format!("New message from {}", sender_name),
            body: content.to_string(),
            channel_id: Some(channel_id.to_string()),
        }
    }

    /// Send a desktop notification for an SOS alert.
    pub fn notify_alert(alert_type: &str, description: &str) -> NotificationPayload {
        NotificationPayload {
            title: format!("SOS Alert: {}", alert_type),
            body: description.to_string(),
            channel_id: None,
        }
    }

    /// Send a desktop notification for an event.
    pub fn notify_event(title: &str) -> NotificationPayload {
        NotificationPayload {
            title: "Event Update".to_string(),
            body: title.to_string(),
            channel_id: None,
        }
    }
}
