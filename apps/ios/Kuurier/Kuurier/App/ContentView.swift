import SwiftUI
import MapKit
import CoreLocation
import Combine

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
    @StateObject private var feedService = FeedService.shared
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
            Group {
                if feedService.posts.isEmpty && !feedService.isLoading {
                    emptyStateView
                } else {
                    postListView
                }
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
            .task {
                await feedService.fetchFeed()
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "newspaper")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("No posts yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Be the first to share what's happening")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if canPost {
                Button("Create Post") {
                    showComposeSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var postListView: some View {
        List {
            ForEach(feedService.posts) { post in
                PostRowView(post: post)
            }

            // Load more indicator
            if feedService.hasMorePosts {
                HStack {
                    Spacer()
                    ProgressView()
                        .onAppear {
                            Task {
                                await feedService.loadMorePosts()
                            }
                        }
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await feedService.fetchFeed(refresh: true)
        }
    }
}

// MARK: - Post Row View

struct PostRowView: View {
    let post: Post
    @StateObject private var feedService = FeedService.shared
    @State private var showActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                sourceTypeBadge
                Spacer()
                urgencyIndicator
                Text(post.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Content
            Text(post.content)
                .font(.body)

            // Location if available
            if let locationName = post.locationName {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption)
                    Text(locationName)
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            // Actions
            HStack(spacing: 20) {
                // Verify button
                Button(action: {
                    Task { await feedService.verifyPost(id: post.id) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("\(post.verificationScore)")
                    }
                    .font(.caption)
                    .foregroundColor(post.verificationScore > 0 ? .green : .secondary)
                }
                .buttonStyle(.plain)

                // Flag button
                Button(action: {
                    Task { await feedService.flagPost(id: post.id) }
                }) {
                    Image(systemName: "flag")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                // Share
                ShareLink(item: post.content) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var sourceTypeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: sourceIcon)
            Text(sourceLabel)
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(sourceColor.opacity(0.15))
        .foregroundColor(sourceColor)
        .cornerRadius(4)
    }

    private var sourceIcon: String {
        switch post.sourceType {
        case .firsthand: return "eye.fill"
        case .aggregated: return "arrow.triangle.merge"
        case .mainstream: return "newspaper.fill"
        }
    }

    private var sourceLabel: String {
        switch post.sourceType {
        case .firsthand: return "Firsthand"
        case .aggregated: return "Aggregated"
        case .mainstream: return "News"
        }
    }

    private var sourceColor: Color {
        switch post.sourceType {
        case .firsthand: return .green
        case .aggregated: return .blue
        case .mainstream: return .purple
        }
    }

    private var urgencyIndicator: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                Circle()
                    .fill(level <= post.urgency ? urgencyColor : Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var urgencyColor: Color {
        switch post.urgency {
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        default: return .gray
        }
    }
}

// MARK: - Compose Post View

struct ComposePostView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var feedService = FeedService.shared
    @State private var content = ""
    @State private var sourceType: SourceType = .firsthand
    @State private var urgency: Int = 1
    @State private var includeLocation = false
    @State private var locationName: String = ""

    private let maxCharacters = 500

    var body: some View {
        NavigationStack {
            Form {
                // Error display
                if let error = feedService.error {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .foregroundColor(.red)
                        }
                    }
                }

                // Content Section
                Section("Content") {
                    TextEditor(text: $content)
                        .frame(minHeight: 100)
                        .onChange(of: content) { _, newValue in
                            if newValue.count > maxCharacters {
                                content = String(newValue.prefix(maxCharacters))
                            }
                        }

                    HStack {
                        Spacer()
                        Text("\(content.count)/\(maxCharacters)")
                            .font(.caption)
                            .foregroundColor(content.count > maxCharacters - 50 ? .orange : .secondary)
                    }
                }

                // Source Section
                Section("Source") {
                    Picker("Source Type", selection: $sourceType) {
                        Label("Firsthand", systemImage: "eye.fill").tag(SourceType.firsthand)
                        Label("Aggregated", systemImage: "arrow.triangle.merge").tag(SourceType.aggregated)
                        Label("Mainstream", systemImage: "newspaper.fill").tag(SourceType.mainstream)
                    }
                    .tint(.orange)

                    Text(sourceDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Urgency Section
                Section("Urgency Level") {
                    HStack {
                        Text("Urgency: \(urgency)")
                        Spacer()
                        Stepper("", value: $urgency, in: 1...3)
                            .labelsHidden()
                    }

                    HStack {
                        ForEach(1...5, id: \.self) { dot in
                            Circle()
                                .fill(dotColor(for: dot))
                                .frame(width: 12, height: 12)
                        }
                        Spacer()
                        Text(urgencyLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Location Section
                Section("Location") {
                    Toggle("Include Location", isOn: $includeLocation)
                        .tint(.orange)

                    if includeLocation {
                        TextField("Location name (optional)", text: $locationName)

                        Button(action: getCurrentLocation) {
                            Text("Get Current Location")
                                .foregroundColor(.orange)
                        }
                    }

                    Text("Location helps others nearby see relevant posts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(feedService.isCreatingPost)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submitPost) {
                        if feedService.isCreatingPost {
                            ProgressView()
                        } else {
                            Text("Post")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feedService.isCreatingPost)
                }
            }
            .interactiveDismissDisabled(feedService.isCreatingPost)
        }
    }

    private var sourceDescription: String {
        switch sourceType {
        case .firsthand: return "You witnessed this directly"
        case .aggregated: return "Information gathered from multiple sources"
        case .mainstream: return "From mainstream news outlets"
        }
    }

    private func dotColor(for dot: Int) -> Color {
        let filledDots: Int
        switch urgency {
        case 1: filledDots = 1
        case 2: filledDots = 3
        case 3: filledDots = 5
        default: filledDots = 1
        }

        if dot <= filledDots {
            switch urgency {
            case 1: return .green
            case 2: return .yellow
            case 3: return .red
            default: return .green
            }
        }
        return Color.gray.opacity(0.3)
    }

    private var urgencyLabel: String {
        switch urgency {
        case 1: return "Low"
        case 2: return "Medium"
        case 3: return "High"
        default: return "Low"
        }
    }

    private func getCurrentLocation() {
        // TODO: Implement location services
    }

    private func submitPost() {
        print("ComposePostView: Submit button tapped")
        Task {
            print("ComposePostView: Calling createPost...")
            let success = await feedService.createPost(
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceType: sourceType,
                locationName: includeLocation && !locationName.isEmpty ? locationName : nil,
                urgency: urgency
            )
            print("ComposePostView: createPost returned success=\(success)")
            if success {
                dismiss()
            }
        }
    }
}

struct MapView: View {
    @StateObject private var mapService = MapService.shared
    @StateObject private var locationManager = LocationManager()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedMarker: MapMarker?
    @State private var showMarkerDetail = false
    @State private var currentZoom: Int = 5

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $cameraPosition) {
                    // User location
                    UserAnnotation()

                    // Markers from API
                    ForEach(mapService.markers) { marker in
                        if marker.type == .cluster {
                            // Cluster annotation
                            Annotation("", coordinate: marker.coordinate) {
                                ClusterMarkerView(
                                    count: marker.count ?? 0,
                                    maxUrgency: marker.maxUrgency ?? 1
                                )
                                .onTapGesture {
                                    // Zoom in on cluster
                                    zoomToCluster(marker)
                                }
                            }
                        } else {
                            // Individual post marker
                            Annotation("", coordinate: marker.coordinate) {
                                PostMarkerView(
                                    urgency: marker.maxUrgency ?? 1,
                                    sourceType: marker.sourceType ?? "firsthand"
                                )
                                .onTapGesture {
                                    selectedMarker = marker
                                    showMarkerDetail = true
                                }
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    let region = context.region
                    let mapRegion = MapRegion(
                        minLat: region.center.latitude - region.span.latitudeDelta / 2,
                        maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                        minLon: region.center.longitude - region.span.longitudeDelta / 2,
                        maxLon: region.center.longitude + region.span.longitudeDelta / 2
                    )

                    // Calculate zoom level from span
                    let zoom = calculateZoom(from: region.span.latitudeDelta)
                    currentZoom = zoom

                    Task {
                        await mapService.fetchMarkers(region: mapRegion, zoom: zoom)
                    }
                }

                // Loading indicator
                if mapService.isLoading {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding()
                        }
                    }
                }

                // Recenter button
                VStack {
                    Spacer()
                    HStack {
                        Button(action: centerOnUser) {
                            Image(systemName: "location.fill")
                                .font(.title2)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .padding()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showMarkerDetail) {
                if let marker = selectedMarker {
                    MarkerDetailSheet(marker: marker)
                        .presentationDetents([.medium])
                }
            }
            .onAppear {
                locationManager.requestPermission()
            }
        }
    }

    private func calculateZoom(from latDelta: Double) -> Int {
        // Rough conversion from latitude delta to zoom level
        switch latDelta {
        case 0..<0.01: return 15
        case 0.01..<0.05: return 13
        case 0.05..<0.1: return 12
        case 0.1..<0.5: return 10
        case 0.5..<1: return 8
        case 1..<5: return 6
        case 5..<20: return 4
        default: return 2
        }
    }

    private func zoomToCluster(_ marker: MapMarker) {
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: marker.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ))
        }
    }

    private func centerOnUser() {
        if let location = locationManager.location {
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
                ))
            }
        }
    }
}

// MARK: - Cluster Marker View

struct ClusterMarkerView: View {
    let count: Int
    let maxUrgency: Int

    private var backgroundColor: Color {
        switch maxUrgency {
        case 3: return .red
        case 2: return .orange
        default: return .blue
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.8))
                .frame(width: markerSize, height: markerSize)

            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: markerSize, height: markerSize)

            Text(formattedCount)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var markerSize: CGFloat {
        switch count {
        case 0..<10: return 36
        case 10..<50: return 44
        case 50..<100: return 52
        default: return 60
        }
    }

    private var fontSize: CGFloat {
        switch count {
        case 0..<10: return 12
        case 10..<100: return 11
        default: return 10
        }
    }

    private var formattedCount: String {
        if count >= 1000 {
            return "\(count / 1000)k+"
        } else if count >= 100 {
            return "\(count)+"
        }
        return "\(count)"
    }
}

// MARK: - Post Marker View

struct PostMarkerView: View {
    let urgency: Int
    let sourceType: String

    private var markerColor: Color {
        switch urgency {
        case 3: return .red
        case 2: return .orange
        default: return .green
        }
    }

    private var sourceIcon: String {
        switch sourceType {
        case "firsthand": return "eye.fill"
        case "aggregated": return "arrow.triangle.merge"
        case "mainstream": return "newspaper.fill"
        default: return "circle.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(markerColor)
                    .frame(width: 32, height: 32)

                Image(systemName: sourceIcon)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }

            // Pin point
            Triangle()
                .fill(markerColor)
                .frame(width: 12, height: 8)
                .offset(y: -2)
        }
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Marker Detail Sheet

struct MarkerDetailSheet: View {
    let marker: MapMarker
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // Source badge
                HStack {
                    sourceTypeBadge
                    Spacer()
                    urgencyIndicator
                }

                // Content
                if let content = marker.content {
                    Text(content)
                        .font(.body)
                }

                // Time
                if let createdAt = marker.createdAt {
                    HStack {
                        Image(systemName: "clock")
                            .font(.caption)
                        Text(createdAt, style: .relative)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                // Actions
                HStack(spacing: 16) {
                    Button(action: {}) {
                        Label("Verify", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)

                    Button(action: {}) {
                        Label("Flag", systemImage: "flag")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Spacer()

                    ShareLink(item: marker.content ?? "") {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var sourceTypeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: sourceIcon)
            Text(sourceLabel)
        }
        .font(.caption)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(sourceColor.opacity(0.15))
        .foregroundColor(sourceColor)
        .cornerRadius(4)
    }

    private var sourceIcon: String {
        switch marker.sourceType {
        case "firsthand": return "eye.fill"
        case "aggregated": return "arrow.triangle.merge"
        case "mainstream": return "newspaper.fill"
        default: return "circle.fill"
        }
    }

    private var sourceLabel: String {
        switch marker.sourceType {
        case "firsthand": return "Firsthand"
        case "aggregated": return "Aggregated"
        case "mainstream": return "News"
        default: return "Unknown"
        }
    }

    private var sourceColor: Color {
        switch marker.sourceType {
        case "firsthand": return .green
        case "aggregated": return .blue
        case "mainstream": return .purple
        default: return .gray
        }
    }

    private var urgencyIndicator: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                Circle()
                    .fill(level <= (marker.maxUrgency ?? 1) ? urgencyColor : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var urgencyColor: Color {
        switch marker.maxUrgency {
        case 1: return .green
        case 2: return .yellow
        case 3: return .red
        default: return .gray
        }
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
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
