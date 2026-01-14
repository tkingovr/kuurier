import UIKit
import UserNotifications

/// AppDelegate handles push notification setup and callbacks
/// Uses token-based APNs authentication with the backend
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set notification delegate
        UNUserNotificationCenter.current().delegate = self

        // Request notification permissions
        requestNotificationPermissions()

        return true
    }

    // MARK: - Notification Permissions

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { granted, error in
            if let error = error {
                print("Push: Permission request failed: \(error.localizedDescription)")
                return
            }

            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                print("Push: Notifications not authorized")
            }
        }
    }

    // MARK: - Remote Notification Registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Convert token to hex string
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("Push: Registered with token: \(tokenString.prefix(20))...")

        // Register with backend
        Task {
            await PushNotificationService.shared.registerDeviceToken(tokenString)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Push: Registration failed: \(error.localizedDescription)")
    }

    // MARK: - Notification Handling

    /// Handle notification received while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        // Process notification data
        PushNotificationService.shared.handleNotificationData(userInfo)

        // Show banner/sound even when app is in foreground for important notifications
        if let type = userInfo["type"] as? String {
            switch type {
            case "alert":
                // Always show SOS alerts prominently
                completionHandler([.banner, .sound, .badge])
            case "message":
                // Show message notifications with banner
                completionHandler([.banner, .sound])
            case "event", "event_reminder":
                completionHandler([.banner, .sound])
            default:
                completionHandler([.banner])
            }
        } else {
            completionHandler([.banner, .sound])
        }
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Handle notification tap based on action
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // User tapped notification
            PushNotificationService.shared.handleNotificationTap(userInfo)
        }

        completionHandler()
    }

    // MARK: - Background Notification

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Handle silent push notifications
        PushNotificationService.shared.handleNotificationData(userInfo)
        completionHandler(.newData)
    }
}
