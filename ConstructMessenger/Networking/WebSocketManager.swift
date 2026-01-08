import Foundation
import Combine
import MessagePack
import os.log

class WebSocketManager: NSObject, ObservableObject {
    static let shared = WebSocketManager()

    @Published var isConnected = false
    @Published var connectionStatus: ConnectionStatus = .disconnected

    private var webSocketTask: URLSessionWebSocketTask?
    private var url: URL {
        let raw = APIConstants.activeServerURL
            guard let url = URL(string: raw) else {
                Log.error("❌ Invalid WebSocket URL: \(raw)", category: "WebSocket")
                fatalError("Invalid WebSocket URL: \(raw)")
            }
            return url
    }
    private var session: URLSession!

    let messagePublisher = PassthroughSubject<ServerMessage, Never>()
    let errorPublisher = PassthroughSubject<Error, Never>()

    // Auto-reconnection
    private var reconnectAttempts = 0
    private var reconnectTimer: Timer?
    private var messageQueue: [ClientMessage] = []
    private var isReconnecting = false

    // Keep-alive ping
    private var pingTimer: Timer?

    enum ConnectionStatus {
        case connected
        case disconnected
        case reconnecting(attempt: Int)

        var displayText: String {
            switch self {
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            case .reconnecting: return "Reconnecting..."
            }
        }
    }

    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - Connection
    func connect() {
        guard webSocketTask == nil else {
            Log.info("WebSocket task already exists, skipping connect", category: "WebSocket")
            return
        }

        Log.info("Connecting to: \(url.absoluteString)", category: "WebSocket")
        let request = URLRequest(url: url)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
    }

    // MARK: - Ping / Keep-Alive
    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        guard let task = webSocketTask else {
            stopPingTimer()
            return
        }
        task.sendPing { error in
            if let error = error {
                Log.error("Failed to receive pong: \(error.localizedDescription)", category: "WebSocket")
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - Send Message
    func send(_ message: ClientMessage) {
        // ✅ FIX: Queue message if not connected, except for Connect which is handled automatically
        guard let task = webSocketTask, isConnected else {
            // Queue non-Connect messages for later sending
            if case .connect = message {
                // Connect messages are handled automatically by authenticateSession()
                Log.info("Connect message queued - will be sent automatically on connection", category: "WebSocket")
                return
            }
            Log.info("Queueing message - WebSocket not yet connected", category: "WebSocket")
            messageQueue.append(message)
            return
        }

        do {
            let msgpackData = try MessagePackHelper.encode(message)
            Log.debug("Sending: \(message)", category: "WebSocket")

            let wsMessage = URLSessionWebSocketTask.Message.data(msgpackData)

            task.send(wsMessage) { [weak self] error in
                if let error = error {
                    Log.error("WebSocket send error: \(error.localizedDescription)", category: "WebSocket")
                    self?.errorPublisher.send(error)
                }
            }
        } catch {
            Log.error("Failed to encode client message to MessagePack: \(String(describing: error))", category: "WebSocket")
            errorPublisher.send(NetworkError.encodingFailed)
        }
    }

    // MARK: - Receive Messages
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleMessage(data)
                case .string(let text):
                    Log.info("Received unexpected string message: \(text)", category: "WebSocket")
                @unknown default:
                    Log.info("Received unknown message type", category: "WebSocket")
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                Log.error("WebSocket receive error: \(error.localizedDescription)", category: "WebSocket")
                DispatchQueue.main.async {
                    let wasConnected = self.isConnected
                    self.isConnected = false
                    self.connectionStatus = .disconnected
                    // Only send error if we were trying to connect (not already connected)
                    // Connection errors are handled by urlSession:task:didCompleteWithError:
                    // If connection was established, this is just a receive error and reconnection will handle it
                    if !wasConnected && !self.isReconnecting {
                        self.errorPublisher.send(NetworkError.connectionFailed)
                    }
                }
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ data: Data) {
        do {
            let serverMessage: ServerMessage = try MessagePackHelper.decode(from: data)
            Log.debug("Received: \(serverMessage)", category: "WebSocket")
            messagePublisher.send(serverMessage)
        } catch {
            Log.error("Failed to decode server message: \(error.localizedDescription)", category: "WebSocket")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .typeMismatch(let type, let context):
                    Log.error("Type mismatch: expected \(type), context: \(context.debugDescription)", category: "WebSocket")
                case .valueNotFound(let type, let context):
                    Log.error("Value not found for \(type), context: \(context.debugDescription)", category: "WebSocket")
                case .keyNotFound(let key, let context):
                    Log.error("Key not found: \(key.stringValue), context: \(context.debugDescription)", category: "WebSocket")
                case .dataCorrupted(let context):
                    Log.error("Data corrupted: \(context.debugDescription)", category: "WebSocket")
                @unknown default:
                    Log.error("Unknown decoding error: \(decodingError.localizedDescription)", category: "WebSocket")
                }
            }
            errorPublisher.send(NetworkError.decodingFailed)
        }
    }

    // MARK: - Reconnection Logic
    private func scheduleReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        reconnectAttempts += 1

        DispatchQueue.main.async {
            self.connectionStatus = .reconnecting(attempt: self.reconnectAttempts)
        }
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard isReconnecting else { return }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connect()
    }

    private func onReconnectSuccess() {
        reconnectAttempts = 0
        isReconnecting = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        flushMessageQueue()
    }
    
    private func onConnectionEstablished() {
        // Clear message queue and flush any queued messages after authentication
        // Note: authenticateSession() is called automatically in didOpenWithProtocol
        flushMessageQueue()
    }

    private func flushMessageQueue() {
        let queuedMessages = messageQueue
        messageQueue.removeAll()
        for message in queuedMessages {
            send(message)
        }
    }

    // MARK: - Authentication
    private func authenticateSession() {
        guard let sessionToken = SessionManager.shared.sessionToken else {
            Log.error("❌ No session token available for authentication", category: "WebSocket")
            return
        }

        Log.info("🔐 Authenticating WebSocket with session token", category: "WebSocket")
        let connectMessage = ClientMessage.connect(ConnectData(sessionToken: sessionToken))
        // At this point we should be connected, so send should work
        // But if not, it will be queued
        send(connectMessage)
    }

    // MARK: - Disconnect
    func disconnect() {
        stopPingTimer()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isReconnecting = false
        reconnectAttempts = 0

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        connectionStatus = .disconnected
    }
}

// MARK: - URLSessionWebSocketDelegate
extension WebSocketManager: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            Log.info("✅ WebSocket connected successfully", category: "WebSocket")
            self.isConnected = true
            self.connectionStatus = .connected

            // ✅ FIX: Authenticate immediately after connection
            self.authenticateSession()
            
            // Flush any queued messages after a short delay to ensure authentication completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.onConnectionEstablished()
            }

            if self.isReconnecting {
                self.onReconnectSuccess()
            }
            self.startPingTimer()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            Log.info("WebSocket disconnected (code: \(closeCode.rawValue))", category: "WebSocket")
            self.stopPingTimer()
            self.isConnected = false
            self.connectionStatus = .disconnected
            if closeCode != .goingAway {
                self.scheduleReconnect()
            }
        }
    }
    
    // Handle URLSession errors (connection failures)
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                Log.error("WebSocket task failed: \(error.localizedDescription)", category: "WebSocket")
                self.isConnected = false
                self.connectionStatus = .disconnected
                // Send error only if we're not already reconnecting
                if !self.isReconnecting {
                    self.errorPublisher.send(NetworkError.connectionFailed)
                }
                self.scheduleReconnect()
            }
        }
    }
}

