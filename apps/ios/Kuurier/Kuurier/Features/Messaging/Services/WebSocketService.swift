import Foundation
import Combine
import CryptoKit
import Network
import UIKit

/// Connection state for WebSocket
enum WebSocketConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)
}

// Make comparison nonisolated for use in background queues
extension WebSocketConnectionState {
    nonisolated static func == (lhs: WebSocketConnectionState, rhs: WebSocketConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected):
            return true
        case (.connecting, .connecting):
            return true
        case (.connected, .connected):
            return true
        case (.reconnecting(let a), .reconnecting(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Service for managing WebSocket connections for real-time messaging
final class WebSocketService: ObservableObject {

    static let shared = WebSocketService()

    // MARK: - Published State

    @Published var connectionState: WebSocketConnectionState = .disconnected
    @Published var connectionError: String?

    /// Convenience computed property
    var isConnected: Bool {
        connectionState == .connected
    }

    // Typing indicators: channelId -> Set of userIds who are typing
    @Published var typingUsers: [String: Set<String>] = [:]

    // Online presence: userId -> isOnline
    @Published var onlineUsers: Set<String> = []

    // MARK: - Callbacks

    var onMessageReceived: ((WebSocketMessage) -> Void)?
    var onTypingUpdate: ((String, String, Bool) -> Void)? // channelId, userId, isTyping
    var onPresenceUpdate: ((String, Bool) -> Void)? // userId, isOnline
    var onConnectionStateChanged: ((WebSocketConnectionState) -> Void)?

    // MARK: - Private Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 60.0
    private var subscribedChannels: Set<String> = []
    private var typingTimers: [String: Timer] = [:]
    private var isManuallyDisconnected = false

    // Network monitoring
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.kuurier.networkmonitor")
    private var hasNetworkConnection = true
    private var wasConnectedBeforeNetworkLoss = false

    // App lifecycle
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupNetworkMonitoring()
        setupAppLifecycleObservers()
    }

    deinit {
        networkMonitor.cancel()
        cancellables.removeAll()
    }

    // MARK: - Network Monitoring

    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkChange(path)
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    private func handleNetworkChange(_ path: NWPath) {
        let wasConnected = hasNetworkConnection
        hasNetworkConnection = path.status == .satisfied

        print("Network: \(hasNetworkConnection ? "available" : "unavailable") (was: \(wasConnected))")

        if !wasConnected && hasNetworkConnection {
            // Network restored
            if wasConnectedBeforeNetworkLoss && !isManuallyDisconnected {
                print("Network restored - attempting reconnection")
                reconnectAttempts = 0 // Reset attempts on network restore
                connect()
            }
        } else if wasConnected && !hasNetworkConnection {
            // Network lost
            wasConnectedBeforeNetworkLoss = isConnected
            if isConnected {
                print("Network lost - connection will be restored when network returns")
                updateConnectionState(.reconnecting(attempt: 0))
            }
        }
    }

    // MARK: - App Lifecycle

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.handleAppWillEnterForeground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.disconnect()
            }
            .store(in: &cancellables)
    }

    private func handleAppWillEnterForeground() {
        print("App entering foreground")
        if !isManuallyDisconnected && SecureStorage.shared.isLoggedIn {
            if !isConnected {
                reconnectAttempts = 0
                connect()
            }
        }
    }

    private func handleAppDidEnterBackground() {
        print("App entering background")
        // Keep connection alive for a short time, iOS will handle cleanup
        // For longer background support, would need background task
    }

    // MARK: - Connection Management

    /// Connects to the WebSocket server
    func connect() {
        guard !isManuallyDisconnected else {
            print("WebSocket: Manual disconnect active, not connecting")
            return
        }

        guard connectionState != .connecting && connectionState != .connected else {
            print("WebSocket: Already connecting or connected")
            return
        }

        guard hasNetworkConnection else {
            print("WebSocket: No network connection available")
            updateConnectionState(.failed(reason: "No network connection"))
            return
        }

        guard let token = SecureStorage.shared.authToken else {
            updateConnectionState(.failed(reason: "Not authenticated"))
            return
        }

        updateConnectionState(.connecting)

        let apiBaseURL = APIClient.shared.baseURL

        // Build WebSocket URL
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/v1/ws"

        guard let wsURL = components.url else {
            updateConnectionState(.failed(reason: "Invalid WebSocket URL"))
            return
        }

        // Create request with auth header
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        // Create URLSession with certificate pinning delegate
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let delegate = WebSocketCertificatePinningDelegate()
        urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: request)

        webSocketTask?.resume()

        // Start receiving messages - connection state updated on first successful receive
        receiveMessage()

        // Start ping timer
        startPingTimer()

        print("WebSocket: Connection initiated to \(wsURL)")
    }

    /// Disconnects from the WebSocket server
    func disconnect() {
        isManuallyDisconnected = true
        performDisconnect()
    }

    /// Internal disconnect without setting manual flag
    private func performDisconnect() {
        stopPingTimer()
        cancelReconnect()

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        typingUsers.removeAll()
        updateConnectionState(.disconnected)
        print("WebSocket: Disconnected")
    }

    /// Reconnects (for external use after manual disconnect)
    func reconnect() {
        isManuallyDisconnected = false
        reconnectAttempts = 0
        connect()
    }

    private func updateConnectionState(_ newState: WebSocketConnectionState) {
        guard connectionState != newState else { return }

        DispatchQueue.main.async { [weak self] in
            self?.connectionState = newState
            self?.onConnectionStateChanged?(newState)

            // Update error message
            if case .failed(let reason) = newState {
                self?.connectionError = reason
            } else {
                self?.connectionError = nil
            }
        }
    }

    // MARK: - Reconnection with Exponential Backoff + Jitter

    private func scheduleReconnect() {
        guard !isManuallyDisconnected else { return }
        guard hasNetworkConnection else {
            print("WebSocket: No network, will reconnect when network returns")
            return
        }
        guard reconnectAttempts < maxReconnectAttempts else {
            updateConnectionState(.failed(reason: "Failed to reconnect after \(maxReconnectAttempts) attempts"))
            return
        }

        reconnectAttempts += 1
        updateConnectionState(.reconnecting(attempt: reconnectAttempts))

        // Exponential backoff with jitter
        let exponentialDelay = min(baseReconnectDelay * pow(2.0, Double(reconnectAttempts - 1)), maxReconnectDelay)
        let jitter = Double.random(in: 0...0.3) * exponentialDelay
        let delay = exponentialDelay + jitter

        print("WebSocket: Scheduling reconnect in \(String(format: "%.1f", delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.connect()
            }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                // First successful message means we're connected
                if self.connectionState != .connected {
                    DispatchQueue.main.async {
                        self.updateConnectionState(.connected)
                        self.reconnectAttempts = 0

                        // Resubscribe to channels after reconnection
                        for channelId in self.subscribedChannels {
                            self.subscribe(to: channelId)
                        }
                    }
                }

                switch message {
                case .string(let text):
                    self.handleTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleTextMessage(text)
                    }
                @unknown default:
                    break
                }

                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                print("WebSocket: Receive error - \(error.localizedDescription)")

                DispatchQueue.main.async {
                    // Don't reconnect if manually disconnected
                    guard !self.isManuallyDisconnected else { return }

                    self.performDisconnect()
                    self.isManuallyDisconnected = false // Reset for auto-reconnect
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(WebSocketMessage.self, from: data) else {
            print("WebSocket: Failed to decode message: \(text.prefix(100))")
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
                print("WebSocket: Server error - \(error.error)")
            }

        default:
            print("WebSocket: Unknown message type - \(message.type)")
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
            print("WebSocket: Cannot send - not connected")
            return
        }

        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            print("WebSocket: Failed to encode message")
            return
        }

        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("WebSocket: Send error - \(error.localizedDescription)")
            }
        }
    }

    /// Subscribes to a channel for real-time updates
    func subscribe(to channelId: String) {
        subscribedChannels.insert(channelId)

        guard isConnected else { return }

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

        guard isConnected else { return }

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
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        guard isConnected else { return }

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

    func isTyping(userId: String, in channelId: String) -> Bool {
        return typingUsers[channelId]?.contains(userId) ?? false
    }

    func typingUsersIn(channelId: String) -> [String] {
        return Array(typingUsers[channelId] ?? [])
    }

    func isOnline(userId: String) -> Bool {
        return onlineUsers.contains(userId)
    }
}

// MARK: - Helper Types

private struct TypingPayload: Codable {
    let typing: Bool
}

private struct ErrorPayload: Codable {
    let error: String
}

// MARK: - Certificate Pinning Delegate for WebSocket

/// URLSession delegate that performs certificate pinning for WebSocket connections
/// This prevents MITM attacks by validating the server's public key
final class WebSocketCertificatePinningDelegate: NSObject, URLSessionDelegate {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only handle server trust challenges
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Skip pinning in debug mode for easier development
        #if DEBUG
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
        return
        #else

        // Check if this host requires pinning
        let host = challenge.protectionSpace.host
        guard AppConfig.pinnedHosts.contains(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Verify the certificate chain
        guard validateCertificateChain(serverTrust: serverTrust) else {
            print("WebSocket certificate pinning failed for host: \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
        #endif
    }

    /// Validates the server certificate chain against pinned public key hashes
    private func validateCertificateChain(serverTrust: SecTrust) -> Bool {
        // Get certificate chain
        guard let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certificateChain.isEmpty else {
            return false
        }

        // Check each certificate in the chain against our pinned hashes
        for certificate in certificateChain {
            let publicKeyHash = getPublicKeyHash(from: certificate)
            if let hash = publicKeyHash,
               AppConfig.pinnedPublicKeyHashes.contains(hash) {
                return true
            }
        }

        return false
    }

    /// Extracts the SHA256 hash of the certificate's public key (SPKI)
    private func getPublicKeyHash(from certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        // Hash the public key data using CryptoKit SHA256
        let hash = SHA256.hash(data: publicKeyData)

        // Return base64-encoded hash
        return Data(hash).base64EncodedString()
    }
}
