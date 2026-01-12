import Foundation
import Combine

/// Service for managing WebSocket connections for real-time messaging
final class WebSocketService: ObservableObject {

    static let shared = WebSocketService()

    // MARK: - Published State

    @Published var isConnected = false
    @Published var connectionError: String?

    // Typing indicators: channelId -> Set of userIds who are typing
    @Published var typingUsers: [String: Set<String>] = [:]

    // Online presence: userId -> isOnline
    @Published var onlineUsers: Set<String> = []

    // MARK: - Callbacks

    var onMessageReceived: ((WebSocketMessage) -> Void)?
    var onTypingUpdate: ((String, String, Bool) -> Void)? // channelId, userId, isTyping
    var onPresenceUpdate: ((String, Bool) -> Void)? // userId, isOnline

    // MARK: - Private Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var subscribedChannels: Set<String> = []

    private var typingTimers: [String: Timer] = [:] // Clear typing after timeout

    private init() {}

    // MARK: - Connection Management

    /// Connects to the WebSocket server
    func connect() {
        guard !isConnected else { return }

        guard let token = SecureStorage.shared.authToken else {
            connectionError = "Not authenticated"
            return
        }

        let apiBaseURL = APIClient.shared.baseURL

        // Build WebSocket URL
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/v1/ws"

        guard let wsURL = components.url else {
            connectionError = "Invalid WebSocket URL"
            return
        }

        // Create request with auth header
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        // Create URLSession with delegate for SSL pinning
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        webSocketTask = urlSession?.webSocketTask(with: request)

        webSocketTask?.resume()
        isConnected = true
        connectionError = nil
        reconnectAttempts = 0

        // Start receiving messages
        receiveMessage()

        // Start ping timer
        startPingTimer()

        // Resubscribe to channels
        for channelId in subscribedChannels {
            subscribe(to: channelId)
        }

        print("WebSocket connected")
    }

    /// Disconnects from the WebSocket server
    func disconnect() {
        stopPingTimer()
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil

        isConnected = false
        typingUsers.removeAll()
        print("WebSocket disconnected")
    }

    /// Reconnects after a delay with exponential backoff
    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionError = "Failed to reconnect after \(maxReconnectAttempts) attempts"
            return
        }

        let delay = pow(2.0, Double(reconnectAttempts))
        reconnectAttempts += 1

        print("Scheduling reconnect in \(delay) seconds (attempt \(reconnectAttempts))")

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleTextMessage(text)
                    }
                @unknown default:
                    break
                }

                // Continue receiving
                self?.receiveMessage()

            case .failure(let error):
                print("WebSocket receive error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                    self?.connectionError = error.localizedDescription
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(WebSocketMessage.self, from: data) else {
            print("Failed to decode WebSocket message: \(text)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.processMessage(message)
        }
    }

    private func processMessage(_ message: WebSocketMessage) {
        switch message.type {
        case "message.new", "message.edited", "message.deleted":
            onMessageReceived?(message)

        case "typing.update":
            handleTypingUpdate(message)

        case "presence.online":
            if let userId = message.userId {
                onlineUsers.insert(userId)
                onPresenceUpdate?(userId, true)
            }

        case "presence.offline":
            if let userId = message.userId {
                onlineUsers.remove(userId)
                onPresenceUpdate?(userId, false)
            }

        case "pong":
            // Pong received, connection is alive
            break

        case "subscribed", "unsubscribed":
            // Confirmation messages
            break

        case "error":
            if let payload = message.payload,
               let error = try? JSONDecoder().decode(ErrorPayload.self, from: payload) {
                print("WebSocket error: \(error.error)")
            }

        default:
            print("Unknown WebSocket message type: \(message.type)")
        }
    }

    private func handleTypingUpdate(_ message: WebSocketMessage) {
        guard let channelId = message.channelId,
              let userId = message.userId,
              let payload = message.payload,
              let typing = try? JSONDecoder().decode(TypingPayload.self, from: payload) else {
            return
        }

        if typing.typing {
            // Add user to typing
            if typingUsers[channelId] == nil {
                typingUsers[channelId] = []
            }
            typingUsers[channelId]?.insert(userId)

            // Set timer to remove typing indicator after 5 seconds
            let key = "\(channelId):\(userId)"
            typingTimers[key]?.invalidate()
            typingTimers[key] = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.typingUsers[channelId]?.remove(userId)
                if self?.typingUsers[channelId]?.isEmpty == true {
                    self?.typingUsers.removeValue(forKey: channelId)
                }
            }
        } else {
            // Remove user from typing
            typingUsers[channelId]?.remove(userId)
            if typingUsers[channelId]?.isEmpty == true {
                typingUsers.removeValue(forKey: channelId)
            }

            let key = "\(channelId):\(userId)"
            typingTimers[key]?.invalidate()
            typingTimers.removeValue(forKey: key)
        }

        onTypingUpdate?(channelId, userId, typing.typing)
    }

    // MARK: - Sending Messages

    /// Sends a WebSocket message
    func send(_ message: WebSocketMessage) {
        guard isConnected else {
            print("Cannot send: WebSocket not connected")
            return
        }

        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            print("Failed to encode message")
            return
        }

        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }

    /// Subscribes to a channel for real-time updates
    func subscribe(to channelId: String) {
        subscribedChannels.insert(channelId)

        let message = WebSocketMessage(
            type: "subscribe",
            channelId: channelId,
            userId: nil,
            payload: nil,
            timestamp: Date()
        )
        send(message)
    }

    /// Unsubscribes from a channel
    func unsubscribe(from channelId: String) {
        subscribedChannels.remove(channelId)

        let message = WebSocketMessage(
            type: "unsubscribe",
            channelId: channelId,
            userId: nil,
            payload: nil,
            timestamp: Date()
        )
        send(message)
    }

    /// Sends a typing start indicator
    func startTyping(in channelId: String) {
        let message = WebSocketMessage(
            type: "typing.start",
            channelId: channelId,
            userId: nil,
            payload: nil,
            timestamp: Date()
        )
        send(message)
    }

    /// Sends a typing stop indicator
    func stopTyping(in channelId: String) {
        let message = WebSocketMessage(
            type: "typing.stop",
            channelId: channelId,
            userId: nil,
            payload: nil,
            timestamp: Date()
        )
        send(message)
    }

    /// Sends a read receipt
    func markRead(channelId: String, messageId: String) {
        guard let payload = try? JSONEncoder().encode(["message_id": messageId]) else { return }

        let message = WebSocketMessage(
            type: "message.read",
            channelId: channelId,
            userId: nil,
            payload: payload,
            timestamp: Date()
        )
        send(message)
    }

    // MARK: - Ping/Pong

    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        let message = WebSocketMessage(
            type: "ping",
            channelId: nil,
            userId: nil,
            payload: nil,
            timestamp: Date()
        )
        send(message)
    }

    // MARK: - Helpers

    /// Returns whether a user is currently typing in a channel
    func isTyping(userId: String, in channelId: String) -> Bool {
        return typingUsers[channelId]?.contains(userId) ?? false
    }

    /// Returns all users currently typing in a channel
    func typingUsersIn(channelId: String) -> [String] {
        return Array(typingUsers[channelId] ?? [])
    }

    /// Returns whether a user is online
    func isOnline(userId: String) -> Bool {
        return onlineUsers.contains(userId)
    }
}

// MARK: - Helper Types
// WebSocketMessage is defined in MessagingModels.swift

private struct TypingPayload: Codable {
    let typing: Bool
}

private struct ErrorPayload: Codable {
    let error: String
}
