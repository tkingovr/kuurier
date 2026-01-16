import SwiftUI
import MapKit
import CoreLocation
import Combine
import PhotosUI
import LocalAuthentication

struct ContentView: View {

    @EnvironmentObject var authService: AuthService
    @State private var selectedTab: Tab = .discover

    enum Tab {
        case discover, messages, events, alerts, settings
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
            DiscoverView()
                .tabItem {
                    Label("Discover", systemImage: "globe")
                }
                .tag(Tab.discover)

            MessagesTabView()
                .tabItem {
                    Label("Messages", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.messages)

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

// MARK: - Discover View (Combined Feed + Map)

struct DiscoverView: View {
    @State private var viewMode: DiscoverMode = .feed

    enum DiscoverMode: String, CaseIterable {
        case feed = "Feed"
        case map = "Map"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // View mode picker
                Picker("View", selection: $viewMode) {
                    ForEach(DiscoverMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Content based on selected mode
                switch viewMode {
                case .feed:
                    FeedContentView()
                case .map:
                    MapContentView()
                }
            }
            .navigationTitle("Discover")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if viewMode == .feed {
                        FeedComposeButton()
                    }
                }
            }
        }
    }
}

// MARK: - Feed Content View (without NavigationStack)

struct FeedContentView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var feedService = FeedService.shared
    @State private var showComposeSheet = false
    @State private var showLockedAlert = false

    private var canPost: Bool {
        guard let user = authService.currentUser else { return false }
        return user.trustScore >= 25
    }

    var body: some View {
        Group {
            if feedService.posts.isEmpty && !feedService.isLoading {
                ContentUnavailableView(
                    "No posts yet",
                    systemImage: "newspaper",
                    description: Text("Be the first to share what's happening")
                )
            } else {
                List {
                    ForEach(feedService.posts) { post in
                        PostRowView(post: post)
                    }

                    if feedService.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await feedService.fetchFeed()
                }
            }
        }
        .sheet(isPresented: $showComposeSheet) {
            ComposePostView()
        }
        .task {
            await feedService.fetchFeed()
        }
    }
}

// MARK: - Map Content View (without NavigationStack)

struct MapContentView: View {
    @StateObject private var mapService = MapService.shared
    @StateObject private var eventsService = EventsService.shared
    @State private var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.0, longitude: 30.0),
        span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 150)
    ))
    @State private var selectedMarker: MapMarker?
    @State private var showMarkerDetail = false
    @State private var selectedEvent: Event?
    @State private var showEventDetail = false
    @State private var publicEvents: [Event] = []
    @State private var heatmapCells: [HeatmapCell] = []
    @State private var currentZoom: Int = 5

    var body: some View {
        ZStack {
            Map(position: $cameraPosition) {
                UserAnnotation()

                // Heatmap zones
                ForEach(heatmapCells, id: \.latitude) { cell in
                    MapCircle(
                        center: CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude),
                        radius: heatmapRadius(for: currentZoom, count: cell.count)
                    )
                    .foregroundStyle(heatmapColor(for: cell).opacity(0.4))
                    .stroke(heatmapColor(for: cell), lineWidth: cell.maxUrgency >= 3 ? 3 : 1)
                }

                // Markers from API
                ForEach(mapService.markers) { marker in
                    if marker.type == .cluster {
                        Annotation("", coordinate: marker.coordinate) {
                            ClusterMarkerView(
                                count: marker.count ?? 0,
                                maxUrgency: marker.maxUrgency ?? 1
                            )
                        }
                    } else {
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

                // Public events
                ForEach(publicEvents) { event in
                    if let location = event.location {
                        Annotation("", coordinate: location.coordinate) {
                            EventMarkerView(eventType: event.eventType)
                                .onTapGesture {
                                    selectedEvent = event
                                    showEventDetail = true
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
                let zoom = calculateZoom(from: region.span.latitudeDelta)
                currentZoom = zoom

                Task {
                    // Create MapRegion from the visible region
                    let mapRegion = MapRegion(
                        minLat: region.center.latitude - region.span.latitudeDelta / 2,
                        maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                        minLon: region.center.longitude - region.span.longitudeDelta / 2,
                        maxLon: region.center.longitude + region.span.longitudeDelta / 2
                    )

                    let gridSize = gridSizeForZoom(zoom)
                    heatmapCells = await mapService.fetchHeatmap(region: mapRegion, gridSize: gridSize)

                    await mapService.fetchMarkers(region: mapRegion, zoom: zoom)

                    publicEvents = await eventsService.fetchPublicEventsForMap(
                        minLat: mapRegion.minLat,
                        maxLat: mapRegion.maxLat,
                        minLon: mapRegion.minLon,
                        maxLon: mapRegion.maxLon
                    )
                }
            }
        }
        .sheet(isPresented: $showMarkerDetail) {
            if let marker = selectedMarker {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        if let content = marker.content {
                            Text(content)
                                .font(.body)
                        }
                        if let createdAt = marker.createdAt {
                            Text(createdAt, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let sourceType = marker.sourceType {
                            HStack {
                                Image(systemName: sourceType == "firsthand" ? "person.fill" : "arrow.triangle.branch")
                                Text(sourceType.capitalized)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .navigationTitle(marker.type == .cluster ? "Cluster (\(marker.count ?? 0))" : "Post")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showMarkerDetail = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showEventDetail) {
            if let event = selectedEvent {
                EventDetailView(event: event)
            }
        }
    }

    private func heatmapRadius(for zoom: Int, count: Int) -> CLLocationDistance {
        let baseRadius: Double = 50000
        let zoomFactor = pow(2.0, Double(max(0, 10 - zoom)))
        let countFactor = min(2.0, 1.0 + Double(count) / 50.0)
        return baseRadius * zoomFactor * countFactor
    }

    private func heatmapColor(for cell: HeatmapCell) -> Color {
        switch cell.maxUrgency {
        case 1: return .green
        case 2: return .yellow
        case 3: return .orange
        case 4...5: return .red
        default: return .blue
        }
    }

    private func calculateZoom(from latDelta: Double) -> Int {
        let zoom = Int(log2(360.0 / latDelta))
        return max(1, min(20, zoom))
    }

    private func gridSizeForZoom(_ zoom: Int) -> Double {
        switch zoom {
        case 0...4: return 2.0   // Large grid for zoomed out
        case 5...8: return 1.0   // Medium grid
        default: return 0.5     // Small grid for zoomed in
        }
    }
}

// MARK: - Feed Compose Button

struct FeedComposeButton: View {
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

// MARK: - Legacy Feed View (kept for reference)

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

            // Media (images/videos)
            if let media = post.media, !media.isEmpty {
                PostMediaView(media: media)
            }

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

// MARK: - Post Media View

struct PostMediaView: View {
    let media: [PostMedia]
    @State private var selectedMedia: PostMedia?

    var body: some View {
        if media.count == 1 {
            // Single media item - show larger
            singleMediaView(media[0])
        } else {
            // Multiple items - horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(media) { item in
                        mediaItemView(item)
                            .frame(width: 150, height: 150)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func singleMediaView(_ item: PostMedia) -> some View {
        switch item.type {
        case .image:
            AsyncImage(url: URL(string: item.url)) { phase in
                switch phase {
                case .empty:
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 200)
                        .overlay {
                            ProgressView()
                        }
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxHeight: 300)
                        .clipped()
                        .cornerRadius(12)
                case .failure:
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 200)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        }
                @unknown default:
                    EmptyView()
                }
            }
        case .video:
            ZStack {
                AsyncImage(url: URL(string: item.url)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 200)
                            .clipped()
                    default:
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 200)
                    }
                }
                .cornerRadius(12)

                // Play button overlay
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
            }
        }
    }

    @ViewBuilder
    private func mediaItemView(_ item: PostMedia) -> some View {
        switch item.type {
        case .image:
            AsyncImage(url: URL(string: item.url)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                default:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .overlay {
                            ProgressView()
                        }
                }
            }
            .cornerRadius(8)
        case .video:
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Media Thumbnail View (for compose)

struct MediaThumbnailView: View {
    let item: SelectedMediaItem
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 80)
                    .overlay {
                        Image(systemName: item.type == .video ? "video" : "photo")
                            .foregroundColor(.secondary)
                    }
            }

            // Video indicator
            if item.type == .video {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(4)
            }

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - Upload Progress Overlay

struct UploadProgressOverlay: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                    .tint(.orange)

                Text("Uploading media... \(Int(progress * 100))%")
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

// MARK: - Camera View

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Compose Post View

struct ComposePostView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var feedService = FeedService.shared
    @StateObject private var mediaService = MediaService.shared
    @State private var content = ""
    @State private var sourceType: SourceType = .firsthand
    @State private var urgency: Int = 1
    @State private var includeLocation = false
    @State private var locationName: String = ""

    // Media selection state
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showingCamera = false

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

                // Media Section
                Section("Media") {
                    // Selected media thumbnails
                    if !mediaService.selectedItems.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(mediaService.selectedItems) { item in
                                    MediaThumbnailView(item: item) {
                                        mediaService.removeItem(id: item.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Add media buttons
                    if mediaService.canAddMore {
                        HStack(spacing: 16) {
                            PhotosPicker(
                                selection: $selectedPhotoItems,
                                maxSelectionCount: mediaService.remainingSlots,
                                matching: .any(of: [.images, .videos])
                            ) {
                                Label("Photo Library", systemImage: "photo.on.rectangle")
                            }
                            .onChange(of: selectedPhotoItems) { _, newItems in
                                Task {
                                    await mediaService.processPickerSelection(newItems)
                                    selectedPhotoItems = []
                                }
                            }

                            Button {
                                showingCamera = true
                            } label: {
                                Label("Camera", systemImage: "camera")
                            }
                        }
                        .foregroundColor(.orange)
                    }

                    // Status text
                    Text("\(mediaService.selectedItems.count)/5 media items")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    .disabled(
                        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        feedService.isCreatingPost ||
                        mediaService.isUploading
                    )
                }
            }
            .interactiveDismissDisabled(feedService.isCreatingPost || mediaService.isUploading)
            .overlay {
                if mediaService.isUploading {
                    UploadProgressOverlay(progress: mediaService.uploadProgress)
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraView { image in
                    if let data = image.jpegData(compressionQuality: 0.8) {
                        let item = SelectedMediaItem(
                            data: data,
                            thumbnail: image,
                            type: .image,
                            originalFilename: "camera_photo.jpg"
                        )
                        mediaService.addItem(item)
                    }
                }
            }
            .onDisappear {
                mediaService.clearSelection()
            }
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

            // Step 1: Create the post
            guard let postId = await feedService.createPost(
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceType: sourceType,
                locationName: includeLocation && !locationName.isEmpty ? locationName : nil,
                urgency: urgency
            ) else {
                print("ComposePostView: createPost failed")
                return
            }

            print("ComposePostView: Post created with id=\(postId)")

            // Step 2: Upload and attach media if any
            if !mediaService.selectedItems.isEmpty {
                print("ComposePostView: Uploading \(mediaService.selectedItems.count) media items...")
                let uploadedUrls = await mediaService.uploadAndAttachMedia(to: postId)
                print("ComposePostView: Uploaded \(uploadedUrls.count) media items")
            }

            // Step 3: Finish and refresh
            await feedService.finishPostCreation(success: true)
            mediaService.clearSelection()
            dismiss()
        }
    }
}

struct MapView: View {
    @StateObject private var mapService = MapService.shared
    @StateObject private var eventsService = EventsService.shared
    @StateObject private var locationManager = LocationManager()
    // Start zoomed out to show global view - centered on Middle East/Africa where most activity is
    @State private var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.0, longitude: 30.0),
        span: MKCoordinateSpan(latitudeDelta: 100, longitudeDelta: 150)
    ))
    @State private var selectedMarker: MapMarker?
    @State private var showMarkerDetail = false
    @State private var selectedEvent: Event?
    @State private var showEventDetail = false
    @State private var publicEvents: [Event] = []
    @State private var heatmapCells: [HeatmapCell] = []
    @State private var currentZoom: Int = 5
    @State private var pulseAnimation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $cameraPosition) {
                    // User location
                    UserAnnotation()

                    // Heatmap zones - activity hotspots based on post density and urgency
                    ForEach(heatmapCells, id: \.latitude) { cell in
                        MapCircle(
                            center: CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude),
                            radius: heatmapRadius(for: currentZoom, count: cell.count)
                        )
                        .foregroundStyle(heatmapColor(for: cell).opacity(pulseAnimation && cell.maxUrgency >= 3 ? 0.6 : 0.4))
                        .stroke(heatmapColor(for: cell), lineWidth: cell.maxUrgency >= 3 ? 3 : 1)
                    }

                    // Markers from API (clusters/individual posts)
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

                    // Public event markers
                    ForEach(publicEvents) { event in
                        if let location = event.location {
                            Annotation("", coordinate: location.coordinate) {
                                EventMarkerView(eventType: event.eventType)
                                    .onTapGesture {
                                        selectedEvent = event
                                        showEventDetail = true
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
                        // Calculate grid size based on zoom level
                        let gridSize = gridSizeForZoom(zoom)

                        // Fetch heatmap, markers, and events in parallel
                        async let heatmapTask = mapService.fetchHeatmap(region: mapRegion, gridSize: gridSize)
                        async let markersTask: () = mapService.fetchMarkers(region: mapRegion, zoom: zoom)
                        async let eventsTask = eventsService.fetchPublicEventsForMap(
                            minLat: mapRegion.minLat,
                            maxLat: mapRegion.maxLat,
                            minLon: mapRegion.minLon,
                            maxLon: mapRegion.maxLon
                        )

                        heatmapCells = await heatmapTask
                        await markersTask
                        publicEvents = await eventsTask
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
            .sheet(isPresented: $showEventDetail) {
                if let event = selectedEvent {
                    NavigationStack {
                        EventDetailView(event: event)
                    }
                    .presentationDetents([.large])
                }
            }
            .onAppear {
                locationManager.requestPermission()
                // Start pulse animation for high-urgency zones
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            }
        }
    }

    // MARK: - Heatmap Helpers

    private func heatmapColor(for cell: HeatmapCell) -> Color {
        switch cell.maxUrgency {
        case 3: return .red        // Critical - active crisis
        case 2: return .orange     // High - significant activity
        default: return .yellow    // Normal - some activity
        }
    }

    private func heatmapRadius(for zoom: Int, count: Int) -> CLLocationDistance {
        // Radius in meters, scales based on zoom and post count
        let baseRadius: Double
        switch zoom {
        case 0..<4: baseRadius = 500_000   // Very zoomed out - large regions
        case 4..<8: baseRadius = 200_000   // Continental view
        case 8..<10: baseRadius = 50_000   // Country view
        case 10..<12: baseRadius = 20_000  // Region view
        case 12..<14: baseRadius = 5_000   // City view
        default: baseRadius = 1_000        // Street view
        }

        // Scale up based on post count
        let countMultiplier = 1.0 + min(Double(count) / 10.0, 2.0)
        return baseRadius * countMultiplier
    }

    private func gridSizeForZoom(_ zoom: Int) -> Double {
        // Grid size in degrees for heatmap aggregation
        switch zoom {
        case 0..<4: return 5.0    // Very large cells for world view
        case 4..<6: return 2.0    // Large cells
        case 6..<8: return 1.0    // Medium cells
        case 8..<10: return 0.5   // Smaller cells
        case 10..<12: return 0.1  // City-level
        default: return 0.05      // Fine detail
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

// MARK: - Event Marker View

struct EventMarkerView: View {
    let eventType: EventType

    private var markerColor: Color {
        switch eventType {
        case .protest: return .purple
        case .strike: return .red
        case .fundraiser: return .pink
        case .mutualAid: return .teal
        case .meeting: return .blue
        case .other: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Event marker with distinct shape (rounded square)
                RoundedRectangle(cornerRadius: 8)
                    .fill(markerColor)
                    .frame(width: 36, height: 36)

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white, lineWidth: 2)
                    .frame(width: 36, height: 36)

                Image(systemName: eventType.icon)
                    .font(.system(size: 16, weight: .semibold))
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
    @StateObject private var eventsService = EventsService.shared
    @State private var showCreateSheet = false
    @State private var showLockedAlert = false
    @State private var selectedEventType: EventType?
    @State private var selectedEvent: Event?

    private var canCreateEvent: Bool {
        guard let user = authService.currentUser else { return false }
        return user.trustScore >= 50
    }

    private var trustNeeded: Int {
        guard let user = authService.currentUser else { return 50 }
        return max(0, 50 - user.trustScore)
    }

    private var filteredEvents: [Event] {
        if let type = selectedEventType {
            return eventsService.events.filter { $0.eventType == type }
        }
        return eventsService.events
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Event type filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "All", isSelected: selectedEventType == nil) {
                            selectedEventType = nil
                        }
                        ForEach(EventType.allCases, id: \.self) { type in
                            FilterChip(
                                title: type.displayName,
                                icon: type.icon,
                                isSelected: selectedEventType == type
                            ) {
                                selectedEventType = type
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(UIColor.systemGroupedBackground))

                // Events list
                List {
                    if filteredEvents.isEmpty && !eventsService.isLoading {
                        ContentUnavailableView(
                            "No Events",
                            systemImage: "calendar",
                            description: Text("No upcoming events found")
                        )
                    } else {
                        ForEach(filteredEvents) { event in
                            EventRowView(event: event)
                                .onTapGesture {
                                    selectedEvent = event
                                }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await eventsService.fetchEvents(refresh: true)
                }
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
            .sheet(item: $selectedEvent) { event in
                EventDetailView(event: event)
            }
            .alert("Event Creation Locked", isPresented: $showLockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You need a trust score of 50 to create events. Get \(trustNeeded) more point\(trustNeeded == 1 ? "" : "s") by receiving vouches from trusted members.")
            }
            .task {
                await eventsService.fetchEvents()
            }
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.orange : Color(UIColor.secondarySystemGroupedBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
    }
}

// MARK: - Event Row View

struct EventRowView: View {
    let event: Event

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Type badge and date
            HStack {
                Label(event.eventType.displayName, systemImage: event.eventType.icon)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(eventTypeColor.opacity(0.15))
                    .foregroundColor(eventTypeColor)
                    .cornerRadius(4)

                Spacer()

                Text(event.startsAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Title
            Text(event.title)
                .font(.headline)
                .lineLimit(2)

            // Location info
            HStack(spacing: 4) {
                if event.locationRevealed, let location = event.location {
                    Image(systemName: "mappin")
                        .font(.caption)
                    if let name = event.locationName {
                        Text(name)
                    } else {
                        Text(String(format: "%.4f, %.4f", location.latitude, location.longitude))
                    }
                } else if let area = event.locationArea {
                    Image(systemName: "map")
                        .font(.caption)
                    Text(area)
                    Text("•")
                    if event.locationVisibility == .rsvp {
                        Text("RSVP to see location")
                            .foregroundColor(.orange)
                    } else if event.locationVisibility == .timed, let revealAt = event.locationRevealAt {
                        Text("Revealed \(revealAt, style: .relative)")
                            .foregroundColor(.orange)
                    }
                } else {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                    Text("Location hidden")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            // Footer: Time and RSVP count
            HStack {
                Image(systemName: "clock")
                Text(event.startsAt, style: .time)

                Spacer()

                if let count = event.rsvpCount, count > 0 {
                    Label("\(count) going", systemImage: "person.2.fill")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var eventTypeColor: Color {
        switch event.eventType {
        case .protest: return .red
        case .strike: return .orange
        case .fundraiser: return .pink
        case .mutualAid: return .green
        case .meeting: return .blue
        case .other: return .gray
        }
    }
}

// MARK: - Event Detail View

struct EventDetailView: View {
    let event: Event
    @Environment(\.dismiss) var dismiss
    @StateObject private var eventsService = EventsService.shared
    @EnvironmentObject var authService: AuthService
    @State private var currentEvent: Event
    @State private var isRSVPing = false

    init(event: Event) {
        self.event = event
        _currentEvent = State(initialValue: event)
    }

    private var isOrganizer: Bool {
        authService.currentUser?.id == currentEvent.organizerId
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Event type and status
                    HStack {
                        Label(currentEvent.eventType.displayName, systemImage: currentEvent.eventType.icon)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(6)

                        if currentEvent.isCancelled == true {
                            Text("CANCELLED")
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }

                        Spacer()

                        // Visibility badge
                        Label(currentEvent.locationVisibility.displayName, systemImage: visibilityIcon)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(4)
                    }

                    // Title
                    Text(currentEvent.title)
                        .font(.title2)
                        .fontWeight(.bold)

                    // Date and time
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(currentEvent.startsAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        .font(.subheadline)

                        if let endsAt = currentEvent.endsAt {
                            Label {
                                Text("Until \(endsAt, format: .dateTime.hour().minute())")
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    // Location section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Location")
                            .font(.headline)

                        if currentEvent.locationRevealed, let location = currentEvent.location {
                            // Show map preview
                            Map(initialPosition: .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                            ))) {
                                Marker(currentEvent.locationName ?? "Event", coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
                            }
                            .frame(height: 150)
                            .cornerRadius(12)

                            if let name = currentEvent.locationName {
                                Label(name, systemImage: "mappin.circle.fill")
                                    .font(.subheadline)
                            }
                        } else {
                            // Location hidden
                            VStack(spacing: 8) {
                                Image(systemName: "lock.shield")
                                    .font(.largeTitle)
                                    .foregroundColor(.orange)

                                if let area = currentEvent.locationArea {
                                    Text("General area: \(area)")
                                        .font(.subheadline)
                                }

                                if currentEvent.locationVisibility == .rsvp {
                                    Text("RSVP to reveal the exact location")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else if currentEvent.locationVisibility == .timed, let revealAt = currentEvent.locationRevealAt {
                                    Text("Location reveals \(revealAt, style: .relative)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }

                    // Description
                    if let description = currentEvent.description, !description.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("About")
                                .font(.headline)
                            Text(description)
                                .font(.body)
                        }
                    }

                    Divider()

                    // RSVP section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Attendance")
                                .font(.headline)
                            Spacer()
                            if let count = currentEvent.rsvpCount, count > 0 {
                                Text("\(count) going")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !isOrganizer {
                            HStack(spacing: 12) {
                                RSVPButton(
                                    title: "Going",
                                    icon: "checkmark.circle.fill",
                                    isSelected: currentEvent.userRsvp == .going,
                                    color: .green
                                ) {
                                    await rsvp(.going)
                                }

                                RSVPButton(
                                    title: "Interested",
                                    icon: "star.fill",
                                    isSelected: currentEvent.userRsvp == .interested,
                                    color: .yellow
                                ) {
                                    await rsvp(.interested)
                                }

                                RSVPButton(
                                    title: "Can't Go",
                                    icon: "xmark.circle.fill",
                                    isSelected: currentEvent.userRsvp == .notGoing,
                                    color: .red
                                ) {
                                    await rsvp(.notGoing)
                                }
                            }
                        } else {
                            Text("You are the organizer")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Event Chat section
                    if let channelId = currentEvent.channelId {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Event Chat")
                                .font(.headline)

                            if currentEvent.isChannelMember == true || isOrganizer {
                                NavigationLink {
                                    ConversationView(channelId: channelId)
                                } label: {
                                    HStack {
                                        Image(systemName: "bubble.left.and.bubble.right.fill")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                            .frame(width: 44, height: 44)
                                            .background(Color.orange)
                                            .cornerRadius(10)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Open Chat")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text("Chat with other attendees")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "lock.fill")
                                        .font(.title2)
                                        .foregroundColor(.secondary)
                                    Text("RSVP to join the event chat")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var visibilityIcon: String {
        switch currentEvent.locationVisibility {
        case .public: return "globe"
        case .rsvp: return "person.badge.key"
        case .timed: return "clock.badge"
        }
    }

    private func rsvp(_ status: RSVPStatus) async {
        isRSVPing = true
        if await eventsService.rsvp(eventId: currentEvent.id, status: status) != nil {
            // Refetch the event to get updated state (including revealed location if applicable)
            if let updated = await eventsService.getEvent(id: currentEvent.id) {
                currentEvent = updated
            }
        }
        isRSVPing = false
    }
}

// MARK: - RSVP Button

struct RSVPButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () async -> Void

    @State private var isLoading = false

    var body: some View {
        Button {
            Task {
                isLoading = true
                await action()
                isLoading = false
            }
        } label: {
            VStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: icon)
                        .font(.title2)
                }
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? color.opacity(0.2) : Color(UIColor.secondarySystemBackground))
            .foregroundColor(isSelected ? color : .primary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? color : Color.clear, lineWidth: 2)
            )
        }
        .disabled(isLoading)
    }
}

// MARK: - Create Event View

struct CreateEventView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var eventsService = EventsService.shared
    @StateObject private var locationManager = LocationManager()

    // Form fields
    @State private var title = ""
    @State private var description = ""
    @State private var eventType: EventType = .meeting
    @State private var startsAt = Date().addingTimeInterval(3600) // 1 hour from now
    @State private var endsAt: Date?
    @State private var hasEndTime = false

    // Location
    @State private var locationName = ""
    @State private var locationArea = ""
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition = .automatic

    // Error handling
    @State private var showError = false
    @State private var errorMessage = ""

    // Privacy
    @State private var locationVisibility: LocationVisibility = .public
    @State private var revealHoursBefore: Int = 1

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selectedCoordinate != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // Event Details
                Section("Event Details") {
                    TextField("Title", text: $title)

                    Picker("Type", selection: $eventType) {
                        ForEach(EventType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.icon)
                                .tag(type)
                        }
                    }

                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                // Date & Time
                Section("Date & Time") {
                    DatePicker("Starts", selection: $startsAt, in: Date()...)

                    Toggle("Add End Time", isOn: $hasEndTime)

                    if hasEndTime {
                        DatePicker("Ends", selection: Binding(
                            get: { endsAt ?? startsAt.addingTimeInterval(7200) },
                            set: { endsAt = $0 }
                        ), in: startsAt...)
                    }
                }

                // Location
                Section {
                    // Map for location selection
                    Map(position: $cameraPosition, interactionModes: [.all]) {
                        if let coord = selectedCoordinate {
                            Marker("Event Location", coordinate: coord)
                        }
                        UserAnnotation()
                    }
                    .frame(height: 200)
                    .cornerRadius(8)
                    .onTapGesture { location in
                        // Note: In a real implementation, we'd convert tap to coordinate
                    }
                    .overlay(alignment: .bottom) {
                        if selectedCoordinate == nil {
                            Text("Tap to place marker or use current location")
                                .font(.caption)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding(8)
                        }
                    }

                    Button {
                        if let location = locationManager.location {
                            selectedCoordinate = location.coordinate
                            cameraPosition = .region(MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                            ))
                        }
                    } label: {
                        Label("Use Current Location", systemImage: "location.fill")
                    }

                    TextField("Location Name (e.g., City Hall Steps)", text: $locationName)
                } header: {
                    Text("Location")
                } footer: {
                    if selectedCoordinate != nil {
                        Text("Location set")
                    }
                }

                // Location Privacy
                Section {
                    Picker("Visibility", selection: $locationVisibility) {
                        ForEach(LocationVisibility.allCases, id: \.self) { visibility in
                            Text(visibility.displayName).tag(visibility)
                        }
                    }

                    if locationVisibility == .timed {
                        Stepper("Reveal \(revealHoursBefore) hour\(revealHoursBefore == 1 ? "" : "s") before", value: $revealHoursBefore, in: 1...24)
                    }

                    if locationVisibility != .public {
                        TextField("General Area (e.g., Downtown Oakland)", text: $locationArea)
                    }
                } header: {
                    Text("Location Privacy")
                } footer: {
                    Text(locationVisibility.description)
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(eventsService.isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createEvent() }
                    }
                    .disabled(!isValid || eventsService.isCreating)
                }
            }
            .interactiveDismissDisabled(eventsService.isCreating)
            .onAppear {
                locationManager.requestPermission()
                // Set initial camera to do something useful here
                if let location = locationManager.location {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func createEvent() async {
        guard let coordinate = selectedCoordinate else { return }

        var revealAt: Date? = nil
        if locationVisibility == .timed {
            revealAt = startsAt.addingTimeInterval(TimeInterval(-revealHoursBefore * 3600))
        }

        let success = await eventsService.createEvent(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.isEmpty ? nil : description,
            eventType: eventType,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            locationName: locationName.isEmpty ? nil : locationName,
            locationArea: locationArea.isEmpty ? nil : locationArea,
            locationVisibility: locationVisibility,
            locationRevealAt: revealAt,
            startsAt: startsAt,
            endsAt: hasEndTime ? endsAt : nil
        )

        if success {
            dismiss()
        } else if let error = eventsService.error {
            errorMessage = error
            showError = true
        } else {
            errorMessage = "Failed to create event. Please try again."
            showError = true
        }
    }
}

struct AlertsView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var alertsService = AlertsService.shared
    @State private var showSOSSheet = false
    @State private var showLockedAlert = false
    @State private var selectedAlert: Alert?
    @State private var showAlertDetail = false
    @State private var selectedTab: AlertTab = .nearby

    enum AlertTab: String, CaseIterable {
        case nearby = "Nearby"
        case all = "All Active"
        case myAlerts = "My Alerts"
    }

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
            VStack(spacing: 0) {
                // SOS Button at top - always visible
                SOSButtonSection(
                    canSendSOS: canSendSOS,
                    onTap: {
                        if canSendSOS {
                            showSOSSheet = true
                        } else {
                            showLockedAlert = true
                        }
                    }
                )

                // Tab picker
                Picker("View", selection: $selectedTab) {
                    ForEach(AlertTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Content based on selected tab
                switch selectedTab {
                case .nearby:
                    NearbyAlertsListView(
                        alerts: alertsService.nearbyAlerts,
                        isLoading: alertsService.isLoading,
                        onSelectAlert: { alert in
                            selectedAlert = alert
                            showAlertDetail = true
                        }
                    )
                case .all:
                    AlertsListView(
                        alerts: alertsService.alerts,
                        isLoading: alertsService.isLoading,
                        onSelectAlert: { alert in
                            selectedAlert = alert
                            showAlertDetail = true
                        }
                    )
                case .myAlerts:
                    MyAlertsListView(
                        alerts: alertsService.alerts.filter { $0.authorId == authService.currentUser?.id },
                        isLoading: alertsService.isLoading,
                        onSelectAlert: { alert in
                            selectedAlert = alert
                            showAlertDetail = true
                        }
                    )
                }
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await alertsService.fetchAlerts(refresh: true)
                            await alertsService.fetchNearbyAlertsFromCurrentLocation()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSOSSheet) {
                SendSOSView()
            }
            .sheet(isPresented: $showAlertDetail) {
                if let alert = selectedAlert {
                    AlertDetailView(alert: alert)
                }
            }
            .alert("SOS Alerts Locked", isPresented: $showLockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("SOS alerts require a trust score of 100 or verified status to prevent misuse. Get \(trustNeeded) more point\(trustNeeded == 1 ? "" : "s") by receiving vouches from trusted members.")
            }
            .task {
                await alertsService.fetchAlerts()
                await alertsService.fetchNearbyAlertsFromCurrentLocation()
            }
        }
    }
}

// MARK: - SOS Button Section

struct SOSButtonSection: View {
    let canSendSOS: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(canSendSOS ? Color.red.opacity(0.15) : Color.gray.opacity(0.1))
                            .frame(width: 80, height: 80)

                        Image(systemName: canSendSOS ? "exclamationmark.triangle.fill" : "lock.fill")
                            .font(.system(size: 36))
                            .foregroundColor(canSendSOS ? .red : .gray)
                    }

                    Text(canSendSOS ? "Send SOS Alert" : "SOS Locked")
                        .font(.headline)
                        .foregroundColor(canSendSOS ? .red : .gray)

                    if !canSendSOS {
                        Text("Requires trust score of 100 or verified status")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Alert nearby trusted members")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 16)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Alerts List Views

struct AlertsListView: View {
    let alerts: [Alert]
    let isLoading: Bool
    let onSelectAlert: (Alert) -> Void

    var body: some View {
        Group {
            if alerts.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Active Alerts",
                    systemImage: "checkmark.shield",
                    description: Text("There are no active SOS alerts at this time")
                )
            } else {
                List {
                    ForEach(alerts) { alert in
                        AlertRowView(alert: alert)
                            .onTapGesture {
                                onSelectAlert(alert)
                            }
                    }

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct NearbyAlertsListView: View {
    let alerts: [Alert]
    let isLoading: Bool
    let onSelectAlert: (Alert) -> Void

    var body: some View {
        Group {
            if alerts.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Alerts Nearby",
                    systemImage: "location.slash",
                    description: Text("There are no active SOS alerts in your area. Enable location access to see nearby alerts.")
                )
            } else {
                List {
                    ForEach(alerts) { alert in
                        AlertRowView(alert: alert, showDistance: true)
                            .onTapGesture {
                                onSelectAlert(alert)
                            }
                    }

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct MyAlertsListView: View {
    let alerts: [Alert]
    let isLoading: Bool
    let onSelectAlert: (Alert) -> Void

    var body: some View {
        Group {
            if alerts.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Alerts Created",
                    systemImage: "bell.slash",
                    description: Text("You haven't created any SOS alerts")
                )
            } else {
                List {
                    ForEach(alerts) { alert in
                        AlertRowView(alert: alert, isOwned: true)
                            .onTapGesture {
                                onSelectAlert(alert)
                            }
                    }

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Alert Row View

struct AlertRowView: View {
    let alert: Alert
    var showDistance: Bool = false
    var isOwned: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Severity indicator
            severityIcon
                .frame(width: 44, height: 44)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(alert.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    if alert.status != .active {
                        statusBadge
                    }
                }

                if let description = alert.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    // Location
                    if let locationName = alert.locationName {
                        Label(locationName, systemImage: "mappin")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // Distance
                    if showDistance, let distance = alert.distanceMeters {
                        Text(formatDistance(distance))
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Spacer()

                    // Response count
                    if let count = alert.responseCount, count > 0 {
                        Label("\(count)", systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Time
                    Text(alert.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var severityIcon: some View {
        ZStack {
            Circle()
                .fill(severityColor.opacity(0.15))

            Image(systemName: severityIconName)
                .font(.system(size: 20))
                .foregroundColor(severityColor)
        }
    }

    private var severityColor: Color {
        switch alert.severity {
        case 1: return .yellow
        case 2: return .orange
        case 3: return .red
        default: return .gray
        }
    }

    private var severityIconName: String {
        switch alert.severity {
        case 1: return "info.circle.fill"
        case 2: return "exclamationmark.circle.fill"
        case 3: return "exclamationmark.triangle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch alert.status {
        case .resolved:
            Text("Resolved")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.2))
                .foregroundColor(.green)
                .cornerRadius(4)
        case .falseAlarm:
            Text("False Alarm")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.gray)
                .cornerRadius(4)
        case .active:
            EmptyView()
        }
    }

    private func formatDistance(_ meters: Int) -> String {
        if meters < 1000 {
            return "\(meters)m away"
        } else {
            let km = Double(meters) / 1000.0
            return String(format: "%.1fkm away", km)
        }
    }
}

// MARK: - Alert Detail View

struct AlertDetailView: View {
    let alert: Alert
    @Environment(\.dismiss) var dismiss
    @StateObject private var alertsService = AlertsService.shared
    @EnvironmentObject var authService: AuthService
    @State private var showRespondSheet = false
    @State private var showStatusSheet = false
    @State private var refreshedAlert: Alert?

    private var displayAlert: Alert {
        refreshedAlert ?? alert
    }

    private var isAuthor: Bool {
        displayAlert.authorId == authService.currentUser?.id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header with severity
                    alertHeader

                    Divider()

                    // Description
                    if let description = displayAlert.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Details")
                                .font(.headline)
                            Text(description)
                                .font(.body)
                        }

                        Divider()
                    }

                    // Location section
                    locationSection

                    Divider()

                    // Response actions (if not author and alert is active)
                    if !isAuthor && displayAlert.status == .active {
                        responseSection
                        Divider()
                    }

                    // Author controls (if author)
                    if isAuthor && displayAlert.status == .active {
                        authorControlsSection
                        Divider()
                    }

                    // Responses list
                    responsesSection
                }
                .padding()
            }
            .navigationTitle("Alert Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showRespondSheet) {
                RespondToAlertSheet(alertId: displayAlert.id) {
                    await refreshAlert()
                }
            }
            .sheet(isPresented: $showStatusSheet) {
                UpdateAlertStatusSheet(alert: displayAlert) {
                    await refreshAlert()
                }
            }
            .task {
                await refreshAlert()
            }
        }
    }

    private var alertHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Severity badge
                HStack(spacing: 6) {
                    Image(systemName: severityIconName)
                    Text(displayAlert.severityDisplayName)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(severityColor)
                .cornerRadius(8)

                Spacer()

                // Status badge
                if displayAlert.status != .active {
                    Text(displayAlert.status == .resolved ? "Resolved" : "False Alarm")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(displayAlert.status == .resolved ? .green : .gray)
                }
            }

            Text(displayAlert.title)
                .font(.title2.weight(.bold))

            HStack {
                Image(systemName: "clock")
                Text(displayAlert.createdAt, style: .relative)
                Text("ago")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Location")
                .font(.headline)

            if let locationName = displayAlert.locationName {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.red)
                    Text(locationName)
                }
            }

            // Mini map
            Map(initialPosition: .region(MKCoordinateRegion(
                center: displayAlert.location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Marker(displayAlert.title, coordinate: displayAlert.location.coordinate)
                    .tint(.red)
            }
            .frame(height: 150)
            .cornerRadius(12)
            .disabled(true)

            // Broadcast radius info
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text("Broadcast radius: \(formatRadius(displayAlert.radiusMeters))")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Respond")
                .font(.headline)

            if let userResponse = displayAlert.userResponse {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("You responded: \(userResponse.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)")
                }
                .font(.subheadline)
            } else {
                Text("Let them know you're coming to help")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    showRespondSheet = true
                } label: {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                        Text("I Can Help")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }

    private var authorControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Alert")
                .font(.headline)

            Button {
                showStatusSheet = true
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle")
                    Text("Update Status")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var responsesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Responses")
                    .font(.headline)
                Spacer()
                Text("\(displayAlert.responseCount ?? displayAlert.responses?.count ?? 0)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let responses = displayAlert.responses, !responses.isEmpty {
                ForEach(responses) { response in
                    ResponseRowView(response: response)
                }
            } else {
                Text("No responses yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private var severityColor: Color {
        switch displayAlert.severity {
        case 1: return .yellow
        case 2: return .orange
        case 3: return .red
        default: return .gray
        }
    }

    private var severityIconName: String {
        switch displayAlert.severity {
        case 1: return "info.circle.fill"
        case 2: return "exclamationmark.circle.fill"
        case 3: return "exclamationmark.triangle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private func formatRadius(_ meters: Int) -> String {
        if meters < 1000 {
            return "\(meters)m"
        } else {
            let km = Double(meters) / 1000.0
            return String(format: "%.1fkm", km)
        }
    }

    private func refreshAlert() async {
        if let updated = await alertsService.getAlert(id: alert.id) {
            refreshedAlert = updated
        }
    }
}

// MARK: - Response Row View

struct ResponseRowView: View {
    let response: AlertResponse

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: response.statusIcon)
                .font(.title3)
                .foregroundColor(statusColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(response.statusDisplayName)
                    .font(.subheadline.weight(.medium))

                if let eta = response.etaMinutes {
                    Text("ETA: \(eta) min")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(response.createdAt, style: .relative)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch response.status {
        case .acknowledged: return .blue
        case .enRoute: return .orange
        case .arrived: return .green
        case .unable: return .gray
        }
    }
}

// MARK: - Respond to Alert Sheet

struct RespondToAlertSheet: View {
    let alertId: String
    let onComplete: () async -> Void
    @Environment(\.dismiss) var dismiss
    @StateObject private var alertsService = AlertsService.shared
    @State private var selectedStatus: AlertResponseStatus = .acknowledged
    @State private var etaMinutes: Int = 10
    @State private var includeETA: Bool = false
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text("Respond to Alert")
                            .font(.title3.weight(.semibold))
                        Text("Let them know you're coming to help")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }

                Section("Your Response") {
                    Picker("Status", selection: $selectedStatus) {
                        Label("Acknowledged", systemImage: "checkmark.circle")
                            .tag(AlertResponseStatus.acknowledged)
                        Label("On my way", systemImage: "figure.walk")
                            .tag(AlertResponseStatus.enRoute)
                        Label("Unable to help", systemImage: "xmark.circle")
                            .tag(AlertResponseStatus.unable)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if selectedStatus == .enRoute {
                    Section("Estimated Time of Arrival") {
                        Toggle("Include ETA", isOn: $includeETA)

                        if includeETA {
                            Stepper("\(etaMinutes) minutes", value: $etaMinutes, in: 1...120, step: 5)
                        }
                    }
                }

                Section {
                    Text("Your current location may be shared to help coordinate the response.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Respond")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            await submitResponse()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private func submitResponse() async {
        isSubmitting = true

        let eta = (selectedStatus == .enRoute && includeETA) ? etaMinutes : nil
        let success = await alertsService.respondToAlertWithLocation(
            alertId: alertId,
            status: selectedStatus,
            etaMinutes: eta
        )

        if success {
            await onComplete()
            dismiss()
        }

        isSubmitting = false
    }
}

// MARK: - Update Alert Status Sheet

struct UpdateAlertStatusSheet: View {
    let alert: Alert
    let onComplete: () async -> Void
    @Environment(\.dismiss) var dismiss
    @StateObject private var alertsService = AlertsService.shared
    @State private var selectedStatus: AlertStatus = .resolved
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Update Status") {
                    Picker("Status", selection: $selectedStatus) {
                        Label("Mark as Resolved", systemImage: "checkmark.circle.fill")
                            .tag(AlertStatus.resolved)
                        Label("Mark as False Alarm", systemImage: "xmark.circle.fill")
                            .tag(AlertStatus.falseAlarm)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    if selectedStatus == .resolved {
                        Text("This will notify all responders that the situation has been resolved.")
                    } else {
                        Text("This will mark the alert as a false alarm and notify responders.")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .navigationTitle("Update Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") {
                        Task {
                            await updateStatus()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private func updateStatus() async {
        isSubmitting = true

        let success = await alertsService.updateAlertStatus(alertId: alert.id, status: selectedStatus)

        if success {
            await onComplete()
            dismiss()
        }

        isSubmitting = false
    }
}

// MARK: - Send SOS View

struct SendSOSView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var alertsService = AlertsService.shared
    @StateObject private var locationManager = LocationManager()
    @State private var title = ""
    @State private var description = ""
    @State private var severity: Int = 3
    @State private var radiusKm: Double = 5.0
    @State private var isSubmitting = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                // Header
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

                // What's happening
                Section("What's happening?") {
                    TextField("Brief title (required)", text: $title)
                    TextField("Details (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                // Severity
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Severity Level")
                            .font(.subheadline.weight(.medium))

                        Picker("Severity", selection: $severity) {
                            HStack {
                                Image(systemName: "info.circle.fill")
                                Text("Awareness")
                            }.tag(1)
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                Text("Help Needed")
                            }.tag(2)
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Emergency")
                            }.tag(3)
                        }
                        .pickerStyle(.segmented)

                        Text(severityDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Broadcast radius
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Broadcast Radius")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(radiusKm)) km")
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $radiusKm, in: 1...50, step: 1)
                            .tint(.orange)

                        Text("Alert will be sent to trusted members within \(Int(radiusKm)) km of your location")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Location
                Section("Your Location") {
                    if let location = locationManager.location {
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text("Location acquired")
                                    .font(.subheadline)
                                Text("\(location.coordinate.latitude, specifier: "%.4f"), \(location.coordinate.longitude, specifier: "%.4f")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Getting your location...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
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
                        Task {
                            await sendAlert()
                        }
                    }
                    .foregroundColor(.red)
                    .fontWeight(.bold)
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                locationManager.requestPermission()
            }
        }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        locationManager.location != nil
    }

    private var severityDescription: String {
        switch severity {
        case 1: return "General awareness - no immediate danger"
        case 2: return "Help needed - assistance required"
        case 3: return "Emergency - immediate help required"
        default: return ""
        }
    }

    private func sendAlert() async {
        guard let location = locationManager.location else {
            errorMessage = "Unable to get your location"
            showError = true
            return
        }

        isSubmitting = true

        let response = await alertsService.createAlert(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.isEmpty ? nil : description,
            severity: severity,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            locationName: nil,
            radiusMeters: Int(radiusKm * 1000)
        )

        if response != nil {
            dismiss()
        } else if let error = alertsService.error {
            errorMessage = error
            showError = true
        }

        isSubmitting = false
    }
}

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showPanicConfirmation = false
    @State private var showRecoveryKey = false
    @State private var navigationPath = NavigationPath()

    enum SettingsDestination: Hashable {
        case invites
        case vouches
        case userSearch
        case topics
        case locations
        case quietHours
        case appLock
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section("Account") {
                    if let user = authService.currentUser {
                        TrustScoreRow(trustScore: user.trustScore)
                        LabeledContent("Status", value: user.isVerified ? "Verified" : "Unverified")
                    }
                }

                Section("Community") {
                    NavigationLink(value: SettingsDestination.invites) {
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

                    NavigationLink(value: SettingsDestination.vouches) {
                        HStack {
                            Image(systemName: "person.badge.shield.checkmark")
                                .foregroundColor(.orange)
                            Text("Vouches")
                        }
                    }

                    NavigationLink(value: SettingsDestination.userSearch) {
                        HStack {
                            Image(systemName: "magnifyingglass.circle")
                                .foregroundColor(.orange)
                            Text("Find Users")
                        }
                    }
                }

                Section("Subscriptions") {
                    NavigationLink(value: SettingsDestination.topics) {
                        Text("Topics")
                    }
                    NavigationLink(value: SettingsDestination.locations) {
                        Text("Locations")
                    }
                }

                Section("Notifications") {
                    NavigationLink(value: SettingsDestination.quietHours) {
                        Text("Quiet Hours")
                    }
                }

                Section("Security") {
                    NavigationLink(value: SettingsDestination.appLock) {
                        HStack {
                            Image(systemName: "lock.shield")
                                .foregroundColor(.orange)
                            Text("App Lock & Duress PIN")
                            Spacer()
                            if AppLockService.shared.isAppLockEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }

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
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .invites:
                    InvitesView()
                case .vouches:
                    VouchesView()
                case .userSearch:
                    UserSearchView()
                case .topics:
                    TopicSubscriptionsView()
                case .locations:
                    LocationSubscriptionsView()
                case .quietHours:
                    QuietHoursView()
                case .appLock:
                    AppLockSettingsView()
                }
            }
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

// MARK: - Vouches View

struct VouchesView: View {
    @StateObject private var settingsService = SettingsService.shared
    @EnvironmentObject var authService: AuthService

    var body: some View {
        List {
            Section {
                if let user = authService.currentUser {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Trust Score")
                            .font(.headline)
                        HStack {
                            Text("\(user.trustScore)")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text("Each vouch adds +10 points")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if user.trustScore < 30 {
                                    Text("Need 30 to vouch for others")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            Section("Vouches Received (\(settingsService.vouchesReceived.count))") {
                if settingsService.isLoadingVouches {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if settingsService.vouchesReceived.isEmpty {
                    Text("No vouches received yet")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(settingsService.vouchesReceived) { vouch in
                        VouchRow(userId: vouch.userId, date: vouch.createdAt, direction: .received)
                    }
                }
            }

            Section("Vouches Given (\(settingsService.vouchesGiven.count))") {
                if settingsService.vouchesGiven.isEmpty && !settingsService.isLoadingVouches {
                    Text("You haven't vouched for anyone yet")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(settingsService.vouchesGiven) { vouch in
                        VouchRow(userId: vouch.userId, date: vouch.createdAt, direction: .given)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How Vouching Works")
                        .font(.headline)
                    Text("Vouching is how trust spreads in Kuurier. When you vouch for someone, you're saying you trust them. Each vouch increases their trust score by 10 points.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("You need a trust score of 30 to vouch for others.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Vouches")
        .refreshable {
            await settingsService.fetchVouches()
        }
        .task {
            await settingsService.fetchVouches()
        }
    }
}

struct VouchRow: View {
    let userId: String
    let date: Date
    let direction: VouchDirection

    enum VouchDirection {
        case received
        case given

        var icon: String {
            switch self {
            case .received: return "arrow.down.circle.fill"
            case .given: return "arrow.up.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .received: return .green
            case .given: return .blue
            }
        }
    }

    var body: some View {
        NavigationLink(destination: UserProfileView(userId: userId)) {
            HStack {
                Image(systemName: direction.icon)
                    .foregroundColor(direction.color)

                VStack(alignment: .leading) {
                    Text(userId.prefix(8) + "...")
                        .font(.system(.body, design: .monospaced))
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(direction == .received ? "+10" : "")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.green)
            }
        }
    }
}

// MARK: - Topic Subscriptions View

struct TopicSubscriptionsView: View {
    @StateObject private var settingsService = SettingsService.shared
    @State private var showAddSubscription = false

    var topicSubscriptions: [Subscription] {
        settingsService.subscriptions.filter { $0.topic != nil }
    }

    var body: some View {
        List {
            Section {
                ForEach(topicSubscriptions) { subscription in
                    SubscriptionRow(subscription: subscription)
                }
                .onDelete(perform: deleteSubscriptions)

                if topicSubscriptions.isEmpty && !settingsService.isLoadingSubscriptions {
                    Text("No topic subscriptions")
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            Section {
                Button(action: { showAddSubscription = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.orange)
                        Text("Add Topic Subscription")
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Topic Subscriptions")
                        .font(.headline)
                    Text("Subscribe to topics you care about to get notified when new posts are created. You can set the minimum urgency level and how often you want to receive updates.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Topics")
        .refreshable {
            await settingsService.fetchSubscriptions()
            await settingsService.fetchTopics()
        }
        .task {
            await settingsService.fetchSubscriptions()
            await settingsService.fetchTopics()
        }
        .sheet(isPresented: $showAddSubscription) {
            AddTopicSubscriptionView(settingsService: settingsService)
        }
    }

    private func deleteSubscriptions(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let subscription = topicSubscriptions[index]
                await settingsService.deleteSubscription(id: subscription.id)
            }
        }
    }
}

struct SubscriptionRow: View {
    let subscription: Subscription

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let topic = subscription.topic {
                    if let icon = topic.icon {
                        Text(icon)
                    }
                    Text(topic.name)
                        .fontWeight(.medium)
                } else if subscription.location != nil {
                    Image(systemName: "location.fill")
                        .foregroundColor(.blue)
                    Text("Location: \(subscription.radiusMeters ?? 0)m radius")
                        .fontWeight(.medium)
                }

                Spacer()

                if !subscription.isActive {
                    Text("Paused")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(4)
                }
            }

            HStack {
                Label("Urgency \(subscription.minUrgency)+", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(subscription.digestMode.rawValue.capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddTopicSubscriptionView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var settingsService: SettingsService
    @State private var selectedTopic: Topic?
    @State private var minUrgency = 1
    @State private var digestMode: DigestMode = .realtime
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Select Topic") {
                    if settingsService.topics.isEmpty {
                        Text("Loading topics...")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(settingsService.topics) { topic in
                            Button(action: { selectedTopic = topic }) {
                                HStack {
                                    if let icon = topic.icon {
                                        Text(icon)
                                    }
                                    Text(topic.name)
                                    Spacer()
                                    if selectedTopic?.id == topic.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                Section("Minimum Urgency") {
                    Picker("Urgency Level", selection: $minUrgency) {
                        Text("All (1+)").tag(1)
                        Text("Medium (2+)").tag(2)
                        Text("High Only (3)").tag(3)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notification Frequency") {
                    Picker("Digest Mode", selection: $digestMode) {
                        Text("Real-time").tag(DigestMode.realtime)
                        Text("Daily").tag(DigestMode.daily)
                        Text("Weekly").tag(DigestMode.weekly)
                    }
                }
            }
            .navigationTitle("Add Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            let success = await settingsService.createSubscription(
                                topicId: selectedTopic?.id,
                                location: nil,
                                radiusMeters: nil,
                                minUrgency: minUrgency,
                                digestMode: digestMode
                            )
                            isSaving = false
                            if success {
                                dismiss()
                            }
                        }
                    }
                    .disabled(selectedTopic == nil || isSaving)
                }
            }
        }
    }
}

// MARK: - Location Subscriptions View

struct LocationSubscriptionsView: View {
    @StateObject private var settingsService = SettingsService.shared
    @State private var showAddLocation = false

    var locationSubscriptions: [Subscription] {
        settingsService.subscriptions.filter { $0.location != nil }
    }

    var body: some View {
        List {
            Section {
                ForEach(locationSubscriptions) { subscription in
                    SubscriptionRow(subscription: subscription)
                }
                .onDelete(perform: deleteSubscriptions)

                if locationSubscriptions.isEmpty && !settingsService.isLoadingSubscriptions {
                    Text("No location subscriptions")
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            Section {
                Button(action: { showAddLocation = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.orange)
                        Text("Add Location Subscription")
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Location Subscriptions")
                        .font(.headline)
                    Text("Subscribe to locations to get notified about activity within a specific radius. Great for monitoring activity near your home, workplace, or areas of interest.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Locations")
        .refreshable {
            await settingsService.fetchSubscriptions()
        }
        .task {
            await settingsService.fetchSubscriptions()
        }
        .sheet(isPresented: $showAddLocation) {
            AddLocationSubscriptionView(settingsService: settingsService)
        }
    }

    private func deleteSubscriptions(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let subscription = locationSubscriptions[index]
                await settingsService.deleteSubscription(id: subscription.id)
            }
        }
    }
}

struct AddLocationSubscriptionView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var settingsService: SettingsService
    @State private var radiusKm = 5.0
    @State private var minUrgency = 1
    @State private var digestMode: DigestMode = .realtime
    @State private var isSaving = false
    @State private var useCurrentLocation = true
    @State private var manualLatitude = ""
    @State private var manualLongitude = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    Toggle("Use Current Location", isOn: $useCurrentLocation)

                    if !useCurrentLocation {
                        TextField("Latitude", text: $manualLatitude)
                            .keyboardType(.decimalPad)
                        TextField("Longitude", text: $manualLongitude)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Radius") {
                    VStack(alignment: .leading) {
                        Text("Radius: \(Int(radiusKm)) km")
                        Slider(value: $radiusKm, in: 1...50, step: 1)
                    }
                }

                Section("Minimum Urgency") {
                    Picker("Urgency Level", selection: $minUrgency) {
                        Text("All (1+)").tag(1)
                        Text("Medium (2+)").tag(2)
                        Text("High Only (3)").tag(3)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notification Frequency") {
                    Picker("Digest Mode", selection: $digestMode) {
                        Text("Real-time").tag(DigestMode.realtime)
                        Text("Daily").tag(DigestMode.daily)
                        Text("Weekly").tag(DigestMode.weekly)
                    }
                }
            }
            .navigationTitle("Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            // For now, use placeholder coordinates (in a real app, get from location manager)
                            let location: Location?
                            if useCurrentLocation {
                                // Use a default location for now
                                location = Location(latitude: 40.7128, longitude: -74.0060)
                            } else if let lat = Double(manualLatitude), let lng = Double(manualLongitude) {
                                location = Location(latitude: lat, longitude: lng)
                            } else {
                                location = nil
                            }

                            let success = await settingsService.createSubscription(
                                topicId: nil,
                                location: location,
                                radiusMeters: Int(radiusKm * 1000),
                                minUrgency: minUrgency,
                                digestMode: digestMode
                            )
                            isSaving = false
                            if success {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

// MARK: - Quiet Hours View

struct QuietHoursView: View {
    @StateObject private var settingsService = SettingsService.shared
    @State private var isActive = false
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var allowEmergency = true
    @State private var isSaving = false
    @State private var hasChanges = false

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                Toggle("Enable Quiet Hours", isOn: $isActive)
                    .onChange(of: isActive) { _, _ in hasChanges = true }
            }

            if isActive {
                Section("Schedule") {
                    DatePicker("Start Time", selection: $startTime, displayedComponents: .hourAndMinute)
                        .onChange(of: startTime) { _, _ in hasChanges = true }

                    DatePicker("End Time", selection: $endTime, displayedComponents: .hourAndMinute)
                        .onChange(of: endTime) { _, _ in hasChanges = true }
                }

                Section("Exceptions") {
                    Toggle("Allow Emergency Alerts", isOn: $allowEmergency)
                        .onChange(of: allowEmergency) { _, _ in hasChanges = true }

                    Text("Emergency alerts (SOS) will still come through during quiet hours")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Quiet Hours")
                        .font(.headline)
                    Text("During quiet hours, you won't receive push notifications except for emergency alerts (if enabled). Messages will still be delivered and visible when you open the app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            if hasChanges {
                Section {
                    Button(action: saveQuietHours) {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save Changes")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSaving)
                }
            }

            if settingsService.quietHours?.configured == true {
                Section {
                    Button(role: .destructive, action: deleteQuietHours) {
                        HStack {
                            Spacer()
                            Text("Delete Quiet Hours")
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle("Quiet Hours")
        .task {
            await settingsService.fetchQuietHours()
            loadFromSettings()
        }
    }

    private func loadFromSettings() {
        guard let qh = settingsService.quietHours else { return }

        isActive = qh.isActive
        allowEmergency = qh.allowEmergency

        // Parse time strings
        if let start = timeFormatter.date(from: qh.startTime) {
            startTime = start
        }
        if let end = timeFormatter.date(from: qh.endTime) {
            endTime = end
        }

        hasChanges = false
    }

    private func saveQuietHours() {
        Task {
            isSaving = true
            let timezone = TimeZone.current.identifier
            let success = await settingsService.saveQuietHours(
                startTime: timeFormatter.string(from: startTime),
                endTime: timeFormatter.string(from: endTime),
                timezone: timezone,
                allowEmergency: allowEmergency,
                isActive: isActive
            )
            isSaving = false
            if success {
                hasChanges = false
            }
        }
    }

    private func deleteQuietHours() {
        Task {
            let success = await settingsService.deleteQuietHours()
            if success {
                isActive = false
                hasChanges = false
            }
        }
    }
}

// MARK: - User Search View

struct UserSearchView: View {
    @StateObject private var settingsService = SettingsService.shared
    @State private var searchText = ""
    @State private var searchResults: [UserProfile] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    var body: some View {
        List {
            if !hasSearched {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Search for Users")
                            .font(.headline)
                        Text("Enter at least 3 characters of a user's ID to search. User IDs are anonymous identifiers like \"a1b2c3d4-...\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if isSearching {
                HStack {
                    Spacer()
                    ProgressView("Searching...")
                    Spacer()
                }
            } else if hasSearched {
                if searchResults.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Users Found",
                            systemImage: "person.slash",
                            description: Text("No users match \"\(searchText)\". Try a different search.")
                        )
                    }
                } else {
                    Section("Results (\(searchResults.count))") {
                        ForEach(searchResults) { user in
                            NavigationLink(destination: UserProfileView(userId: user.id)) {
                                UserSearchResultRow(user: user)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Find Users")
        .searchable(text: $searchText, prompt: "Search by user ID...")
        .onSubmit(of: .search) {
            Task {
                await performSearch()
            }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                hasSearched = false
                searchResults = []
            }
        }
    }

    private func performSearch() async {
        guard searchText.count >= 3 else { return }

        isSearching = true
        searchResults = await settingsService.searchUsers(query: searchText)
        hasSearched = true
        isSearching = false
    }
}

struct UserSearchResultRow: View {
    let user: UserProfile

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: 44, height: 44)
                Text(String(user.id.prefix(2)).uppercased())
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(user.id.prefix(12) + "...")
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)

                    if user.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }

                HStack(spacing: 8) {
                    Label("\(user.trustScore)", systemImage: "shield.fill")
                        .font(.caption)
                        .foregroundColor(trustColor(for: user.trustScore))

                    Label("\(user.vouchCount)", systemImage: "person.badge.shield.checkmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if user.hasVouched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else if user.canVouch {
                Image(systemName: "hand.thumbsup")
                    .foregroundColor(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func trustColor(for score: Int) -> Color {
        if score >= 100 {
            return .green
        } else if score >= 50 {
            return .blue
        } else if score >= 30 {
            return .orange
        } else {
            return .secondary
        }
    }
}

// MARK: - User Profile View

struct UserProfileView: View {
    let userId: String
    @StateObject private var settingsService = SettingsService.shared
    @EnvironmentObject var authService: AuthService
    @State private var profile: UserProfile?
    @State private var isLoading = true
    @State private var isVouching = false
    @State private var showVouchSuccess = false

    private var isOwnProfile: Bool {
        authService.currentUser?.id == userId
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading profile...")
            } else if let profile = profile {
                profileContent(profile)
            } else {
                ContentUnavailableView(
                    "User Not Found",
                    systemImage: "person.slash",
                    description: Text("This user doesn't exist or has been deleted.")
                )
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProfile()
        }
        .alert("Vouched!", isPresented: $showVouchSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You've successfully vouched for this user. Their trust score has increased by 10 points.")
        }
    }

    @ViewBuilder
    private func profileContent(_ profile: UserProfile) -> some View {
        List {
            // User ID Section
            Section {
                VStack(alignment: .center, spacing: 16) {
                    // Avatar placeholder
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.2))
                            .frame(width: 80, height: 80)
                        Text(String(userId.prefix(2)).uppercased())
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }

                    // User ID (truncated)
                    Text(userId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if profile.isVerified {
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // Trust Score Section
            Section("Trust") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Trust Score")
                            .font(.headline)
                        Text("Based on vouches received")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(profile.trustScore)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(trustColor(for: profile.trustScore))
                }

                HStack {
                    Label("\(profile.vouchCount) vouches received", systemImage: "person.badge.shield.checkmark")
                    Spacer()
                    Text("+\(profile.vouchCount * 10) points")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Member Since
            Section("Account") {
                LabeledContent("Member Since") {
                    Text(profile.createdAt, style: .date)
                }
            }

            // Vouch Action
            if !isOwnProfile {
                Section {
                    if profile.hasVouched {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("You've vouched for this user")
                                .foregroundColor(.secondary)
                        }
                    } else if profile.canVouch {
                        Button(action: vouchForUser) {
                            HStack {
                                Spacer()
                                if isVouching {
                                    ProgressView()
                                } else {
                                    Image(systemName: "hand.thumbsup.fill")
                                    Text("Vouch for this User")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .foregroundColor(.white)
                        .listRowBackground(Color.orange)
                        .disabled(isVouching)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.secondary)
                                Text("Cannot vouch yet")
                                    .foregroundColor(.secondary)
                            }
                            Text("You need a trust score of 30 to vouch for others.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Trust Level Explanation
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trust Levels")
                        .font(.headline)
                    TrustLevelRow(level: 15, label: "View feed", icon: "newspaper", currentScore: profile.trustScore)
                    TrustLevelRow(level: 25, label: "Create posts", icon: "square.and.pencil", currentScore: profile.trustScore)
                    TrustLevelRow(level: 30, label: "Generate invites", icon: "envelope.badge.person.crop", currentScore: profile.trustScore)
                    TrustLevelRow(level: 50, label: "Create events", icon: "calendar.badge.plus", currentScore: profile.trustScore)
                    TrustLevelRow(level: 100, label: "Send SOS alerts", icon: "exclamationmark.triangle", currentScore: profile.trustScore)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func trustColor(for score: Int) -> Color {
        if score >= 100 {
            return .green
        } else if score >= 50 {
            return .blue
        } else if score >= 30 {
            return .orange
        } else {
            return .secondary
        }
    }

    private func loadProfile() async {
        isLoading = true
        profile = await settingsService.fetchUserProfile(userId: userId)
        isLoading = false
    }

    private func vouchForUser() {
        Task {
            isVouching = true
            let success = await settingsService.vouchForUser(userId: userId)
            if success {
                showVouchSuccess = true
                await loadProfile()
            }
            isVouching = false
        }
    }
}

// MARK: - App Lock Settings View

struct AppLockSettingsView: View {
    @StateObject private var appLockService = AppLockService.shared
    @State private var showSetupPIN = false
    @State private var showChangePIN = false
    @State private var showSetupDuress = false
    @State private var showDisableConfirm = false
    @State private var disablePIN = ""
    @State private var showDisableError = false

    var body: some View {
        List {
            // App Lock Status Section
            Section {
                if appLockService.isAppLockEnabled {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                        Text("App Lock Enabled")
                            .foregroundColor(.green)
                    }
                } else {
                    HStack {
                        Image(systemName: "lock.open")
                            .foregroundColor(.secondary)
                        Text("App Lock Disabled")
                            .foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("App Lock requires a PIN to access the app after it's been closed or backgrounded.")
            }

            // Setup/Manage PIN Section
            Section("PIN Settings") {
                if !appLockService.isAppLockEnabled {
                    Button {
                        showSetupPIN = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.orange)
                            Text("Set Up App Lock PIN")
                        }
                    }
                } else {
                    Button {
                        showChangePIN = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Change PIN")
                        }
                    }

                    Button(role: .destructive) {
                        showDisableConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "lock.open")
                            Text("Disable App Lock")
                        }
                    }
                }
            }

            // Biometric Section
            if appLockService.isAppLockEnabled && appLockService.canUseBiometrics {
                Section {
                    Toggle(isOn: Binding(
                        get: { appLockService.isBiometricEnabled },
                        set: { appLockService.setBiometricEnabled($0) }
                    )) {
                        HStack {
                            Image(systemName: biometricIcon)
                            Text("Use \(appLockService.biometricTypeName)")
                        }
                    }
                } header: {
                    Text("Biometric Unlock")
                } footer: {
                    Text("Unlock the app quickly using \(appLockService.biometricTypeName) instead of entering your PIN.")
                }
            }

            // Auto Lock Timeout Section
            if appLockService.isAppLockEnabled {
                Section {
                    Picker("Lock After", selection: Binding(
                        get: { appLockService.autoLockTimeout },
                        set: { appLockService.setAutoLockTimeout($0) }
                    )) {
                        ForEach(AppLockService.AutoLockTimeout.allCases, id: \.self) { timeout in
                            Text(timeout.displayName).tag(timeout)
                        }
                    }
                } header: {
                    Text("Auto Lock")
                } footer: {
                    Text("How long the app can be in the background before requiring PIN entry.")
                }
            }

            // Duress PIN Section
            if appLockService.isAppLockEnabled {
                Section {
                    if appLockService.isDuressPINSet {
                        HStack {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.red)
                            Text("Duress PIN Active")
                                .foregroundColor(.red)
                        }

                        Button(role: .destructive) {
                            showSetupDuress = true
                        } label: {
                            Text("Change Duress PIN")
                        }
                    } else {
                        Button {
                            showSetupDuress = true
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.shield")
                                    .foregroundColor(.red)
                                Text("Set Up Duress PIN")
                            }
                        }
                    }
                } header: {
                    Text("Duress PIN")
                } footer: {
                    Text("A duress PIN is a secondary PIN that, when entered, silently wipes all app data. Use this if you're being forced to unlock your phone. The app will appear as if you've never used it.")
                }
            }

            // Manual Lock Section
            if appLockService.isAppLockEnabled {
                Section {
                    Button {
                        appLockService.lockApp()
                    } label: {
                        HStack {
                            Image(systemName: "lock.fill")
                            Text("Lock App Now")
                        }
                    }
                }
            }
        }
        .navigationTitle("App Lock")
        .sheet(isPresented: $showSetupPIN) {
            PINSetupView(mode: .setup)
        }
        .sheet(isPresented: $showChangePIN) {
            PINSetupView(mode: .change)
        }
        .sheet(isPresented: $showSetupDuress) {
            PINSetupView(mode: .duress)
        }
        .alert("Disable App Lock", isPresented: $showDisableConfirm) {
            SecureField("Enter PIN", text: $disablePIN)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {
                disablePIN = ""
            }
            Button("Disable", role: .destructive) {
                if appLockService.disableAppLock(currentPIN: disablePIN) {
                    disablePIN = ""
                } else {
                    disablePIN = ""
                    showDisableError = true
                }
            }
        } message: {
            Text("Enter your current PIN to disable App Lock.")
        }
        .alert("Incorrect PIN", isPresented: $showDisableError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The PIN you entered is incorrect.")
        }
    }

    private var biometricIcon: String {
        switch appLockService.biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "faceid"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
}
