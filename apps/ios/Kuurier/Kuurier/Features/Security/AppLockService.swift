import Foundation
import Combine
import CryptoKit
import LocalAuthentication

/// Manages app lock functionality with duress PIN support
/// When duress PIN is entered, all data is wiped silently
final class AppLockService: ObservableObject {

    static let shared = AppLockService()

    // MARK: - Published State

    @Published var isLocked: Bool = false
    @Published var isAppLockEnabled: Bool = false
    @Published var isDuressPINSet: Bool = false
    @Published var isBiometricEnabled: Bool = false
    @Published var autoLockTimeout: AutoLockTimeout = .immediately

    // MARK: - Private Properties

    private let storage = SecureStorage.shared
    private let pinKey = "app_lock_pin_hash"
    private let duressPINKey = "duress_pin_hash"
    private let biometricKey = "biometric_enabled"
    private let timeoutKey = "auto_lock_timeout"
    private var lastBackgroundTime: Date?

    enum AutoLockTimeout: Int, CaseIterable {
        case immediately = 0
        case after1Minute = 60
        case after5Minutes = 300
        case after15Minutes = 900

        var displayName: String {
            switch self {
            case .immediately: return "Immediately"
            case .after1Minute: return "After 1 minute"
            case .after5Minutes: return "After 5 minutes"
            case .after15Minutes: return "After 15 minutes"
            }
        }
    }

    private init() {
        loadSettings()
    }

    // MARK: - Setup

    private func loadSettings() {
        isAppLockEnabled = storage.getString(forKey: pinKey) != nil
        isDuressPINSet = storage.getString(forKey: duressPINKey) != nil
        isBiometricEnabled = UserDefaults.standard.bool(forKey: biometricKey)

        if let timeoutValue = UserDefaults.standard.object(forKey: timeoutKey) as? Int,
           let timeout = AutoLockTimeout(rawValue: timeoutValue) {
            autoLockTimeout = timeout
        }

        // Start locked if app lock is enabled
        isLocked = isAppLockEnabled
    }

    // MARK: - PIN Management

    /// Sets up app lock with a new PIN
    func setupPIN(_ pin: String) -> Bool {
        guard pin.count == 6, pin.allSatisfy({ $0.isNumber }) else {
            return false
        }

        let hash = hashPIN(pin)
        do {
            try storage.setString(hash, forKey: pinKey)
            isAppLockEnabled = true
            isLocked = false
            return true
        } catch {
            return false
        }
    }

    /// Changes the existing PIN
    func changePIN(currentPIN: String, newPIN: String) -> Bool {
        guard verifyPIN(currentPIN) else { return false }
        return setupPIN(newPIN)
    }

    /// Disables app lock (requires current PIN)
    func disableAppLock(currentPIN: String) -> Bool {
        guard verifyPIN(currentPIN) else { return false }

        storage.delete(key: pinKey)
        storage.delete(key: duressPINKey)
        isAppLockEnabled = false
        isDuressPINSet = false
        isLocked = false
        return true
    }

    /// Sets up a duress PIN (different from regular PIN)
    func setupDuressPIN(_ pin: String, regularPIN: String) -> Bool {
        // Verify regular PIN first
        guard verifyPIN(regularPIN) else { return false }

        // Duress PIN must be different from regular PIN
        guard pin != regularPIN else { return false }

        guard pin.count == 6, pin.allSatisfy({ $0.isNumber }) else {
            return false
        }

        let hash = hashPIN(pin)
        do {
            try storage.setString(hash, forKey: duressPINKey)
            isDuressPINSet = true
            return true
        } catch {
            return false
        }
    }

    /// Removes the duress PIN
    func removeDuressPIN(regularPIN: String) -> Bool {
        guard verifyPIN(regularPIN) else { return false }
        storage.delete(key: duressPINKey)
        isDuressPINSet = false
        return true
    }

    // MARK: - Authentication

    /// Attempts to unlock with the provided PIN
    /// Returns: .success if unlocked, .duress if duress PIN entered (wipe triggered), .failure if wrong PIN
    func attemptUnlock(with pin: String) -> UnlockResult {
        // Check duress PIN first
        if isDuressPINSet, let storedHash = storage.getString(forKey: duressPINKey) {
            if hashPIN(pin) == storedHash {
                // Duress PIN entered - trigger silent wipe
                triggerDuressWipe()
                return .duress
            }
        }

        // Check regular PIN
        if verifyPIN(pin) {
            isLocked = false
            return .success
        }

        return .failure
    }

    enum UnlockResult {
        case success
        case duress
        case failure
    }

    /// Verifies if the provided PIN matches the stored PIN
    private func verifyPIN(_ pin: String) -> Bool {
        guard let storedHash = storage.getString(forKey: pinKey) else {
            return false
        }
        return hashPIN(pin) == storedHash
    }

    /// Hashes a PIN using SHA256
    private func hashPIN(_ pin: String) -> String {
        let data = Data(pin.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Biometric Authentication

    var biometricType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var biometricTypeName: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometric"
        }
    }

    var canUseBiometrics: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func setBiometricEnabled(_ enabled: Bool) {
        isBiometricEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: biometricKey)
    }

    func authenticateWithBiometrics() async -> Bool {
        guard isBiometricEnabled, canUseBiometrics else { return false }

        let context = LAContext()
        context.localizedCancelTitle = "Enter PIN"

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock Kuurier"
            )
            if success {
                await MainActor.run {
                    isLocked = false
                }
            }
            return success
        } catch {
            return false
        }
    }

    // MARK: - Lock State Management

    func setAutoLockTimeout(_ timeout: AutoLockTimeout) {
        autoLockTimeout = timeout
        UserDefaults.standard.set(timeout.rawValue, forKey: timeoutKey)
    }

    /// Called when app goes to background
    func appDidEnterBackground() {
        lastBackgroundTime = Date()
    }

    /// Called when app returns to foreground
    func appWillEnterForeground() {
        guard isAppLockEnabled else { return }

        if autoLockTimeout == .immediately {
            isLocked = true
            return
        }

        if let lastTime = lastBackgroundTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed >= Double(autoLockTimeout.rawValue) {
                isLocked = true
            }
        }
    }

    /// Manually lock the app
    func lockApp() {
        guard isAppLockEnabled else { return }
        isLocked = true
    }

    // MARK: - Duress Wipe

    /// Silently wipes all data when duress PIN is entered
    private func triggerDuressWipe() {
        // Wipe all data
        storage.panicWipe()

        // Reset auth state
        AuthService.shared.panicWipe()

        // Clear app lock settings too
        storage.delete(key: pinKey)
        storage.delete(key: duressPINKey)
        UserDefaults.standard.removeObject(forKey: biometricKey)
        UserDefaults.standard.removeObject(forKey: timeoutKey)

        // Reset local state
        isAppLockEnabled = false
        isDuressPINSet = false
        isBiometricEnabled = false
        isLocked = false
    }
}
