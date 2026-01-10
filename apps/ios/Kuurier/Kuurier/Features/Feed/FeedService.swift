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
        var body: [String: Any] = [
            "content": content,
            "source_type": sourceType.rawValue,
            "urgency": urgency
        ]

        if !topicIds.isEmpty {
            body["topic_ids"] = topicIds
        }

        if let lat = latitude, let lon = longitude {
            body["latitude"] = lat
            body["longitude"] = lon
        }

        if let name = locationName {
            body["location_name"] = name
        }

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
