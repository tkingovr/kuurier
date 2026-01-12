import SwiftUI
import Combine

/// Main chat view displaying messages in a conversation
struct ConversationView: View {
    let channel: Channel

    @StateObject private var viewModel: ConversationViewModel
    @StateObject private var wsService = WebSocketService.shared
    @State private var messageText = ""
    @State private var isLoadingMore = false
    @State private var typingTimer: Timer?
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

                        // Typing indicator
                        if !wsService.typingUsersIn(channelId: channel.id).isEmpty {
                            TypingIndicatorView()
                                .padding(.horizontal)
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
                        wsService.stopTyping(in: channel.id)
                        await viewModel.sendMessage(messageText)
                        messageText = ""
                    }
                }
            )
            .onChange(of: messageText) { _, newValue in
                handleTyping(newValue)
            }
        }
        .navigationTitle(channel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(channel.displayName)
                            .font(.headline)
                        // Online indicator for DMs
                        if channel.type == .dm,
                           let otherUserId = channel.otherUserId,
                           wsService.isOnline(userId: otherUserId) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                        }
                    }
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
            viewModel.setupWebSocket(for: channel.id)
        }
        .onDisappear {
            wsService.stopTyping(in: channel.id)
            wsService.unsubscribe(from: channel.id)
        }
        .refreshable {
            await viewModel.loadMessages()
        }
    }

    private func handleTyping(_ text: String) {
        // Cancel previous timer
        typingTimer?.invalidate()

        if !text.isEmpty {
            // Send typing start
            wsService.startTyping(in: channel.id)

            // Set timer to stop typing after 3 seconds of no input
            typingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                wsService.stopTyping(in: channel.id)
            }
        } else {
            wsService.stopTyping(in: channel.id)
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
    private let senderKeyService = SenderKeyService.shared
    private let wsService = WebSocketService.shared

    init(channel: Channel) {
        self.channel = channel
    }

    /// Sets up WebSocket for real-time updates
    func setupWebSocket(for channelId: String) {
        // Connect if not connected
        if !wsService.isConnected {
            wsService.connect()
        }

        // Subscribe to channel
        wsService.subscribe(to: channelId)

        // Handle incoming messages
        wsService.onMessageReceived = { [weak self] wsMessage in
            guard let self = self,
                  wsMessage.channelId == channelId else { return }

            Task { @MainActor in
                await self.handleIncomingMessage(wsMessage)
            }
        }
    }

    /// Handles incoming WebSocket messages
    private func handleIncomingMessage(_ wsMessage: WebSocketMessage) async {
        guard wsMessage.type == "message.new",
              let payload = wsMessage.payload else { return }

        // Decode the message from payload
        guard let message = try? JSONDecoder().decode(Message.self, from: payload) else {
            return
        }

        // Don't add if it's our own message (already added optimistically)
        if message.senderId == SecureStorage.shared.userID {
            return
        }

        // Decrypt and add to messages
        var decryptedMessage = message
        decryptedMessage.decryptedContent = await decryptMessage(message)
        messages.append(decryptedMessage)
    }

    func loadMessages() async {
        isLoading = true
        error = nil

        do {
            // For group channels, fetch sender keys before loading messages
            if channel.type != .dm {
                try await senderKeyService.fetchSenderKeys(for: channel.id)
            }

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
            // Group: Use Sender Keys for efficient group encryption
            let groupCiphertext = try await senderKeyService.encryptForGroup(contentData, channelId: channel.id)
            // Encode the GroupCiphertext as JSON for transport
            return try JSONEncoder().encode(groupCiphertext)
        }
    }

    private func decryptMessage(_ message: Message) async -> String? {
        if channel.type == .dm {
            // DM: Use Signal Protocol decryption
            if let decrypted = try? await signalService.decrypt(message.ciphertext, from: message.senderId) {
                return String(data: decrypted, encoding: .utf8)
            }
        } else {
            // Group: Decode GroupCiphertext and decrypt with Sender Keys
            do {
                let groupCiphertext = try JSONDecoder().decode(GroupCiphertext.self, from: message.ciphertext)
                let decrypted = try await senderKeyService.decryptFromGroup(
                    groupCiphertext,
                    from: message.senderId,
                    channelId: channel.id
                )
                return String(data: decrypted, encoding: .utf8)
            } catch {
                print("Group decryption failed: \(error)")
                return "[Unable to decrypt]"
            }
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
