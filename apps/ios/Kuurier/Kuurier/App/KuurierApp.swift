import SwiftUI

@main
struct KuurierApp: App {

    // Connect AppDelegate for push notifications
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var authService = AuthService.shared
    @StateObject private var pushService = PushNotificationService.shared
    @StateObject private var appLockService = AppLockService.shared

    // Detect shake gesture for panic button
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(authService)
                    .environmentObject(pushService)
                    .environmentObject(appLockService)

                // Show PIN entry when app is locked
                if appLockService.isLocked {
                    PINEntryView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .preferredColorScheme(.dark) // Default to dark mode for privacy
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                // Triple shake triggers panic mode confirmation
                // Implement shake detection in a real app
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                switch newPhase {
                case .active:
                    // Check if we need to lock based on timeout
                    appLockService.appWillEnterForeground()

                    // Re-register push token when app becomes active (after login)
                    if authService.isAuthenticated && !appLockService.isLocked {
                        Task {
                            await pushService.reregisterAfterLogin()
                        }
                    }
                case .background:
                    appLockService.appDidEnterBackground()
                case .inactive:
                    break
                @unknown default:
                    break
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
