import Foundation
import Combine

/// Represents a message that's pending send to the server
/// Stored locally first, then sent asynchronously (Signal pattern)
struct PendingMessage: Codable, Identifiable {
    let id: String  // Local UUID, replaced with server ID after send
    let channelId: String
    let content: String
    let createdAt: Date
    var status: PendingMessageStatus
    var serverMessageId: String?  // Set after successful send
    var errorMessage: String?
    var retryCount: Int

    enum PendingMessageStatus: String, Codable {
        case pending    // Waiting to be sent
        case sending    // Currently being sent
        case sent       // Successfully sent to server
        case failed     // Failed to send
    }

    init(channelId: String, content: String) {
        self.id = UUID().uuidString
        self.channelId = channelId
        self.content = content
        self.createdAt = Date()
        self.status = .pending
        self.serverMessageId = nil
        self.errorMessage = nil
        self.retryCount = 0
    }
}

/// Local storage for pending messages
/// Messages are saved here FIRST before any network calls (Signal pattern)
/// This ensures messages survive app crashes, race conditions, and network issues
final class PendingMessageStore: ObservableObject {

    static let shared = PendingMessageStore()

    @Published private(set) var pendingMessages: [String: [PendingMessage]] = [:]  // channelId -> messages

    private let storageKey = "com.kuurier.pendingMessages"
    private let userDefaults = UserDefaults.standard

    private init() {
        loadFromStorage()
    }

    // MARK: - Public API

    /// Saves a new pending message locally (call BEFORE any network operations)
    func saveMessage(channelId: String, content: String) -> PendingMessage {
        let message = PendingMessage(channelId: channelId, content: content)

        if pendingMessages[channelId] == nil {
            pendingMessages[channelId] = []
        }
        pendingMessages[channelId]?.append(message)

        persistToStorage()
        return message
    }

    /// Gets all pending messages for a channel
    func getMessages(for channelId: String) -> [PendingMessage] {
        return pendingMessages[channelId] ?? []
    }

    /// Updates a message's status to sending
    func markSending(messageId: String, channelId: String) {
        updateMessage(messageId: messageId, channelId: channelId) { message in
            message.status = .sending
        }
    }

    /// Marks a message as successfully sent
    func markSent(messageId: String, channelId: String, serverMessageId: String) {
        updateMessage(messageId: messageId, channelId: channelId) { message in
            message.status = .sent
            message.serverMessageId = serverMessageId
        }

        // Remove sent messages after a short delay (keep for deduplication)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.removeMessage(messageId: messageId, channelId: channelId)
        }
    }

    /// Marks a message as failed
    func markFailed(messageId: String, channelId: String, error: String) {
        updateMessage(messageId: messageId, channelId: channelId) { message in
            message.status = .failed
            message.errorMessage = error
            message.retryCount += 1
        }
    }

    /// Removes a pending message (after successful send or user dismissal)
    func removeMessage(messageId: String, channelId: String) {
        pendingMessages[channelId]?.removeAll { $0.id == messageId }
        if pendingMessages[channelId]?.isEmpty == true {
            pendingMessages.removeValue(forKey: channelId)
        }
        persistToStorage()
    }

    /// Removes all pending messages for a channel
    func clearChannel(channelId: String) {
        pendingMessages.removeValue(forKey: channelId)
        persistToStorage()
    }

    /// Checks if a server message ID corresponds to a pending message we sent
    func isPendingMessage(serverMessageId: String, channelId: String) -> Bool {
        return pendingMessages[channelId]?.contains { $0.serverMessageId == serverMessageId } ?? false
    }

    /// Gets the local message ID for a server message ID
    func getLocalMessageId(for serverMessageId: String, channelId: String) -> String? {
        return pendingMessages[channelId]?.first { $0.serverMessageId == serverMessageId }?.id
    }

    /// Gets pending messages that need to be retried
    func getFailedMessages(for channelId: String) -> [PendingMessage] {
        return pendingMessages[channelId]?.filter { $0.status == .failed } ?? []
    }

    // MARK: - Private Helpers

    private func updateMessage(messageId: String, channelId: String, update: (inout PendingMessage) -> Void) {
        guard let index = pendingMessages[channelId]?.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        update(&pendingMessages[channelId]![index])
        persistToStorage()
    }

    private func persistToStorage() {
        do {
            let data = try JSONEncoder().encode(pendingMessages)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            print("Failed to persist pending messages: \(error)")
        }
    }

    private func loadFromStorage() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }

        do {
            pendingMessages = try JSONDecoder().decode([String: [PendingMessage]].self, from: data)
        } catch {
            print("Failed to load pending messages: \(error)")
            pendingMessages = [:]
        }
    }
}
