import Foundation

/// Application configuration for different environments
/// Change these values before building for production
enum AppConfig {

    // MARK: - API Configuration

    /// Base URL for the API server
    /// DEBUG: Uses localhost for development
    /// RELEASE: Uses production server
    static var apiBaseURL: URL {
        #if DEBUG
        // Development - local server
        return URL(string: "http://localhost:8080/api/v1")!
        #else
        // Production - change this to your server URL
        return URL(string: productionAPIURL)!
        #endif
    }

    /// Production API URL
    /// IMPORTANT: Change this before releasing to App Store!
    private static let productionAPIURL = "https://api.kuurier.app/api/v1"

    // MARK: - App Information

    /// App bundle identifier
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.kuurier.app"
    }

    /// App version string
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Build number
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Feature Flags

    /// Enable debug logging
    static var enableDebugLogging: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Enable certificate pinning (recommended for production)
    static var enableCertificatePinning: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    // MARK: - Timeouts

    /// API request timeout in seconds
    static let apiRequestTimeout: TimeInterval = 30

    /// API resource timeout in seconds
    static let apiResourceTimeout: TimeInterval = 60

    /// WebSocket ping interval in seconds
    static let webSocketPingInterval: TimeInterval = 30

    /// WebSocket reconnection max attempts
    static let webSocketMaxReconnectAttempts = 10

    // MARK: - Storage Limits

    /// Maximum image upload size in bytes (10 MB)
    static let maxImageUploadSize = 10 * 1024 * 1024

    /// Maximum video upload size in bytes (50 MB)
    static let maxVideoUploadSize = 50 * 1024 * 1024

    // MARK: - Environment Check

    /// Whether running in debug mode
    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Whether running in production
    static var isProduction: Bool {
        !isDebug
    }
}
