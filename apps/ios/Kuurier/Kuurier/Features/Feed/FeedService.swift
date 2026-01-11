import Foundation
import Combine

/// Service for fetching and managing feed posts
final class FeedService: ObservableObject {

    static let shared = FeedService()

    @Published var posts: [Post] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isCreatingPost = false
    @Published var error: String?
    @Published var hasMorePosts = true

    private let api = APIClient.shared
    private var currentOffset = 0
    private let pageSize = 30

    private init() {}

    // MARK: - Fetch Feed

    /// Fetches the feed (initial load or refresh)
    @MainActor
    func fetchFeed(refresh: Bool = false) async {
        if refresh {
            currentOffset = 0
            hasMorePosts = true
        }

        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            let response: FeedResponse = try await api.get("/feed", queryItems: [
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "offset", value: "0")
            ])

            posts = response.posts
            currentOffset = response.posts.count
            hasMorePosts = response.posts.count >= pageSize
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    /// Loads more posts for pagination
    @MainActor
    func loadMorePosts() async {
        guard !isLoadingMore && hasMorePosts else { return }

        isLoadingMore = true

        do {
            let response: FeedResponse = try await api.get("/feed", queryItems: [
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "offset", value: String(currentOffset))
            ])

            posts.append(contentsOf: response.posts)
            currentOffset += response.posts.count
            hasMorePosts = response.posts.count >= pageSize
            isLoadingMore = false
        } catch {
            isLoadingMore = false
        }
    }

    // MARK: - Create Post

    /// Creates a new post
    @MainActor
    func createPost(content: String, sourceType: SourceType, location: Location? = nil, locationName: String? = nil, urgency: Int = 1) async -> Bool {
        // Prevent double-submit
        guard !isCreatingPost else {
            print("FeedService: Already creating a post, ignoring duplicate request")
            return false
        }

        isCreatingPost = true
        error = nil

        do {
            let request = CreatePostRequest(
                content: content,
                sourceType: sourceType.rawValue,
                latitude: location?.latitude,
                longitude: location?.longitude,
                locationName: locationName,
                urgency: urgency
            )

            print("FeedService: Creating post with content=\(content.prefix(50))..., sourceType=\(sourceType.rawValue), urgency=\(urgency)")

            let response: CreatePostResponse = try await api.post("/feed/posts", body: request)

            print("FeedService: Post created successfully with id=\(response.id)")

            // Reset creating state before refreshing feed (so fetchFeed isn't blocked)
            isCreatingPost = false

            // Refresh feed to show new post
            await fetchFeed(refresh: true)
            return true
        } catch {
            print("FeedService: Error creating post: \(error)")
            self.error = error.localizedDescription
            isCreatingPost = false
            return false
        }
    }

    // MARK: - Post Actions

    /// Verifies (upvotes) a post
    @MainActor
    func verifyPost(id: String) async -> Bool {
        do {
            let _: MessageResponse = try await api.post("/feed/\(id)/verify", body: EmptyBody())

            // Update local post
            if let index = posts.firstIndex(where: { $0.id == id }) {
                var updatedPost = posts[index]
                // Create a new post with incremented verification score
                posts[index] = Post(
                    id: updatedPost.id,
                    authorId: updatedPost.authorId,
                    content: updatedPost.content,
                    sourceType: updatedPost.sourceType,
                    location: updatedPost.location,
                    locationName: updatedPost.locationName,
                    urgency: updatedPost.urgency,
                    createdAt: updatedPost.createdAt,
                    verificationScore: updatedPost.verificationScore + 1
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// Flags (downvotes) a post
    @MainActor
    func flagPost(id: String) async -> Bool {
        do {
            let _: MessageResponse = try await api.post("/feed/\(id)/flag", body: EmptyBody())

            // Update local post
            if let index = posts.firstIndex(where: { $0.id == id }) {
                var updatedPost = posts[index]
                posts[index] = Post(
                    id: updatedPost.id,
                    authorId: updatedPost.authorId,
                    content: updatedPost.content,
                    sourceType: updatedPost.sourceType,
                    location: updatedPost.location,
                    locationName: updatedPost.locationName,
                    urgency: updatedPost.urgency,
                    createdAt: updatedPost.createdAt,
                    verificationScore: updatedPost.verificationScore - 1
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// Deletes a post (only works for own posts)
    @MainActor
    func deletePost(id: String) async -> Bool {
        do {
            let _: MessageResponse = try await api.delete("/feed/\(id)")
            posts.removeAll { $0.id == id }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Request/Response Types

private struct CreatePostRequest: Encodable {
    let content: String
    let sourceType: String
    let latitude: Double?
    let longitude: Double?
    let locationName: String?
    let urgency: Int

    enum CodingKeys: String, CodingKey {
        case content
        case sourceType = "source_type"
        case latitude
        case longitude
        case locationName = "location_name"
        case urgency
    }
}

private struct CreatePostResponse: Decodable {
    let id: String
    let message: String
    let createdAt: Date
}

private struct EmptyBody: Encodable {}
