import SwiftUI

/// Main feed view showing posts from subscribed topics and locations
struct FeedView: View {
    @StateObject private var feedService = FeedService.shared
    @State private var showingCreatePost = false

    var body: some View {
        NavigationStack {
            Group {
                if feedService.posts.isEmpty && feedService.isLoading {
                    loadingView
                } else if feedService.posts.isEmpty {
                    emptyStateView
                } else {
                    postsList
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCreatePost = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showingCreatePost) {
                CreatePostView()
            }
            .task {
                if feedService.posts.isEmpty {
                    await feedService.fetchFeed()
                }
            }
        }
    }

    // MARK: - Views

    private var postsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(feedService.posts) { post in
                    PostRowView(post: post)
                }

                // Load more trigger
                if !feedService.posts.isEmpty {
                    ProgressView()
                        .padding()
                        .task {
                            await feedService.loadMore()
                        }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .refreshable {
            await feedService.refresh()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading feed...")
                .foregroundStyle(.secondary)
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Posts Yet", systemImage: "doc.text")
        } description: {
            Text("Posts from your subscribed topics and locations will appear here.")
        } actions: {
            Button("Create First Post") {
                showingCreatePost = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    FeedView()
}
