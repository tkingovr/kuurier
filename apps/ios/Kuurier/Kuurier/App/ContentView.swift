import SwiftUI

struct ContentView: View {

    @EnvironmentObject var authService: AuthService
    @State private var selectedTab: Tab = .feed

    enum Tab {
        case feed, map, events, alerts, settings
    }

    var body: some View {
        Group {
            if authService.isAuthenticated {
                mainTabView
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut, value: authService.isAuthenticated)
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            FeedView()
                .tabItem {
                    Label("Feed", systemImage: "newspaper")
                }
                .tag(Tab.feed)

            MapView()
                .tabItem {
                    Label("Map", systemImage: "map")
                }
                .tag(Tab.map)

            EventsView()
                .tabItem {
                    Label("Events", systemImage: "calendar")
                }
                .tag(Tab.events)

            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: "exclamationmark.triangle")
                }
                .tag(Tab.alerts)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(Tab.settings)
        }
        .tint(.orange)
    }
}

// MARK: - Placeholder Views

struct FeedView: View {
    var body: some View {
        NavigationStack {
            List {
                Text("Feed coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Feed")
        }
    }
}

struct MapView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Text("Global Map")
                    .foregroundColor(.white)
            }
            .navigationTitle("Map")
        }
    }
}

struct EventsView: View {
    var body: some View {
        NavigationStack {
            List {
                Text("Events coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Events")
        }
    }
}

struct AlertsView: View {
    var body: some View {
        NavigationStack {
            List {
                Text("SOS Alerts coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Alerts")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showPanicConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let user = authService.currentUser {
                        LabeledContent("Trust Score", value: "\(user.trustScore)")
                        LabeledContent("Status", value: user.isVerified ? "Verified" : "Unverified")
                    }
                }

                Section("Subscriptions") {
                    NavigationLink("Topics") {
                        Text("Topic subscriptions")
                    }
                    NavigationLink("Locations") {
                        Text("Location subscriptions")
                    }
                }

                Section("Notifications") {
                    NavigationLink("Quiet Hours") {
                        Text("Quiet hours settings")
                    }
                }

                Section("Security") {
                    Button("Export Recovery Key") {
                        // Export private key
                    }

                    Button("Panic Wipe", role: .destructive) {
                        showPanicConfirmation = true
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        authService.logout()
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Panic Wipe", isPresented: $showPanicConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Wipe Everything", role: .destructive) {
                    authService.panicWipe()
                }
            } message: {
                Text("This will permanently delete ALL data including your account keys. This cannot be undone.")
            }
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var authService: AuthService
    @State private var step: OnboardingStep = .welcome
    @State private var inviteCode = ""
    @State private var showRecovery = false

    enum OnboardingStep {
        case welcome
        case inviteCode
    }

    var body: some View {
        VStack(spacing: 32) {
            switch step {
            case .welcome:
                welcomeStep
            case .inviteCode:
                inviteCodeStep
            }
        }
        .padding()
        .animation(.easeInOut, value: step)
        .sheet(isPresented: $showRecovery) {
            RecoveryView()
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 80))
                .foregroundColor(.orange)

            Text("Kuurier")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("The pulse of the movement, delivered.")
                .foregroundColor(.secondary)

            Spacer()

            // Features
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "lock.shield", title: "Anonymous", description: "No phone, no email, no tracking")
                FeatureRow(icon: "bell.badge", title: "Stay Informed", description: "Get alerts that matter to you")
                FeatureRow(icon: "map", title: "See the World", description: "Global map of activist activity")
                FeatureRow(icon: "person.3", title: "Web of Trust", description: "Build community credibility")
            }
            .padding(.horizontal)

            Spacer()

            // Get Started Button
            Button(action: {
                step = .inviteCode
            }) {
                Text("Get Started")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .background(Color.orange)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)

            // Recovery option
            Button("Recover existing account") {
                showRecovery = true
            }
            .font(.footnote)
            .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Invite Code Step

    private var inviteCodeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            // Back button
            HStack {
                Button(action: { step = .welcome }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundColor(.orange)
                }
                Spacer()
            }
            .padding(.horizontal)

            Image(systemName: "envelope.badge.person.crop")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Enter Invite Code")
                .font(.title)
                .fontWeight(.bold)

            Text("Kuurier is invite-only to protect the community.\nAsk a trusted member for an invite code.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            // Invite code input
            TextField("KUU-XXXXXX", text: $inviteCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .autocapitalization(.allCharacters)
                .disableAutocorrection(true)
                .padding(.horizontal, 40)
                .onChange(of: inviteCode) { _, newValue in
                    // Auto-format invite code
                    inviteCode = formatInviteCode(newValue)
                }

            if let error = authService.inviteError {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error)
                }
                .foregroundColor(.red)
                .font(.caption)
            }

            if let error = authService.error {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error)
                }
                .foregroundColor(.red)
                .font(.caption)
            }

            Spacer()

            // Join Button
            Button(action: {
                Task {
                    let isValid = await authService.validateInviteCode(inviteCode)
                    if isValid {
                        await authService.authenticate(inviteCode: inviteCode)
                    }
                }
            }) {
                if authService.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("Join Kuurier")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isValidCodeFormat ? Color.orange : Color.gray)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            .disabled(!isValidCodeFormat || authService.isLoading)

            Text("By joining, you agree to uphold community trust.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Helpers

    private var isValidCodeFormat: Bool {
        // Check if code matches pattern KUU-XXXXXX
        let pattern = "^KUU-[A-Z0-9]{6}$"
        return inviteCode.range(of: pattern, options: .regularExpression) != nil
    }

    private func formatInviteCode(_ input: String) -> String {
        // Remove any existing prefix and non-alphanumeric characters
        var cleaned = input.uppercased().replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)

        // Remove KUU prefix if present
        if cleaned.hasPrefix("KUU") {
            cleaned = String(cleaned.dropFirst(3))
        }

        // Limit to 6 characters
        let code = String(cleaned.prefix(6))

        // Add prefix back
        if code.isEmpty {
            return ""
        }
        return "KUU-\(code)"
    }
}

// MARK: - Recovery View

struct RecoveryView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) var dismiss
    @State private var recoveryKey = ""
    @State private var isRecovering = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)

                Text("Account Recovery")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Paste your recovery key to restore your account.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                TextEditor(text: $recoveryKey)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)

                if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Spacer()

                Button(action: recoverAccount) {
                    if isRecovering {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Recover Account")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal)
                .disabled(recoveryKey.isEmpty || isRecovering)
            }
            .padding()
            .navigationTitle("Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func recoverAccount() {
        guard let data = Data(base64Encoded: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Invalid recovery key format"
            return
        }

        isRecovering = true
        error = nil

        Task {
            do {
                try await authService.importRecoveryData(data)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    self.error = "Recovery failed: \(error.localizedDescription)"
                    isRecovering = false
                }
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
}
