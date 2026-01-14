import Foundation
import Combine

/// Notification types received from the server
enum PushNotificationType: String {
    case alert = "alert"
    case alertResponse = "alert_response"
    case message = "message"
    case event = "event"
    case eventReminder = "event_reminder"
}

/// Deep link destinations from push notifications
enum NotificationDestination: Equatable {
    case alert(id: String)
    case channel(id: String)
    case event(id: String)
}

/// Manages push notification registration and handling
final class PushNotificationService: ObservableObject {

    static let shared = PushNotificationService()

    /// Current pending navigation destination from tapped notification
    @Published var pendingDestination: NotificationDestination?

    /// Whether push notifications are enabled
    @Published var isEnabled: Bool = false

    private let api = APIClient.shared
    private let storage = SecureStorage.shared

    private let pushTokenKey = "push_token"

    private init() {
        // Check if we have a stored token
        isEnabled = storage.getString(forKey: pushTokenKey) != nil
    }

    // MARK: - Token Registration

    /// Registers device token with the backend
    func registerDeviceToken(_ token: String) async {
        // Store locally first
        try? storage.setString(token, forKey: pushTokenKey)

        // Only send to server if authenticated
        guard storage.isLoggedIn else {
            print("Push: Skipping server registration - not logged in")
            return
        }

        do {
            let request = RegisterTokenRequest(token: token, platform: "ios")
            let _: MessageResponse = try await api.post("/push/token", body: request)
            print("Push: Token registered with server")

            await MainActor.run {
                isEnabled = true
            }
        } catch {
            print("Push: Failed to register token with server: \(error.localizedDescription)")
        }
    }

    /// Unregisters device token from the backend
    func unregisterDeviceToken() async {
        guard let token = storage.getString(forKey: pushTokenKey) else { return }

        do {
            let request = UnregisterTokenRequest(token: token)
            let _: MessageResponse = try await api.delete("/push/token")
            print("Push: Token unregistered from server")

            // Remove locally
            storage.delete(key: pushTokenKey)

            await MainActor.run {
                isEnabled = false
            }
        } catch {
            print("Push: Failed to unregister token: \(error.localizedDescription)")
        }
    }

    /// Re-registers token after login (if we had one stored)
    func reregisterAfterLogin() async {
        guard let token = storage.getString(forKey: pushTokenKey) else { return }
        await registerDeviceToken(token)
    }

    // MARK: - Notification Handling

    /// Processes notification data (for analytics, updates, etc.)
    func handleNotificationData(_ userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return }

        switch PushNotificationType(rawValue: type) {
        case .alert:
            // Could refresh alerts list
            NotificationCenter.default.post(name: .alertsUpdated, object: nil)

        case .alertResponse:
            // Could update alert detail view
            if let alertID = userInfo["alert_id"] as? String {
                NotificationCenter.default.post(
                    name: .alertResponseReceived,
                    object: nil,
                    userInfo: ["alert_id": alertID]
                )
            }

        case .message:
            // Could update unread count
            if let channelID = userInfo["channel_id"] as? String {
                NotificationCenter.default.post(
                    name: .newMessageReceived,
                    object: nil,
                    userInfo: ["channel_id": channelID]
                )
            }

        case .event, .eventReminder:
            // Could refresh events
            if let eventID = userInfo["event_id"] as? String {
                NotificationCenter.default.post(
                    name: .eventUpdated,
                    object: nil,
                    userInfo: ["event_id": eventID]
                )
            }

        case .none:
            print("Push: Unknown notification type: \(type)")
        }
    }

    /// Handles notification tap - determines navigation destination
    func handleNotificationTap(_ userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return }

        switch PushNotificationType(rawValue: type) {
        case .alert, .alertResponse:
            if let alertID = userInfo["alert_id"] as? String {
                pendingDestination = .alert(id: alertID)
            }

        case .message:
            if let channelID = userInfo["channel_id"] as? String {
                pendingDestination = .channel(id: channelID)
            }

        case .event, .eventReminder:
            if let eventID = userInfo["event_id"] as? String {
                pendingDestination = .event(id: eventID)
            }

        case .none:
            break
        }
    }

    /// Clears pending navigation destination after handling
    func clearPendingDestination() {
        pendingDestination = nil
    }
}

// MARK: - Request/Response Models

private struct RegisterTokenRequest: Encodable {
    let token: String
    let platform: String
}

private struct UnregisterTokenRequest: Encodable {
    let token: String
}

// MARK: - Notification Names

extension Notification.Name {
    static let alertsUpdated = Notification.Name("alertsUpdated")
    static let alertResponseReceived = Notification.Name("alertResponseReceived")
    static let newMessageReceived = Notification.Name("newMessageReceived")
    static let eventUpdated = Notification.Name("eventUpdated")
}
