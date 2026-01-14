import SwiftUI

@main
struct KuurierApp: App {

    // Connect AppDelegate for push notifications
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var authService = AuthService.shared
    @StateObject private var pushService = PushNotificationService.shared

    // Detect shake gesture for panic button
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .environmentObject(pushService)
                .preferredColorScheme(.dark) // Default to dark mode for privacy
                .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                    // Triple shake triggers panic mode confirmation
                    // Implement shake detection in a real app
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        // Re-register push token when app becomes active (after login)
                        if authService.isAuthenticated {
                            Task {
                                await pushService.reregisterAfterLogin()
                            }
                        }
                    }
                }
        }
    }
}

// MARK: - Shake Detection (for panic button)

extension NSNotification.Name {
    static let deviceDidShake = NSNotification.Name("deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
}
