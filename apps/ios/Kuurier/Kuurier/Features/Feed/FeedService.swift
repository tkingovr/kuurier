import Foundation
import Combine

/// Service for feed-related API operations
@MainActor
final class FeedService: ObservableObject {

    static let shared = FeedService()

    @Published var posts: [Post] = []
    @Published var topics: [Topic] = []
    @Published var isLoading = false
    @Published var error: String?

    private let api = APIClient.shared

    private init() {}

    // MARK: - Feed

    /// Fetches the personalized feed
    func fetchFeed(limit: Int = 50, offset: Int = 0) async {
        isLoading = true
        error = nil

        do {
            let queryItems = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            let response: FeedResponse = try await api.get("/feed", queryItems: queryItems)

            if offset == 0 {
                posts = response.posts
            } else {
                posts.append(contentsOf: response.posts)
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Refreshes the feed (pull-to-refresh)
    func refresh() async {
        await fetchFeed(limit: 50, offset: 0)
    }

    /// Loads more posts (infinite scroll)
    func loadMore() async {
        guard !isLoading else { return }
        await fetchFeed(limit: 50, offset: posts.count)
    }

    // MARK: - Posts

    /// Creates a new post
    func createPost(
        content: String,
        sourceType: SourceType = .firsthand,
        topicIds: [String] = [],
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        urgency: Int = 1
    ) async throws {
        let body = CreatePostRequest(
            content: content,
            sourceType: sourceType.rawValue,
            topicIds: topicIds.isEmpty ? nil : topicIds,
            latitude: latitude,
            longitude: longitude,
            locationName: locationName,
            urgency: urgency
        )

        let _: Post = try await api.post("/feed/posts", body: body)

        // Refresh feed to show new post
        await refresh()
    }

    // MARK: - Topics

    /// Fetches available topics
    func fetchTopics() async {
        do {
            let response: TopicsResponse = try await api.get("/topics")
            topics = response.topics
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Request Types

private struct CreatePostRequest: Encodable {
    let content: String
    let sourceType: String
    let topicIds: [String]?
    let latitude: Double?
    let longitude: Double?
    let locationName: String?
    let urgency: Int
}
