import SwiftUI
import CoreLocation
import Combine

/// View for creating a new post
struct CreatePostView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var feedService = FeedService.shared
    @StateObject private var locationManager = LocationManager()

    @State private var content = ""
    @State private var sourceType: SourceType = .firsthand
    @State private var urgency = 1
    @State private var includeLocation = false
    @State private var locationName = ""
    @State private var isSubmitting = false
    @State private var error: String?

    private let maxCharacters = 500

    var body: some View {
        NavigationStack {
            Form {
                // Content
                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("What's happening?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack {
                        Spacer()
                        Text("\(content.count)/\(maxCharacters)")
                            .font(.caption)
                            .foregroundStyle(content.count > maxCharacters ? .red : .secondary)
                    }
                } header: {
                    Text("Content")
                }

                // Source Type
                Section {
                    Picker("Source Type", selection: $sourceType) {
                        Label("Firsthand", systemImage: "eye.fill")
                            .tag(SourceType.firsthand)
                        Label("Aggregated", systemImage: "square.stack.fill")
                            .tag(SourceType.aggregated)
                        Label("News", systemImage: "newspaper.fill")
                            .tag(SourceType.mainstream)
                    }
                } header: {
                    Text("Source")
                } footer: {
                    Text(sourceTypeDescription)
                }

                // Urgency
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("Urgency: \(urgency)", value: $urgency, in: 1...5)

                        HStack(spacing: 4) {
                            ForEach(1...5, id: \.self) { level in
                                Circle()
                                    .fill(level <= urgency ? urgencyColor : Color.gray.opacity(0.3))
                                    .frame(width: 12, height: 12)
                            }
                            Spacer()
                            Text(urgencyLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Urgency Level")
                }

                // Location
                Section {
                    Toggle("Include Location", isOn: $includeLocation)

                    if includeLocation {
                        TextField("Location name (optional)", text: $locationName)

                        if let location = locationManager.currentLocation {
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.green)
                                Text(String(format: "%.4f, %.4f", location.latitude, location.longitude))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Get Current Location") {
                                locationManager.requestLocation()
                            }
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    if includeLocation {
                        Text("Location helps others nearby see relevant posts.")
                    }
                }

                // Error
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        Task { await submitPost() }
                    }
                    .disabled(!canSubmit)
                    .fontWeight(.semibold)
                }
            }
            .disabled(isSubmitting)
            .overlay {
                if isSubmitting {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                    ProgressView("Posting...")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var canSubmit: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        content.count <= maxCharacters &&
        !isSubmitting
    }

    private var sourceTypeDescription: String {
        switch sourceType {
        case .firsthand: return "You witnessed this directly"
        case .aggregated: return "Compiled from multiple sources"
        case .mainstream: return "From news or media outlets"
        }
    }

    private var urgencyColor: Color {
        switch urgency {
        case 1: return .green
        case 2: return .yellow
        case 3: return .orange
        case 4...5: return .red
        default: return .gray
        }
    }

    private var urgencyLabel: String {
        switch urgency {
        case 1: return "Low"
        case 2: return "Moderate"
        case 3: return "High"
        case 4: return "Urgent"
        case 5: return "Critical"
        default: return ""
        }
    }

    // MARK: - Actions

    private func submitPost() async {
        isSubmitting = true
        error = nil

        do {
            let lat = includeLocation ? locationManager.currentLocation?.latitude : nil
            let lon = includeLocation ? locationManager.currentLocation?.longitude : nil
            let locName = includeLocation && !locationName.isEmpty ? locationName : nil

            try await feedService.createPost(
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceType: sourceType,
                latitude: lat,
                longitude: lon,
                locationName: locName,
                urgency: urgency
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }

        isSubmitting = false
    }
}

// MARK: - Location Manager

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    func requestLocation() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            currentLocation = locations.first?.coordinate
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Handle error silently for now
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}

#Preview {
    CreatePostView()
}
