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

    // Brute force protection
    @Published var failedAttempts: Int = 0
    @Published var isLockedOut: Bool = false
    @Published var lockoutEndTime: Date?
    @Published var wipeOnMaxAttempts: Bool = false

    // MARK: - Private Properties

    private let storage = SecureStorage.shared
    private let pinKey = "app_lock_pin_hash"
    private let duressPINKey = "duress_pin_hash"
    private let biometricKey = "biometric_enabled"
    private let timeoutKey = "auto_lock_timeout"
    private let failedAttemptsKey = "failed_pin_attempts"
    private let lockoutEndKey = "pin_lockout_end"
    private let wipeOnMaxKey = "wipe_on_max_attempts"
    private var lastBackgroundTime: Date?

    // Brute force protection configuration
    private let maxAttemptsBeforeLockout = 5
    private let maxAttemptsBeforeWipe = 10
    private let baseLockoutSeconds: TimeInterval = 30  // 30 seconds base, doubles each lockout

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
        wipeOnMaxAttempts = UserDefaults.standard.bool(forKey: wipeOnMaxKey)

        if let timeoutValue = UserDefaults.standard.object(forKey: timeoutKey) as? Int,
           let timeout = AutoLockTimeout(rawValue: timeoutValue) {
            autoLockTimeout = timeout
        }

        // Load brute force protection state
        failedAttempts = UserDefaults.standard.integer(forKey: failedAttemptsKey)
        if let lockoutEndTimestamp = UserDefaults.standard.object(forKey: lockoutEndKey) as? Double {
            let endTime = Date(timeIntervalSince1970: lockoutEndTimestamp)
            if endTime > Date() {
                lockoutEndTime = endTime
                isLockedOut = true
            } else {
                // Lockout expired, clear it
                UserDefaults.standard.removeObject(forKey: lockoutEndKey)
            }
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
    /// Returns: .success if unlocked, .duress if duress PIN entered (wipe triggered),
    /// .lockedOut if too many failures, .failure if wrong PIN
    func attemptUnlock(with pin: String) -> UnlockResult {
        // Check if currently locked out
        if isLockedOut {
            if let endTime = lockoutEndTime, Date() < endTime {
                return .lockedOut(until: endTime)
            } else {
                // Lockout expired
                clearLockout()
            }
        }

        // Check duress PIN first (always check, even if locked out)
        if isDuressPINSet, verifyPINAgainstKey(pin, key: duressPINKey) {
            // Duress PIN entered - trigger silent wipe
            clearBruteForceState()
            triggerDuressWipe()
            return .duress
        }

        // Check regular PIN
        if verifyPIN(pin) {
            // Success - clear brute force state
            clearBruteForceState()
            isLocked = false
            return .success
        }

        // Failed attempt - update brute force state
        recordFailedAttempt()

        // Check if we should trigger a wipe (max attempts exceeded)
        if wipeOnMaxAttempts && failedAttempts >= maxAttemptsBeforeWipe {
            clearBruteForceState()
            triggerDuressWipe()
            return .maxAttemptsReached
        }

        // Check if we should lock out
        if failedAttempts >= maxAttemptsBeforeLockout {
            triggerLockout()
            return .lockedOut(until: lockoutEndTime!)
        }

        return .failure(attemptsRemaining: maxAttemptsBeforeLockout - failedAttempts)
    }

    // MARK: - Brute Force Protection

    /// Records a failed PIN attempt
    private func recordFailedAttempt() {
        failedAttempts += 1
        UserDefaults.standard.set(failedAttempts, forKey: failedAttemptsKey)
    }

    /// Triggers a lockout period with exponential backoff
    private func triggerLockout() {
        // Calculate lockout multiplier (doubles each time we've hit lockout)
        let lockoutCount = (failedAttempts - maxAttemptsBeforeLockout) / maxAttemptsBeforeLockout + 1
        let lockoutDuration = baseLockoutSeconds * pow(2.0, Double(lockoutCount - 1))

        // Cap at 1 hour max
        let cappedDuration = min(lockoutDuration, 3600)

        lockoutEndTime = Date().addingTimeInterval(cappedDuration)
        isLockedOut = true

        // Persist lockout end time
        UserDefaults.standard.set(lockoutEndTime!.timeIntervalSince1970, forKey: lockoutEndKey)
    }

    /// Clears the lockout state (but not failed attempts)
    private func clearLockout() {
        isLockedOut = false
        lockoutEndTime = nil
        UserDefaults.standard.removeObject(forKey: lockoutEndKey)
    }

    /// Clears all brute force protection state (on success or duress)
    private func clearBruteForceState() {
        failedAttempts = 0
        isLockedOut = false
        lockoutEndTime = nil
        UserDefaults.standard.removeObject(forKey: failedAttemptsKey)
        UserDefaults.standard.removeObject(forKey: lockoutEndKey)
    }

    /// Sets whether to wipe data after max attempts
    func setWipeOnMaxAttempts(_ enabled: Bool) {
        wipeOnMaxAttempts = enabled
        UserDefaults.standard.set(enabled, forKey: wipeOnMaxKey)
    }

    /// Returns remaining time in lockout (nil if not locked out)
    var remainingLockoutTime: TimeInterval? {
        guard isLockedOut, let endTime = lockoutEndTime else { return nil }
        let remaining = endTime.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    enum UnlockResult {
        case success
        case duress
        case failure(attemptsRemaining: Int)
        case lockedOut(until: Date)
        case maxAttemptsReached  // Data wiped due to too many attempts
    }

    /// Verifies if the provided PIN matches the stored PIN
    private func verifyPIN(_ pin: String) -> Bool {
        return verifyPINAgainstKey(pin, key: pinKey)
    }

    /// Verifies a PIN against a stored hash at the specified key
    private func verifyPINAgainstKey(_ pin: String, key: String) -> Bool {
        guard let storedValue = storage.getString(forKey: key),
              let storedData = Data(base64Encoded: storedValue),
              storedData.count >= 48 else { // 16 bytes salt + 32 bytes hash
            return false
        }

        // Extract salt and stored hash
        let salt = storedData.prefix(16)
        let storedHash = storedData.dropFirst(16)

        // Hash the input PIN with the same salt
        let inputHash = hashPINWithSalt(pin, salt: Data(salt))

        // Constant-time comparison to prevent timing attacks
        return constantTimeCompare(inputHash, Data(storedHash))
    }

    /// Hashes a PIN using PBKDF2 with SHA256 (100,000 iterations)
    /// Returns: salt (16 bytes) + hash (32 bytes) as base64 string
    private func hashPIN(_ pin: String) -> String {
        // Generate random 16-byte salt
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        // Hash PIN with salt
        let hash = hashPINWithSalt(pin, salt: salt)

        // Combine salt + hash
        var combined = Data()
        combined.append(salt)
        combined.append(hash)

        return combined.base64EncodedString()
    }

    /// Hashes PIN with provided salt using PBKDF2-HMAC-SHA256 (pure Swift implementation)
    private func hashPINWithSalt(_ pin: String, salt: Data) -> Data {
        let password = Data(pin.utf8)
        let iterations = 100_000  // OWASP recommended minimum
        let keyLength = 32  // 256 bits

        return pbkdf2SHA256(password: password, salt: salt, iterations: iterations, keyLength: keyLength)
    }

    /// PBKDF2 implementation using CryptoKit's HMAC-SHA256
    private func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let hashLength = 32  // SHA256 output length
        let numBlocks = (keyLength + hashLength - 1) / hashLength

        var derivedKey = Data()

        for blockIndex in 1...numBlocks {
            // Initial U1 = HMAC(password, salt || INT(blockIndex))
            var blockData = salt
            var blockNum = UInt32(blockIndex).bigEndian
            blockData.append(Data(bytes: &blockNum, count: 4))

            let key = SymmetricKey(data: password)
            var u = Data(HMAC<SHA256>.authenticationCode(for: blockData, using: key))
            var result = u

            // U2 ... Uc
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                // XOR result with each U
                for i in 0..<result.count {
                    result[i] ^= u[i]
                }
            }

            derivedKey.append(result)
        }

        // Truncate to requested key length
        return Data(derivedKey.prefix(keyLength))
    }

    /// Constant-time comparison to prevent timing attacks
    private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(a, b) {
            result |= x ^ y
        }
        return result == 0
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
