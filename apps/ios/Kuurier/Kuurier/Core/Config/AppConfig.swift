import Foundation

/// Application configuration for different environments
/// Change these values before building for production
enum AppConfig {

    // MARK: - API Configuration

    /// Base URL for the API server
    /// Set useProductionServer to true to test against production in DEBUG builds
    static var apiBaseURL: URL {
        #if DEBUG
        if useProductionServer {
            return URL(string: productionAPIURL)!
        }
        // Development - local server
        return URL(string: "http://localhost:8080/api/v1")!
        #else
        // Production
        return URL(string: productionAPIURL)!
        #endif
    }

    /// Set to true to use production server in DEBUG builds (for testing)
    static let useProductionServer = true

    /// Production API URL
    /// TODO: Change to https:// once SSL is configured on server
    private static let productionAPIURL = "http://api.kuurier.com/api/v1"

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

    // MARK: - Certificate Pinning

    /// Pinned public key hashes (SHA256 of SPKI)
    /// These are the base64-encoded SHA256 hashes of the server's public key
    ///
    /// To generate a pin from your certificate:
    /// ```bash
    /// # From a certificate file:
    /// openssl x509 -in cert.pem -pubkey -noout | \
    ///   openssl pkey -pubin -outform DER | \
    ///   openssl dgst -sha256 -binary | base64
    ///
    /// # From a live server:
    /// openssl s_client -connect api.kuurier.com:443 2>/dev/null | \
    ///   openssl x509 -pubkey -noout | \
    ///   openssl pkey -pubin -outform DER | \
    ///   openssl dgst -sha256 -binary | base64
    /// ```
    ///
    /// IMPORTANT: Include at least 2 pins (primary + backup) to avoid lockout
    /// during certificate rotation. The backup can be a new key pair stored securely.
    ///
    /// DEPLOYMENT CHECKLIST:
    /// 1. Generate primary pin from your production TLS certificate
    /// 2. Generate backup pin from a securely stored backup key pair
    /// 3. Replace PLACEHOLDER values below before App Store submission
    /// 4. Test certificate pinning in staging environment first
    static let pinnedPublicKeyHashes: [String] = [
        // Primary: Current production server public key
        // PLACEHOLDER - Must be replaced before production deployment!
        "PLACEHOLDER_PRIMARY_CERTIFICATE_PIN_REPLACE_BEFORE_DEPLOY",

        // Backup: Secondary key for rotation (generate and store securely)
        // PLACEHOLDER - Must be replaced before production deployment!
        "PLACEHOLDER_BACKUP_CERTIFICATE_PIN_REPLACE_BEFORE_DEPLOY",

        // Let's Encrypt ISRG Root X1 (common CA - provides fallback during rotation)
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=",
    ]

    /// Validates that certificate pins have been configured for production
    /// Call this during app startup in production builds
    static func validateCertificatePins() {
        #if !DEBUG
        let placeholderPins = pinnedPublicKeyHashes.filter { $0.hasPrefix("PLACEHOLDER") }
        if !placeholderPins.isEmpty {
            // In production, crash early if pins aren't configured
            // This prevents shipping an insecure app
            fatalError("""
                SECURITY ERROR: Certificate pins have not been configured!

                Found \(placeholderPins.count) placeholder pin(s) in AppConfig.swift.

                Before deploying to production:
                1. Generate your server's certificate pin
                2. Replace PLACEHOLDER values in pinnedPublicKeyHashes
                3. Test certificate pinning in staging

                The app cannot run in production with placeholder pins.
                """)
        }
        #endif
    }

    /// Hosts that require certificate pinning
    /// Only these hosts will have their certificates validated against pins
    static let pinnedHosts: Set<String> = [
        "api.kuurier.com",
        // Add additional API hosts here if needed
    ]

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
