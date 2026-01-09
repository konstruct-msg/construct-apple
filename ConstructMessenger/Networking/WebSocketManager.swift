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
    
    // Message tracking for offline scenarios
    private let messageQueueManager = MessageQueueManager.shared

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
        send(message, messageId: nil)
    }
    
    /// Send message with optional message ID tracking for offline scenarios
    func send(_ message: ClientMessage, messageId: String? = nil) {
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
            
            // If we have a messageId, mark it as queued in Core Data
            if let messageId = messageId {
                markMessageAsQueued(messageId: messageId)
            }
            return
        }

        do {
            let msgpackData = try MessagePackHelper.encode(message)
            Log.debug("Sending: \(message)", category: "WebSocket")

            let wsMessage = URLSessionWebSocketTask.Message.data(msgpackData)
            
            // Track message if we have an ID
            if let messageId = messageId {
                messageQueueManager.markMessageAsSending(messageId)
            }

            task.send(wsMessage) { [weak self] error in
                if let error = error {
                    Log.error("WebSocket send error: \(error.localizedDescription)", category: "WebSocket")
                    self?.errorPublisher.send(error)
                    
                    // If we have a messageId, mark it as failed/queued
                    if let messageId = messageId {
                        self?.handleSendError(messageId: messageId, error: error)
                    }
                } else {
                    // Successfully sent to WebSocket (but not necessarily to server)
                    // ACK will confirm actual delivery
                    if let messageId = messageId {
                        Log.debug("✅ Message \(messageId) sent to WebSocket", category: "WebSocket")
                    }
                }
            }
        } catch {
            Log.error("Failed to encode client message to MessagePack: \(String(describing: error))", category: "WebSocket")
            errorPublisher.send(NetworkError.encodingFailed)
            
            // If we have a messageId, mark it as failed
            if let messageId = messageId {
                handleSendError(messageId: messageId, error: NetworkError.encodingFailed)
            }
        }
    }
    
    // MARK: - Message Status Helpers
    
    private func markMessageAsQueued(messageId: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let context = PersistenceController.shared.container.viewContext else { return }
            
            context.perform {
                let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
                
                if let message = try? context.fetch(fetchRequest).first {
                    if message.deliveryStatus != .queued {
                        message.deliveryStatus = .queued
                        try? context.save()
                        Log.debug("📝 Marked message \(messageId) as queued", category: "WebSocket")
                    }
                }
            }
        }
    }
    
    private func handleSendError(messageId: String, error: Error) {
        messageQueueManager.markMessageAsFailed(messageId)
        
        DispatchQueue.global(qos: .utility).async {
            guard let context = PersistenceController.shared.container.viewContext else { return }
            
            context.perform {
                let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
                
                if let message = try? context.fetch(fetchRequest).first {
                    // Check if we should retry or mark as failed
                    if message.retryCount < FeatureFlags.maxMessageRetryAttempts {
                        message.deliveryStatus = .queued
                        Log.warning("⚠️ Message \(messageId) send failed, queued for retry (attempt \(message.retryCount + 1))", category: "WebSocket")
                    } else {
                        message.deliveryStatus = .failed
                        Log.error("❌ Message \(messageId) send failed after \(message.retryCount) attempts, marking as failed", category: "WebSocket")
                    }
                    try? context.save()
                }
            }
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
    
    // MARK: - Background Fetch
    
    /// Fetch offline messages in background
    /// Creates a temporary connection, requests messages, and disconnects
    /// - Parameter completion: Called with result containing array of messages or error
    func fetchOfflineMessages(completion: @escaping (Result<[ChatMessage], Error>) -> Void) {
        Log.info("📥 Starting background fetch for offline messages", category: "WebSocket")
        
        // Create a temporary WebSocket connection for background fetch
        // Use a simple configuration without delegate for background fetch
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 20.0
        let tempSession = URLSession(configuration: config)
        let request = URLRequest(url: url)
        let tempTask = tempSession.webSocketTask(with: request)
        
        var messages: [ChatMessage] = []
        var didComplete = false
        let timeout: TimeInterval = 15.0
        
        // Set timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if !didComplete {
                didComplete = true
                tempTask.cancel(with: .goingAway, reason: nil)
                completion(.failure(BackgroundFetchError.timeout))
            }
        }
        
        // Track connection state
        var isAuthenticated = false
        var hasRequestedMessages = false
        
        // Start receiving messages
        func receiveMessages() {
            tempTask.receive { result in
                guard !didComplete else { return }
                
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data):
                        do {
                            let serverMessage: ServerMessage = try MessagePackHelper.decode(from: data)
                            
                            switch serverMessage {
                            case .connectSuccess:
                                Log.info("✅ Background fetch: Connected and authenticated", category: "WebSocket")
                                isAuthenticated = true
                                
                                // Request offline messages
                                if !hasRequestedMessages {
                                    hasRequestedMessages = true
                                    do {
                                        let requestMessage = ClientMessage.getOfflineMessages
                                        let msgpackData = try MessagePackHelper.encode(requestMessage)
                                        let wsMessage = URLSessionWebSocketTask.Message.data(msgpackData)
                                        tempTask.send(wsMessage) { error in
                                            if let error = error {
                                                Log.error("Failed to send GetOfflineMessages: \(error)", category: "WebSocket")
                                                if !didComplete {
                                                    didComplete = true
                                                    completion(.failure(error))
                                                }
                                            } else {
                                                Log.info("📤 GetOfflineMessages request sent", category: "WebSocket")
                                            }
                                        }
                                    } catch {
                                        Log.error("Failed to encode GetOfflineMessages: \(error)", category: "WebSocket")
                                        if !didComplete {
                                            didComplete = true
                                            completion(.failure(error))
                                        }
                                    }
                                }
                                
                            case .offlineMessages(let data):
                                Log.info("📬 Received \(data.messages.count) offline messages", category: "WebSocket")
                                messages = data.messages
                                
                                // Disconnect after receiving messages
                                if !didComplete {
                                    didComplete = true
                                    tempTask.cancel(with: .goingAway, reason: nil)
                                    completion(.success(messages))
                                }
                                
                            case .message(let msg):
                                // Handle individual message (fallback if server sends messages one by one)
                                Log.debug("📨 Received individual message in background fetch", category: "WebSocket")
                                messages.append(msg)
                                
                            case .error(let errorData):
                                Log.error("❌ Server error: \(errorData.message)", category: "WebSocket")
                                if !didComplete {
                                    didComplete = true
                                    tempTask.cancel(with: .goingAway, reason: nil)
                                    completion(.failure(NetworkError.serverError(errorData.message)))
                                }
                                
                            case .sessionExpired:
                                Log.error("❌ Session expired during background fetch", category: "WebSocket")
                                if !didComplete {
                                    didComplete = true
                                    tempTask.cancel(with: .goingAway, reason: nil)
                                    completion(.failure(BackgroundFetchError.notAuthenticated))
                                }
                                
                            default:
                                // Ignore other message types
                                break
                            }
                            
                            // Continue receiving if not done
                            if !didComplete {
                                receiveMessages()
                            }
                        } catch {
                            Log.error("Failed to decode server message: \(error)", category: "WebSocket")
                            if !didComplete {
                                didComplete = true
                                tempTask.cancel(with: .goingAway, reason: nil)
                                completion(.failure(NetworkError.decodingFailed))
                            }
                        }
                        
                    case .string(let text):
                        Log.info("Received unexpected string message: \(text)", category: "WebSocket")
                        receiveMessages()
                        
                    @unknown default:
                        receiveMessages()
                    }
                    
                case .failure(let error):
                    Log.error("WebSocket receive error: \(error.localizedDescription)", category: "WebSocket")
                    if !didComplete {
                        didComplete = true
                        completion(.failure(error))
                    }
                }
            }
        }
        
        // Start connection
        tempTask.resume()
        
        // Authenticate after a short delay to allow connection to establish
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            guard !didComplete else { return }
            guard let sessionToken = SessionManager.shared.sessionToken else {
                if !didComplete {
                    didComplete = true
                    tempTask.cancel(with: .goingAway, reason: nil)
                    completion(.failure(BackgroundFetchError.notAuthenticated))
                }
                return
            }
            
            do {
                let connectMessage = ClientMessage.connect(ConnectData(sessionToken: sessionToken))
                let msgpackData = try MessagePackHelper.encode(connectMessage)
                let wsMessage = URLSessionWebSocketTask.Message.data(msgpackData)
                tempTask.send(wsMessage) { error in
                    if let error = error {
                        Log.error("Failed to authenticate background fetch: \(error)", category: "WebSocket")
                        if !didComplete {
                            didComplete = true
                            tempTask.cancel(with: .goingAway, reason: nil)
                            completion(.failure(error))
                        }
                    } else {
                        Log.info("🔐 Background fetch authentication sent", category: "WebSocket")
                        // Start receiving messages
                        receiveMessages()
                    }
                }
            } catch {
                Log.error("Failed to encode connect message: \(error)", category: "WebSocket")
                if !didComplete {
                    didComplete = true
                    tempTask.cancel(with: .goingAway, reason: nil)
                    completion(.failure(error))
                }
            }
        }
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

