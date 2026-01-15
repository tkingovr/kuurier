import SwiftUI
import Combine

/// Main chat view displaying messages in a conversation
struct ConversationView: View {
    let channel: Channel?
    let channelId: String

    @StateObject private var viewModel: ConversationViewModel
    @StateObject private var wsService = WebSocketService.shared
    @State private var messageText = ""
    @State private var isLoadingMore = false
    @State private var typingTimer: Timer?
    @FocusState private var isInputFocused: Bool

    init(channel: Channel) {
        self.channel = channel
        self.channelId = channel.id
        _viewModel = StateObject(wrappedValue: ConversationViewModel(channel: channel))
    }

    /// Initialize with just a channel ID (for event channels)
    init(channelId: String) {
        self.channel = nil
        self.channelId = channelId
        _viewModel = StateObject(wrappedValue: ConversationViewModel(channelId: channelId))
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
                        if !wsService.typingUsersIn(channelId: channelId).isEmpty {
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
                        wsService.stopTyping(in: channelId)
                        await viewModel.sendMessage(messageText)
                        messageText = ""
                    }
                }
            )
            .onChange(of: messageText) { _, newValue in
                handleTyping(newValue)
            }
        }
        .navigationTitle(viewModel.channel?.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(viewModel.channel?.displayName ?? "Chat")
                            .font(.headline)
                        // Online indicator for DMs
                        if let channel = viewModel.channel,
                           channel.type == .dm,
                           let otherUserId = channel.otherUserId,
                           wsService.isOnline(userId: otherUserId) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                        }
                    }
                    if let channel = viewModel.channel, channel.type != .dm {
                        Text("\(channel.memberCount) members")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .task {
            await viewModel.loadChannelIfNeeded()
            await viewModel.loadMessages()
            viewModel.setupWebSocket(for: channelId)
        }
        .onDisappear {
            wsService.stopTyping(in: channelId)
            wsService.unsubscribe(from: channelId)
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
            wsService.startTyping(in: channelId)

            // Set timer to stop typing after 3 seconds of no input
            typingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                self.wsService.stopTyping(in: self.channelId)
            }
        } else {
            wsService.stopTyping(in: channelId)
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
    @Published var channel: Channel?

    private let channelId: String
    private let api = APIClient.shared
    private let signalService = SignalService.shared
    private let senderKeyService = SenderKeyService.shared
    private let wsService = WebSocketService.shared
    private let pendingStore = PendingMessageStore.shared

    // Map local pending IDs to server message IDs for deduplication
    private var localToServerIds: [String: String] = [:]

    init(channel: Channel) {
        self.channel = channel
        self.channelId = channel.id
    }

    /// Initialize with just a channel ID (for event channels)
    init(channelId: String) {
        self.channelId = channelId
        self.channel = nil
    }

    /// Fetches channel details if not already loaded
    func loadChannelIfNeeded() async {
        guard channel == nil else { return }

        do {
            let fetchedChannel: Channel = try await api.get("/channels/\(channelId)")
            self.channel = fetchedChannel
        } catch {
            self.error = "Failed to load channel"
        }
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

        // Don't add if already in messages (server ID match)
        if messages.contains(where: { $0.id == message.id }) {
            return
        }

        // Check if this is our own message that we sent (local-first pattern)
        let currentUserId = SecureStorage.shared.userID
        if message.senderId == currentUserId {
            // Check if we have a pending message for this
            if pendingStore.isPendingMessage(serverMessageId: message.id, channelId: channelId) {
                return  // Already handled by sendMessage
            }

            // Check if we have any pending messages (we might be waiting for confirmation)
            let pendingMessages = pendingStore.getMessages(for: channelId)
            if !pendingMessages.isEmpty {
                // Check if any pending message matches by content and approximate time
                // This handles the case where WebSocket arrives before POST response
                for pending in pendingMessages where pending.status == .sending {
                    // If message was created within 30 seconds, it's likely our pending message
                    let timeDiff = abs(message.createdAt.timeIntervalSince(pending.createdAt))
                    if timeDiff < 30 {
                        // Update our local tracking
                        pendingStore.markSent(messageId: pending.id, channelId: channelId, serverMessageId: message.id)
                        localToServerIds[pending.id] = message.id

                        // Replace local message with server message
                        if let index = messages.firstIndex(where: { $0.id == pending.id }) {
                            var confirmedMessage = message
                            confirmedMessage.decryptedContent = pending.content
                            messages[index] = confirmedMessage
                        }
                        return
                    }
                }
            }
        }

        // This is a message from someone else - decrypt and add
        var decryptedMessage = message
        decryptedMessage.decryptedContent = await decryptMessage(message)
        messages.append(decryptedMessage)
    }

    func loadMessages() async {
        isLoading = true
        error = nil

        do {
            // For group channels, fetch sender keys before loading messages
            if channel?.type != .dm {
                try await senderKeyService.fetchSenderKeys(for: channelId)
            }

            let response: MessagesResponse = try await api.get("/messages/\(channelId)")
            // Messages come newest first, reverse for display
            var serverMessages = response.messages.reversed().map { $0 }

            // Create a map of already-decrypted messages to avoid re-decryption
            let existingDecrypted: [String: String] = Dictionary(
                messages.compactMap { msg -> (String, String)? in
                    guard let content = msg.decryptedContent else { return nil }
                    return (msg.id, content)
                },
                uniquingKeysWith: { first, _ in first }
            )

            // Decrypt only new messages, reuse existing decrypted content
            for i in 0..<serverMessages.count {
                if let existingContent = existingDecrypted[serverMessages[i].id] {
                    serverMessages[i].decryptedContent = existingContent
                } else {
                    serverMessages[i].decryptedContent = await decryptMessage(serverMessages[i])
                }
            }

            // Get IDs of messages from server (including mapped local IDs)
            let serverMessageIds = Set(serverMessages.map { $0.id })

            // Get pending messages from local storage (Signal pattern)
            let pendingMessages = pendingStore.getMessages(for: channelId)

            // Convert pending messages to Message objects for display
            let pendingToDisplay: [Message] = pendingMessages.compactMap { pending in
                // Skip if this message is already on server (by checking localToServerIds)
                if let serverId = localToServerIds[pending.id], serverMessageIds.contains(serverId) {
                    return nil
                }
                // Skip if somehow the pending ID is on server
                if serverMessageIds.contains(pending.id) {
                    return nil
                }

                return Message(
                    id: pending.id,
                    channelId: channelId,
                    senderId: SecureStorage.shared.userID ?? "",
                    ciphertext: Data(),
                    messageType: .text,
                    replyToId: nil,
                    createdAt: pending.createdAt,
                    editedAt: nil,
                    decryptedContent: pending.content
                )
            }

            // Merge: server messages + pending messages (sorted by date)
            var allMessages = serverMessages + pendingToDisplay
            allMessages.sort { $0.createdAt < $1.createdAt }
            messages = allMessages

            hasMoreMessages = response.messages.count >= 50
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func loadMoreMessages() async {
        // Find oldest non-pending message to use as cursor
        let pendingIds = Set(pendingStore.getMessages(for: channelId).map { $0.id })
        let nonPendingMessages = messages.filter { !pendingIds.contains($0.id) }
        guard let oldestMessage = nonPendingMessages.first, hasMoreMessages else { return }

        do {
            let beforeDate = ISO8601DateFormatter().string(from: oldestMessage.createdAt)
            let response: MessagesResponse = try await api.get(
                "/messages/\(channelId)",
                queryItems: [URLQueryItem(name: "before", value: beforeDate)]
            )

            var decryptedMessages = response.messages.reversed().map { $0 }
            for i in 0..<decryptedMessages.count {
                decryptedMessages[i].decryptedContent = await decryptMessage(decryptedMessages[i])
            }

            // Remove any duplicates that might exist
            let existingIds = Set(messages.map { $0.id })
            let newMessages = decryptedMessages.filter { !existingIds.contains($0.id) }

            messages.insert(contentsOf: newMessages, at: 0)
            hasMoreMessages = response.messages.count >= 50
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sendMessage(_ content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // STEP 1: Save to local storage FIRST (Signal pattern)
        // This ensures the message survives any race conditions
        let pendingMessage = pendingStore.saveMessage(channelId: channelId, content: content)

        // STEP 2: Add to UI immediately from local storage
        let localMessage = Message(
            id: pendingMessage.id,
            channelId: channelId,
            senderId: SecureStorage.shared.userID ?? "",
            ciphertext: Data(),
            messageType: .text,
            replyToId: nil,
            createdAt: pendingMessage.createdAt,
            editedAt: nil,
            decryptedContent: content
        )
        messages.append(localMessage)

        // STEP 3: Send asynchronously (don't block UI)
        pendingStore.markSending(messageId: pendingMessage.id, channelId: channelId)

        do {
            // Encrypt the message
            let ciphertext = try await encryptMessage(content)

            // Send to server
            let request = SendMessageRequest(
                channelId: channelId,
                ciphertext: ciphertext,
                messageType: "text",
                replyToId: nil
            )

            let serverMessage: Message = try await api.post("/messages", body: request)

            // STEP 4: Update local storage with server ID
            pendingStore.markSent(messageId: pendingMessage.id, channelId: channelId, serverMessageId: serverMessage.id)
            localToServerIds[pendingMessage.id] = serverMessage.id

            // Update the message in UI with server details (keep same position)
            if let index = messages.firstIndex(where: { $0.id == pendingMessage.id }) {
                var confirmedMessage = serverMessage
                confirmedMessage.decryptedContent = content
                messages[index] = confirmedMessage
            }

            // Mark channel as read
            await MessagingService.shared.markChannelRead(channelId)
        } catch {
            // Mark as failed but keep in UI (user can retry)
            pendingStore.markFailed(messageId: pendingMessage.id, channelId: channelId, error: error.localizedDescription)
            self.error = "Failed to send message: \(error.localizedDescription)"
        }
    }

    private func encryptMessage(_ content: String) async throws -> Data {
        guard let contentData = content.data(using: .utf8) else {
            throw MessagingError.encryptionFailed
        }

        if let channel = channel, channel.type == .dm, let otherUserId = channel.otherUserId {
            // DM: Use Signal Protocol 1:1 encryption
            return try await signalService.encrypt(contentData, for: otherUserId)
        } else {
            // Group: Use Sender Keys for efficient group encryption
            let groupCiphertext = try await senderKeyService.encryptForGroup(contentData, channelId: channelId)
            // Encode the GroupCiphertext as JSON for transport
            return try JSONEncoder().encode(groupCiphertext)
        }
    }

    private func decryptMessage(_ message: Message) async -> String? {
        if channel?.type == .dm {
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
                    channelId: channelId
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
