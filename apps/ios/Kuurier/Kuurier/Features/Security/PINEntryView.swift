import SwiftUI
import LocalAuthentication

/// PIN entry view for app lock
struct PINEntryView: View {
    @StateObject private var appLockService = AppLockService.shared
    @State private var enteredPIN = ""
    @State private var showError = false
    @State private var errorMessage = "Incorrect PIN"
    @State private var attempts = 0

    private let maxDigits = 6

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // App icon/logo area
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)

                    Text("Enter PIN")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }

                // PIN dots
                HStack(spacing: 16) {
                    ForEach(0..<maxDigits, id: \.self) { index in
                        Circle()
                            .fill(index < enteredPIN.count ? Color.orange : Color.gray.opacity(0.3))
                            .frame(width: 16, height: 16)
                            .animation(.easeInOut(duration: 0.1), value: enteredPIN.count)
                    }
                }
                .modifier(ShakeEffect(shakes: showError ? 2 : 0))

                // Error message
                if showError {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .transition(.opacity)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                // Number pad
                VStack(spacing: 20) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 40) {
                            ForEach(1...3, id: \.self) { col in
                                let number = row * 3 + col
                                NumberButton(number: "\(number)") {
                                    appendDigit("\(number)")
                                }
                            }
                        }
                    }

                    // Bottom row: Biometric, 0, Delete
                    HStack(spacing: 40) {
                        // Biometric button
                        if appLockService.isBiometricEnabled && appLockService.canUseBiometrics {
                            Button {
                                Task {
                                    await appLockService.authenticateWithBiometrics()
                                }
                            } label: {
                                Image(systemName: biometricIcon)
                                    .font(.system(size: 28))
                                    .foregroundColor(.white)
                                    .frame(width: 75, height: 75)
                            }
                        } else {
                            Color.clear.frame(width: 75, height: 75)
                        }

                        NumberButton(number: "0") {
                            appendDigit("0")
                        }

                        // Delete button
                        Button {
                            deleteDigit()
                        } label: {
                            Image(systemName: "delete.left.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .frame(width: 75, height: 75)
                        }
                        .disabled(enteredPIN.isEmpty)
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    private var biometricIcon: String {
        switch appLockService.biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "faceid"
        }
    }

    private func appendDigit(_ digit: String) {
        guard enteredPIN.count < maxDigits else { return }

        enteredPIN += digit
        showError = false

        if enteredPIN.count == maxDigits {
            validatePIN()
        }
    }

    private func deleteDigit() {
        guard !enteredPIN.isEmpty else { return }
        enteredPIN.removeLast()
        showError = false
    }

    private func validatePIN() {
        let result = appLockService.attemptUnlock(with: enteredPIN)

        switch result {
        case .success:
            // Successfully unlocked
            enteredPIN = ""
            attempts = 0

        case .duress, .maxAttemptsReached:
            // Duress PIN entered OR max attempts reached - data wiped, appear as if logged out
            // The app will show the login screen since auth state was cleared
            enteredPIN = ""
            attempts = 0

        case .failure(let attemptsRemaining):
            // Wrong PIN
            attempts += 1
            withAnimation {
                showError = true
                errorMessage = "Wrong PIN. \(attemptsRemaining) attempts remaining."
            }
            enteredPIN = ""

            // Add haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)

        case .lockedOut(let until):
            // Too many failed attempts
            enteredPIN = ""
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.minute, .second]
            formatter.unitsStyle = .abbreviated
            let timeRemaining = until.timeIntervalSinceNow
            let formattedTime = formatter.string(from: timeRemaining) ?? "a few minutes"

            withAnimation {
                showError = true
                errorMessage = "Too many attempts. Try again in \(formattedTime)."
            }

            // Add haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }
}

// MARK: - Number Button

private struct NumberButton: View {
    let number: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(number)
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 75, height: 75)
                .background(Color.gray.opacity(0.2))
                .clipShape(Circle())
        }
    }
}

// MARK: - Shake Effect

private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = sin(shakes * .pi * 4) * 10
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

// MARK: - PIN Setup View

struct PINSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appLockService = AppLockService.shared

    enum Mode {
        case setup
        case change
        case duress
    }

    let mode: Mode
    var onComplete: (() -> Void)?

    @State private var step: SetupStep = .enterNew
    @State private var firstPIN = ""
    @State private var confirmPIN = ""
    @State private var currentPIN = ""
    @State private var errorMessage: String?

    private enum SetupStep {
        case enterCurrent  // For change mode
        case enterNew
        case confirmNew
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 40) {
                    Spacer()

                    // Header
                    VStack(spacing: 16) {
                        Image(systemName: headerIcon)
                            .font(.system(size: 50))
                            .foregroundColor(mode == .duress ? .red : .orange)

                        Text(headerTitle)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)

                        Text(headerSubtitle)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    // PIN dots
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { index in
                            Circle()
                                .fill(index < currentInput.count ? (mode == .duress ? Color.red : Color.orange) : Color.gray.opacity(0.3))
                                .frame(width: 16, height: 16)
                        }
                    }

                    // Error message
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Spacer()

                    // Number pad
                    VStack(spacing: 20) {
                        ForEach(0..<3) { row in
                            HStack(spacing: 40) {
                                ForEach(1...3, id: \.self) { col in
                                    let number = row * 3 + col
                                    NumberButton(number: "\(number)") {
                                        appendDigit("\(number)")
                                    }
                                }
                            }
                        }

                        HStack(spacing: 40) {
                            Color.clear.frame(width: 75, height: 75)

                            NumberButton(number: "0") {
                                appendDigit("0")
                            }

                            Button {
                                deleteDigit()
                            } label: {
                                Image(systemName: "delete.left.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                                    .frame(width: 75, height: 75)
                            }
                            .disabled(currentInput.isEmpty)
                        }
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            if mode == .change || mode == .duress {
                step = .enterCurrent
            }
        }
    }

    private var headerIcon: String {
        switch mode {
        case .setup: return "lock.shield.fill"
        case .change: return "lock.rotation"
        case .duress: return "exclamationmark.shield.fill"
        }
    }

    private var headerTitle: String {
        switch step {
        case .enterCurrent:
            return "Enter Current PIN"
        case .enterNew:
            switch mode {
            case .setup: return "Create PIN"
            case .change: return "Enter New PIN"
            case .duress: return "Create Duress PIN"
            }
        case .confirmNew:
            return "Confirm PIN"
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .setup:
            return step == .confirmNew ? "Enter your PIN again to confirm" : "Choose a 6-digit PIN to lock the app"
        case .change:
            return step == .confirmNew ? "Enter your new PIN again" : step == .enterCurrent ? "Verify your identity" : "Choose a new 6-digit PIN"
        case .duress:
            if step == .enterCurrent {
                return "Verify your regular PIN first"
            } else if step == .confirmNew {
                return "Enter the duress PIN again to confirm"
            } else {
                return "This PIN will wipe all data when entered. Use a different PIN than your regular one."
            }
        }
    }

    private var currentInput: String {
        switch step {
        case .enterCurrent: return currentPIN
        case .enterNew: return firstPIN
        case .confirmNew: return confirmPIN
        }
    }

    private func appendDigit(_ digit: String) {
        errorMessage = nil

        switch step {
        case .enterCurrent:
            guard currentPIN.count < 6 else { return }
            currentPIN += digit
            if currentPIN.count == 6 {
                validateCurrentPIN()
            }
        case .enterNew:
            guard firstPIN.count < 6 else { return }
            firstPIN += digit
            if firstPIN.count == 6 {
                // For duress mode, check it's different from regular PIN
                if mode == .duress {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        step = .confirmNew
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        step = .confirmNew
                    }
                }
            }
        case .confirmNew:
            guard confirmPIN.count < 6 else { return }
            confirmPIN += digit
            if confirmPIN.count == 6 {
                validateConfirmPIN()
            }
        }
    }

    private func deleteDigit() {
        errorMessage = nil

        switch step {
        case .enterCurrent:
            guard !currentPIN.isEmpty else { return }
            currentPIN.removeLast()
        case .enterNew:
            guard !firstPIN.isEmpty else { return }
            firstPIN.removeLast()
        case .confirmNew:
            guard !confirmPIN.isEmpty else { return }
            confirmPIN.removeLast()
        }
    }

    private func validateCurrentPIN() {
        // Verify the current PIN is correct
        let result = appLockService.attemptUnlock(with: currentPIN)
        if case .success = result {
            // Re-lock since we just want to verify, not actually unlock
            if appLockService.isAppLockEnabled {
                appLockService.lockApp()
            }
            step = .enterNew
        } else {
            switch result {
            case .failure(let remaining):
                errorMessage = "Incorrect PIN. \(remaining) attempts remaining."
            case .lockedOut(let until):
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.minute, .second]
                formatter.unitsStyle = .abbreviated
                let formattedTime = formatter.string(from: until.timeIntervalSinceNow) ?? "a few minutes"
                errorMessage = "Too many attempts. Try again in \(formattedTime)."
            default:
                errorMessage = "Incorrect PIN"
            }
            currentPIN = ""
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }

    private func validateConfirmPIN() {
        if confirmPIN == firstPIN {
            // PINs match - save
            let success: Bool
            switch mode {
            case .setup:
                success = appLockService.setupPIN(firstPIN)
            case .change:
                success = appLockService.changePIN(currentPIN: currentPIN, newPIN: firstPIN)
            case .duress:
                success = appLockService.setupDuressPIN(firstPIN, regularPIN: currentPIN)
            }

            if success {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                onComplete?()
                dismiss()
            } else {
                errorMessage = mode == .duress ? "Duress PIN must be different from regular PIN" : "Failed to save PIN"
                firstPIN = ""
                confirmPIN = ""
                step = .enterNew
            }
        } else {
            errorMessage = "PINs don't match"
            confirmPIN = ""
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
    }
}

// MARK: - Preview

#Preview {
    PINEntryView()
}
