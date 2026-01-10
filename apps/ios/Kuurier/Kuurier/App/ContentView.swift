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
    @EnvironmentObject var authService: AuthService
    @State private var showComposeSheet = false
    @State private var showLockedAlert = false

    private var canPost: Bool {
        guard let user = authService.currentUser else { return false }
        return user.trustScore >= 25
    }

    private var trustNeeded: Int {
        guard let user = authService.currentUser else { return 25 }
        return max(0, 25 - user.trustScore)
    }

    var body: some View {
        NavigationStack {
            List {
                Text("Feed coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        if canPost {
                            showComposeSheet = true
                        } else {
                            showLockedAlert = true
                        }
                    }) {
                        Image(systemName: canPost ? "square.and.pencil" : "lock.fill")
                            .foregroundColor(canPost ? .orange : .gray)
                    }
                }
            }
            .sheet(isPresented: $showComposeSheet) {
                ComposePostView()
            }
            .alert("Posting Locked", isPresented: $showLockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You need a trust score of 25 to create posts. Get \(trustNeeded) more point\(trustNeeded == 1 ? "" : "s") by receiving vouches from trusted members.")
            }
        }
    }
}

struct ComposePostView: View {
    @Environment(\.dismiss) var dismiss
    @State private var content = ""

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $content)
                    .padding()
                Spacer()
            }
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        // TODO: Submit post
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
    @EnvironmentObject var authService: AuthService
    @State private var showCreateSheet = false
    @State private var showLockedAlert = false

    private var canCreateEvent: Bool {
        guard let user = authService.currentUser else { return false }
        return user.trustScore >= 50
    }

    private var trustNeeded: Int {
        guard let user = authService.currentUser else { return 50 }
        return max(0, 50 - user.trustScore)
    }

    var body: some View {
        NavigationStack {
            List {
                Text("Events coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        if canCreateEvent {
                            showCreateSheet = true
                        } else {
                            showLockedAlert = true
                        }
                    }) {
                        Image(systemName: canCreateEvent ? "calendar.badge.plus" : "lock.fill")
                            .foregroundColor(canCreateEvent ? .orange : .gray)
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateEventView()
            }
            .alert("Event Creation Locked", isPresented: $showLockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You need a trust score of 50 to create events. Get \(trustNeeded) more point\(trustNeeded == 1 ? "" : "s") by receiving vouches from trusted members.")
            }
        }
    }
}

struct CreateEventView: View {
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var description = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Event Details") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Location") {
                    Text("Location picker coming soon...")
                        .foregroundColor(.secondary)
                }

                Section("Date & Time") {
                    Text("Date picker coming soon...")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        // TODO: Submit event
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct AlertsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showSOSSheet = false
    @State private var showLockedAlert = false

    private var canSendSOS: Bool {
        guard let user = authService.currentUser else { return false }
        return user.trustScore >= 100 || user.isVerified
    }

    private var trustNeeded: Int {
        guard let user = authService.currentUser else { return 100 }
        return max(0, 100 - user.trustScore)
    }

    var body: some View {
        NavigationStack {
            List {
                // SOS Button at top
                Section {
                    Button(action: {
                        if canSendSOS {
                            showSOSSheet = true
                        } else {
                            showLockedAlert = true
                        }
                    }) {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: canSendSOS ? "exclamationmark.triangle.fill" : "lock.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(canSendSOS ? .red : .gray)
                                Text(canSendSOS ? "Send SOS Alert" : "SOS Locked")
                                    .font(.headline)
                                    .foregroundColor(canSendSOS ? .red : .gray)
                                if !canSendSOS {
                                    Text("Requires trust score of 100")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Active alerts section
                Section("Active Alerts Nearby") {
                    Text("No active alerts in your area")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Alerts")
            .sheet(isPresented: $showSOSSheet) {
                SendSOSView()
            }
            .alert("SOS Alerts Locked", isPresented: $showLockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("SOS alerts require a trust score of 100 or verified status to prevent misuse. Get \(trustNeeded) more point\(trustNeeded == 1 ? "" : "s") by receiving vouches from trusted members.")
            }
        }
    }
}

struct SendSOSView: View {
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var severity: Int = 3

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.red)
                        Text("Send SOS Alert")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("This will alert nearby trusted members")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }

                Section("What's happening?") {
                    TextField("Brief title", text: $title)
                    TextField("Details (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Severity") {
                    Picker("Severity Level", selection: $severity) {
                        Text("Low").tag(1)
                        Text("Medium").tag(2)
                        Text("High").tag(3)
                        Text("Critical").tag(4)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Location") {
                    Text("Your current location will be shared")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .navigationTitle("SOS Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send SOS") {
                        // TODO: Submit SOS alert
                        dismiss()
                    }
                    .foregroundColor(.red)
                    .fontWeight(.bold)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showPanicConfirmation = false
    @State private var showRecoveryKey = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let user = authService.currentUser {
                        TrustScoreRow(trustScore: user.trustScore)
                        LabeledContent("Status", value: user.isVerified ? "Verified" : "Unverified")
                    }
                }

                Section("Community") {
                    NavigationLink {
                        InvitesView()
                    } label: {
                        HStack {
                            Image(systemName: "envelope.badge.person.crop")
                                .foregroundColor(.orange)
                            Text("Invites")
                            Spacer()
                            if let user = authService.currentUser, user.trustScore >= 30 {
                                Text("Available")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        Text("Vouching coming soon...")
                    } label: {
                        HStack {
                            Image(systemName: "person.badge.shield.checkmark")
                                .foregroundColor(.orange)
                            Text("Vouches")
                        }
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
                    Button(action: { showRecoveryKey = true }) {
                        HStack {
                            Image(systemName: "key")
                            Text("Export Recovery Key")
                        }
                    }

                    Button(role: .destructive, action: { showPanicConfirmation = true }) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Panic Wipe")
                        }
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
            .sheet(isPresented: $showRecoveryKey) {
                RecoveryKeyExportView()
            }
        }
    }
}

// MARK: - Trust Score Row

struct TrustScoreRow: View {
    let trustScore: Int
    @State private var showLevels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trust Score")
                Spacer()
                Text("\(trustScore)")
                    .fontWeight(.semibold)
                    .foregroundColor(trustColor)
                Image(systemName: showLevels ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showLevels.toggle()
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 6)
                        .cornerRadius(3)

                    Rectangle()
                        .fill(trustColor)
                        .frame(width: min(CGFloat(trustScore) / 100.0 * geometry.size.width, geometry.size.width), height: 6)
                        .cornerRadius(3)
                }
            }
            .frame(height: 6)

            // Next milestone
            if let nextMilestone = nextMilestone {
                Text(nextMilestone)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Expandable trust levels
            if showLevels {
                VStack(spacing: 0) {
                    Divider()
                        .padding(.vertical, 8)
                    TrustLevelRow(level: 15, label: "Browse & View", icon: "eye", currentScore: trustScore)
                    TrustLevelRow(level: 25, label: "Create Posts", icon: "square.and.pencil", currentScore: trustScore)
                    TrustLevelRow(level: 30, label: "Generate Invites", icon: "envelope.badge.person.crop", currentScore: trustScore)
                    TrustLevelRow(level: 50, label: "Create Events", icon: "calendar.badge.plus", currentScore: trustScore)
                    TrustLevelRow(level: 100, label: "Send SOS Alerts", icon: "exclamationmark.triangle.fill", currentScore: trustScore)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var trustColor: Color {
        switch trustScore {
        case 0..<15: return .red
        case 15..<25: return .orange
        case 25..<50: return .yellow
        case 50..<100: return .green
        default: return .blue
        }
    }

    private var nextMilestone: String? {
        if trustScore < 25 {
            return "Reach 25 to create posts"
        } else if trustScore < 30 {
            return "Reach 30 to generate invites"
        } else if trustScore < 50 {
            return "Reach 50 to create events"
        } else if trustScore < 100 {
            return "Reach 100 to send SOS alerts"
        }
        return nil
    }
}

struct TrustLevelRow: View {
    let level: Int
    let label: String
    let icon: String
    let currentScore: Int

    private var isUnlocked: Bool { currentScore >= level }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isUnlocked ? "checkmark.circle.fill" : "lock.fill")
                .foregroundColor(isUnlocked ? .green : .gray)
                .font(.caption)
                .frame(width: 20)

            Image(systemName: icon)
                .foregroundColor(isUnlocked ? .orange : .gray)
                .font(.caption)
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundColor(isUnlocked ? .primary : .secondary)

            Spacer()

            Text("\(level)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(isUnlocked ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recovery Key Export

struct RecoveryKeyExportView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) var dismiss
    @State private var recoveryKey: String = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)

                Text("Your Recovery Key")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Store this key safely. It's the ONLY way to recover your account if you lose access.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                if !recoveryKey.isEmpty {
                    Text(recoveryKey)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .textSelection(.enabled)

                    Button(action: copyKey) {
                        HStack {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied!" : "Copy to Clipboard")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(copied ? Color.green : Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                Spacer()

                Text("Never share this key with anyone!")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .padding()
            .navigationTitle("Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let data = authService.exportRecoveryData() {
                    recoveryKey = data.base64EncodedString()
                }
            }
        }
    }

    private func copyKey() {
        UIPasteboard.general.string = recoveryKey
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
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
