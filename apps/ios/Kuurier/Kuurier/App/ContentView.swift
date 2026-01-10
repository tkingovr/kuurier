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

    var body: some View {
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
                Task {
                    await authService.authenticate()
                }
            }) {
                if authService.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("Get Started")
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.orange)
            .foregroundColor(.white)
            .cornerRadius(12)
            .padding(.horizontal)
            .disabled(authService.isLoading)

            if let error = authService.error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            // Recovery option
            Button("Recover existing account") {
                // Show recovery flow
            }
            .font(.footnote)
            .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
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
