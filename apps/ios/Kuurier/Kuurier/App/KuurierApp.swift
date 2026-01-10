import SwiftUI

@main
struct KuurierApp: App {

    @StateObject private var authService = AuthService.shared

    // Detect shake gesture for panic button
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .preferredColorScheme(.dark) // Default to dark mode for privacy
                .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                    // Triple shake triggers panic mode confirmation
                    // Implement shake detection in a real app
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
