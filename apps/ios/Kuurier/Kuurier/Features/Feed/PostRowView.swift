import SwiftUI

/// Displays a single post in the feed
struct PostRowView: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Source type badge + time
            HStack {
                sourceTypeBadge
                Spacer()
                Text(post.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Content
            Text(post.content)
                .font(.body)

            // Location (if available)
            if let locationName = post.locationName {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption)
                    Text(locationName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            // Footer: Urgency + Verification
            HStack {
                urgencyIndicator

                Spacer()

                // Verification score
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption)
                    Text("\(post.verificationScore)")
                        .font(.caption)
                }
                .foregroundStyle(verificationColor)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    // MARK: - Components

    private var sourceTypeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: sourceTypeIcon)
                .font(.caption)
            Text(sourceTypeLabel)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(sourceTypeColor.opacity(0.15))
        .foregroundStyle(sourceTypeColor)
        .clipShape(Capsule())
    }

    private var urgencyIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(post.urgency, 5), id: \.self) { _ in
                Circle()
                    .fill(urgencyColor)
                    .frame(width: 6, height: 6)
            }
            ForEach(0..<max(0, 5 - post.urgency), id: \.self) { _ in
                Circle()
                    .stroke(urgencyColor.opacity(0.3), lineWidth: 1)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Computed Properties

    private var sourceTypeIcon: String {
        switch post.sourceType {
        case .firsthand: return "eye.fill"
        case .aggregated: return "square.stack.fill"
        case .mainstream: return "newspaper.fill"
        }
    }

    private var sourceTypeLabel: String {
        switch post.sourceType {
        case .firsthand: return "Firsthand"
        case .aggregated: return "Aggregated"
        case .mainstream: return "News"
        }
    }

    private var sourceTypeColor: Color {
        switch post.sourceType {
        case .firsthand: return .green
        case .aggregated: return .blue
        case .mainstream: return .orange
        }
    }

    private var urgencyColor: Color {
        switch post.urgency {
        case 1: return .green
        case 2: return .yellow
        case 3: return .orange
        case 4...5: return .red
        default: return .gray
        }
    }

    private var verificationColor: Color {
        switch post.verificationScore {
        case 80...100: return .green
        case 50..<80: return .yellow
        default: return .gray
        }
    }
}

#Preview {
    PostRowView(post: Post(
        id: "1",
        authorId: "user1",
        content: "Large crowd gathering at City Hall for the climate march. Peaceful so far, police presence is minimal. #ClimateAction",
        sourceType: .firsthand,
        location: Location(latitude: 40.7128, longitude: -74.0060),
        locationName: "City Hall, New York",
        urgency: 2,
        createdAt: Date().addingTimeInterval(-3600),
        verificationScore: 85
    ))
    .padding()
    .background(Color(.systemGroupedBackground))
}
