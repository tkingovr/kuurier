import SwiftUI
import Combine

/// Main chat view displaying messages in a conversation
struct ConversationView: View {
    let channel: Channel

    @StateObject private var viewModel: ConversationViewModel
    @State private var messageText = ""
    @State private var isLoadingMore = false
    @FocusState private var isInputFocused: Bool

    init(channel: Channel) {
        self.channel = channel
        _viewModel = StateObject(wrappedValue: ConversationViewModel(channel: channel))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Load more indicator
                        if viewModel.hasMoreMessages {
                            Button(action: { Task { await viewModel.loadMoreMessages() } }) {
                                if isLoadingMore {
                                    ProgressView()
                                        .padding()
                                } else {
                                    Text("Load earlier messages")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .padding()
                                }
                            }
                        }

                        // Messages
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(
                                message: message,
                                isFromCurrentUser: message.senderId == SecureStorage.shared.userID
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    // Scroll to bottom on new message
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Scroll to bottom initially
                    if let lastMessage = viewModel.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Message input
            ComposeMessageView(
                text: $messageText,
                isFocused: $isInputFocused,
                onSend: {
                    Task {
                        await viewModel.sendMessage(messageText)
                        messageText = ""
                    }
                }
            )
        }
        .navigationTitle(channel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(channel.displayName)
                        .font(.headline)
                    if channel.type != .dm {
                        Text("\(channel.memberCount) members")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .task {
            await viewModel.loadMessages()
        }
        .refreshable {
            await viewModel.loadMessages()
        }
    }
}

/// ViewModel for ConversationView
@MainActor
final class ConversationViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasMoreMessages = true

    private let channel: Channel
    private let api = APIClient.shared
    private let signalService = SignalService.shared

    init(channel: Channel) {
        self.channel = channel
    }

    func loadMessages() async {
        isLoading = true
        error = nil

        do {
            let response: MessagesResponse = try await api.get("/messages/\(channel.id)")
            // Messages come newest first, reverse for display
            var decryptedMessages = response.messages.reversed().map { $0 }

            // Decrypt messages
            for i in 0..<decryptedMessages.count {
                decryptedMessages[i].decryptedContent = await decryptMessage(decryptedMessages[i])
            }

            messages = decryptedMessages
            hasMoreMessages = response.messages.count >= 50
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func loadMoreMessages() async {
        guard let oldestMessage = messages.first, hasMoreMessages else { return }

        do {
            let beforeDate = ISO8601DateFormatter().string(from: oldestMessage.createdAt)
            let response: MessagesResponse = try await api.get(
                "/messages/\(channel.id)",
                queryItems: [URLQueryItem(name: "before", value: beforeDate)]
            )

            var decryptedMessages = response.messages.reversed().map { $0 }
            for i in 0..<decryptedMessages.count {
                decryptedMessages[i].decryptedContent = await decryptMessage(decryptedMessages[i])
            }

            messages.insert(contentsOf: decryptedMessages, at: 0)
            hasMoreMessages = response.messages.count >= 50
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sendMessage(_ content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            // Encrypt the message
            let ciphertext = try await encryptMessage(content)

            // Send to server
            let request = SendMessageRequest(
                channelId: channel.id,
                ciphertext: ciphertext,
                messageType: "text",
                replyToId: nil
            )

            let message: Message = try await api.post("/messages", body: request)

            // Add to local messages with decrypted content
            var decryptedMessage = message
            decryptedMessage.decryptedContent = content
            messages.append(decryptedMessage)

            // Mark channel as read
            await MessagingService.shared.markChannelRead(channel.id)
        } catch {
            self.error = "Failed to send message: \(error.localizedDescription)"
        }
    }

    private func encryptMessage(_ content: String) async throws -> Data {
        guard let contentData = content.data(using: .utf8) else {
            throw MessagingError.encryptionFailed
        }

        if channel.type == .dm, let otherUserId = channel.otherUserId {
            // DM: Use Signal Protocol 1:1 encryption
            return try await signalService.encrypt(contentData, for: otherUserId)
        } else {
            // Group: For now, use simple encoding (Phase 5 will add Sender Keys)
            // TODO: Implement group encryption with Sender Keys
            return contentData
        }
    }

    private func decryptMessage(_ message: Message) async -> String? {
        if channel.type == .dm {
            // DM: Use Signal Protocol decryption
            if let decrypted = try? await signalService.decrypt(message.ciphertext, from: message.senderId) {
                return String(data: decrypted, encoding: .utf8)
            }
        } else {
            // Group: Simple decoding for now
            return String(data: message.ciphertext, encoding: .utf8)
        }
        return "[Unable to decrypt]"
    }
}

enum MessagingError: Error {
    case encryptionFailed
    case decryptionFailed
}

// SendMessageRequest is defined in MessagingModels.swift

#Preview {
    NavigationStack {
        ConversationView(channel: Channel(
            id: "test",
            orgId: nil,
            name: "Test Channel",
            description: nil,
            type: .dm,
            eventId: nil,
            createdBy: "user1",
            createdAt: Date(),
            memberCount: 2,
            unreadCount: 0,
            lastActivity: Date(),
            otherUserId: "user2"
        ))
    }
}
