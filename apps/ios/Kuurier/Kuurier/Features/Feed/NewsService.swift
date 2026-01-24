import Foundation
import Combine

/// Service for fetching news articles from external sources
final class NewsService: ObservableObject {

    static let shared = NewsService()

    @Published var articles: [NewsArticle] = []
    @Published var isLoading = false
    @Published var error: String?

    private let api = APIClient.shared
    private var lastFetchTime: Date?
    private let cacheInterval: TimeInterval = 5 * 60 // 5 minutes

    private init() {}

    // MARK: - Fetch News

    /// Fetches news articles
    @MainActor
    func fetchNews(forceRefresh: Bool = false) async {
        // Use cached data if recent enough and not forcing refresh
        if !forceRefresh,
           let lastFetch = lastFetchTime,
           Date().timeIntervalSince(lastFetch) < cacheInterval,
           !articles.isEmpty {
            return
        }

        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            let response: NewsResponse = try await api.get("/news")
            articles = response.articles
            lastFetchTime = Date()
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    /// Returns articles filtered by category
    func articles(for category: String) -> [NewsArticle] {
        articles.filter { $0.category == category }
    }

    /// Returns articles that have location data (for map display)
    var articlesWithLocation: [NewsArticle] {
        articles.filter { $0.location != nil }
    }
}
