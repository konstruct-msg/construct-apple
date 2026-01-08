import Foundation
import Combine
import CoreData
import os.log

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isSending = false
    @Published var errorMessage: String?

    // ✅ FIXED: Track session initialization state
    @Published var isSessionReady = false

    // ✅ FIXED: Queue for pending messages before session is ready
    private var pendingMessages: [(text: String, timestamp: Date)] = []

    let chat: Chat
    private var recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String)?

    private let wsManager = WebSocketManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var viewContext: NSManagedObjectContext

    // ✅ FIX: Use NSFetchedResultsController for automatic Core Data updates
    private var fetchedResultsController: NSFetchedResultsController<Message>?

    init(chat: Chat, context: NSManagedObjectContext) {
        self.chat = chat
        self.viewContext = context
        Log.debug("🔧 ChatViewModel init: chat.id=\(chat.id ?? "nil"), chat.otherUser?.id=\(chat.otherUser?.id ?? "nil"), chat.otherUser?.username=\(chat.otherUser?.username ?? "nil")", category: "ChatViewModel")

        setupFetchedResultsController()  // ✅ Setup FRC first
        setupSubscribers()
        checkExistingSession()  // ✅ FIXED: Check if session already exists
        fetchRecipientPublicKey()

        // Load messages immediately since we have context
        Log.debug("🔧 ChatViewModel initialized with viewContext", category: "ChatViewModel")
        loadMessages()
    }

    deinit {
        // ✅ FIX: Clean up subscriptions when ViewModel is destroyed
        cancellables.removeAll()
        Log.debug("🔧 ChatViewModel deinitialized", category: "ChatViewModel")
    }

    private func setupFetchedResultsController() {
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "chat == %@", chat)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        fetchedResultsController = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )

        // Observe changes using Combine
        NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadMessages()
            }
            .store(in: &cancellables)
    }

    private func setupSubscribers() {
        wsManager.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleServerMessage(message)
            }
            .store(in: &cancellables)

        // ✅ FIX: Listen for connection status changes
        wsManager.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                if isConnected {
                    Log.info("✅ WebSocket reconnected - processing queued messages", category: "ChatViewModel")
                    self?.sendQueuedMessages()
                }
            }
            .store(in: &cancellables)
    }

    // ✅ FIXED: Check if we already have a session for this user
    private func checkExistingSession() {
        guard let userId = chat.otherUser?.id else { return }
        isSessionReady = CryptoManager.shared.hasSession(for: userId)
        if isSessionReady {
            Log.info("Session already exists for user: \(userId)", category: "ChatViewModel")
        }
    }

    private func fetchRecipientPublicKey() {
        guard let userId = chat.otherUser?.id else {
            Log.error("❌ Cannot fetch recipient public key: chat.otherUser?.id is nil", category: "ChatViewModel")
            return
        }
        guard let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ Cannot fetch recipient public key: currentUserId is nil", category: "ChatViewModel")
            return
        }
        Log.debug("🔑 Fetching public key for userId: \(userId), currentUserId: \(currentUserId)", category: "ChatViewModel")

        // 🚫 BLOCK: Cannot send encrypted messages to yourself
        if userId == currentUserId {
            errorMessage = "Cannot send encrypted messages to yourself. Use notes instead."
            Log.debug("Blocked attempt to initialize session with self", category: "ChatViewModel")
            return
        }

        // Don't fetch if session already exists
        if isSessionReady {
            return
        }

        wsManager.send(.getPublicKey(GetPublicKeyData(userId: userId)))
    }

    private func loadMessages() {
        Log.debug("📥 Loading messages for chat \(chat.id ?? "unknown")", category: "ChatViewModel")

        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "chat == %@", chat)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        if let fetchedMessages = try? viewContext.fetch(fetchRequest) {
            messages = fetchedMessages
            Log.debug("📬 Loaded \(fetchedMessages.count) messages", category: "ChatViewModel")
            for (index, msg) in fetchedMessages.enumerated() {
                Log.debug("  Message \(index): id=\(msg.id ?? "nil"), isSentByMe=\(msg.isSentByMe), text=\(msg.decryptedContent?.prefix(20) ?? "nil")", category: "ChatViewModel")
            }
        } else {
            Log.error("❌ Failed to fetch messages", category: "ChatViewModel")
        }
    }

    // MARK: - Send Message
    func sendMessage(text: String, replyTo: Message? = nil) {
        Log.info("📤 sendMessage called", category: "ChatViewModel")

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.debug("❌ Empty message, ignoring", category: "ChatViewModel")
            return
        }

        guard let recipientId = chat.otherUser?.id else {
            Log.error("❌ No recipient ID", category: "ChatViewModel")
            return
        }

        guard let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ No current user ID", category: "ChatViewModel")
            return
        }

        Log.info("📤 Sending to: \(recipientId), from: \(currentUserId)", category: "ChatViewModel")

        // 🚫 BLOCK: Cannot send encrypted messages to yourself
        if recipientId == currentUserId {
            errorMessage = "Cannot send encrypted messages to yourself. Use notes app instead."
            Log.debug("❌ Blocked attempt to send message to self", category: "ChatViewModel")
            return
        }

        // ✅ FIXED: Check if session is ready before sending
        if !isSessionReady {
            // Queue the message to be sent after session initialization
            pendingMessages.append((text: text, timestamp: Date()))
            errorMessage = "Initializing secure connection..."
            Log.info("⏳ Message queued - waiting for session initialization (session ready: \(isSessionReady))", category: "ChatViewModel")
            return
        }

        Log.info("✅ Session is ready, checking WebSocket connection...", category: "ChatViewModel")

        isSending = true
        errorMessage = nil

        do {
            // Encrypt message and get components
            let components = try CryptoManager.shared.encryptMessage(text, for: recipientId)

            // Create ChatMessage with proper format per server spec
            let messageId = UUID().uuidString
            let message = ChatMessage(
                id: messageId,
                from: currentUserId,
                to: recipientId,
                ephemeralPublicKey: components.ephemeralPublicKey,  // Binary 32 bytes
                messageNumber: components.messageNumber,
                content: components.content,  // Base64(nonce || ciphertext_with_tag)
                timestamp: UInt64(Date().timeIntervalSince1970)
            )

            Log.debug("📤 Sending message with ID: \(messageId)", category: "ChatViewModel")
            Log.debug("   Message number: \(components.messageNumber)", category: "ChatViewModel")
            Log.debug("   Content length: \(message.content.count) bytes", category: "ChatViewModel")

            // ✅ FIX: Check WebSocket connection BEFORE saving as "sending"
            let wsConnected = wsManager.isConnected
            Log.info("🔌 WebSocket connected: \(wsConnected)", category: "ChatViewModel")

            if !wsConnected {
                Log.error("❌ WebSocket not connected - message will be queued", category: "ChatViewModel")
                saveMessage(
                    message,
                    decryptedContent: text,
                    isSentByMe: true,
                    status: .queued,  // Save as QUEUED, not SENDING
                    replyTo: replyTo
                )
                errorMessage = "Not connected. Message saved and will be sent when connection is restored."
                isSending = false
                return
            }

            Log.info("✅ WebSocket connected, saving message with .sending status", category: "ChatViewModel")

            // Save with .sending status
            saveMessage(
                message,
                decryptedContent: text,
                isSentByMe: true,
                status: .sending,
                replyTo: replyTo
            )

            // Send through WebSocket
            Log.info("📮 Calling wsManager.send() for message: \(messageId)", category: "ChatViewModel")
            wsManager.send(.sendMessage(message))
            Log.info("✅ wsManager.send() completed", category: "ChatViewModel")

        } catch {
            // ✅ Session was corrupted and auto-deleted by CryptoManager
            // Reinitialize session and retry
            Log.debug("🔄 Encryption failed, session was deleted. Reinitializing...", category: "ChatViewModel")

            // Delete old session from memory (already done by CryptoManager)
            // Request new public key bundle to reinitialize
            if let toUserId = chat.otherUser?.id {
                Log.info("🔑 Requesting fresh public key bundle for reinitialization", category: "ChatViewModel")

                // Mark session as not ready to trigger reinitialization flow
                isSessionReady = false

                // Queue this message to be sent after session is reinitialized
                pendingMessages.append((text: text, timestamp: Date()))
                errorMessage = "Session expired, reinitializing..."
                Log.info("📝 Message queued for retry after session reinitialization", category: "ChatViewModel")

                // Request fresh public key bundle
                wsManager.send(.getPublicKey(GetPublicKeyData(userId: toUserId)))
            } else {
                errorMessage = "Failed to encrypt message: \(error.localizedDescription)"
                Log.error("Failed to encrypt message: \(error.localizedDescription)", category: "ChatViewModel")
            }
        }
        isSending = false
    }

    // ✅ FIXED: Process pending messages after session is ready
    private func processPendingMessages() {
        guard isSessionReady else { return }

        let messagesToSend = pendingMessages
        pendingMessages.removeAll()

        for pending in messagesToSend {
            Log.info("Processing pending message from queue", category: "ChatViewModel")
            sendMessage(text: pending.text)
        }
    }

    // ✅ FIX: Send all queued messages when connection is restored
    private func sendQueuedMessages() {
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "chat == %@ AND deliveryStatusRaw == %d", chat, DeliveryStatus.queued.rawValue)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        guard let queuedMessages = try? viewContext.fetch(fetchRequest) else {
            return
        }

        Log.info("📤 Sending \(queuedMessages.count) queued messages", category: "ChatViewModel")

        for message in queuedMessages {
            // Re-encrypt and send
            guard let decryptedText = message.decryptedContent,
                  let recipientId = chat.otherUser?.id,
                  let currentUserId = SessionManager.shared.currentUserId else {
                continue
            }

            do {
                let components = try CryptoManager.shared.encryptMessage(decryptedText, for: recipientId)

                let chatMessage = ChatMessage(
                    id: message.id,
                    from: currentUserId,
                    to: recipientId,
                    ephemeralPublicKey: components.ephemeralPublicKey,
                    messageNumber: components.messageNumber,
                    content: components.content,
                    timestamp: UInt64(message.timestamp.timeIntervalSince1970)
                )

                message.deliveryStatus = .sending
                try? viewContext.save()

                wsManager.send(.sendMessage(chatMessage))
                Log.debug("📮 Re-sent queued message: \(message.id)", category: "ChatViewModel")

            } catch {
                Log.error("Failed to re-encrypt queued message: \(error)", category: "ChatViewModel")
                message.deliveryStatus = .failed
                try? viewContext.save()
            }
        }

        loadMessages()
    }

    func retryMessage(_ message: Message) {
        // Retry for failed or queued messages
        guard message.canRetry || message.deliveryStatus == .queued else {
            Log.info("Message cannot be retried", category: "ChatViewModel")
            return
        }

        guard let decryptedText = message.decryptedContent else {
            Log.error("Cannot retry - no decrypted content", category: "ChatViewModel")
            return
        }

        // Increment retry count
        message.retryCount += 1
        try? viewContext.save()

        // Re-send the message
        sendMessage(text: decryptedText)
        Log.info("Retrying message (attempt \(message.retryCount))", category: "ChatViewModel")
    }

    // MARK: - Handle Server Messages
    private func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case .publicKeyBundle(let data):
            Log.debug("📦 Received publicKeyBundle for userId: \(data.userId), chat.otherUser?.id: \(chat.otherUser?.id ?? "nil"), match: \(data.userId == chat.otherUser?.id)", category: "ChatViewModel")
            if data.userId == chat.otherUser?.id {
                // ✅ Update username if we have the user in Core Data
                if let user = chat.otherUser {
                    user.username = data.username
                    user.displayName = data.username
                    try? viewContext.save()
                    Log.info("Updated username for user: \(data.username)", category: "ChatViewModel")
                }

                self.recipientBundle = (data.identityPublic, data.signedPrekeyPublic, data.signature, data.verifyingKey)
                guard let currentUserId = SessionManager.shared.currentUserId else { return }
                
                // ✅ FIX: Proactively delete any stale session before starting a new one.
                // This handles cases where a session exists in the Rust core but not in the Swift
                // session mapping, or any other conflict, preventing initialization failures.
                CryptoManager.shared.deleteSession(for: data.userId)
                Log.info("🗑️ Proactively deleted any existing session for \(data.userId) before initialization.", category: "ChatViewModel")

                // ✅ FIX: If we requested the keys, WE are the initiator
                // The fact that we're in ChatViewModel and requested getPublicKey
                // means the user wants to start a conversation → we're the initiator
                Log.info("🔑 Received public key bundle - we requested it, so we are INITIATOR", category: "ChatViewModel")

                do {
                    let bundleWithSuite = (
                        identityPublic: data.identityPublic,
                        signedPrekeyPublic: data.signedPrekeyPublic,
                        signature: data.signature,
                        verifyingKey: data.verifyingKey,
                        suiteId: "1"
                    )
                    try CryptoManager.shared.initializeSession(for: data.userId, recipientBundle: bundleWithSuite)

                    isSessionReady = true
                    errorMessage = nil
                    Log.info("✅ Session initialized as INITIATOR for \(data.userId)", category: "ChatViewModel")

                    // Process any pending messages
                    processPendingMessages()

                } catch {
                    errorMessage = "Failed to initialize secure session: \(error.localizedDescription)"
                    Log.error("❌ Failed to initialize session: \(error.localizedDescription)", category: "ChatViewModel")
                    isSessionReady = false
                }
            }
        // ✅ REMOVED: .message handling - ChatsViewModel handles ALL incoming messages
        // ChatViewModel only handles ACKs for sent messages
        case .ack(let data):
            handleAck(messageId: data.messageId, status: data.status)
        case .error(let data):
            self.errorMessage = data.message
        default:
            break
        }
    }
    
    private func handleAck(messageId: String, status: String) {
        Log.debug("📨 Received ACK for message: \(messageId), status: \(status)", category: "ChatViewModel")

        // First, try to find the message by ID
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)

        if let message = try? viewContext.fetch(fetchRequest).first {
            Log.debug("✅ Found message by ID: \(messageId)", category: "ChatViewModel")
            updateMessageStatus(messageId: messageId, status: status == "delivered" ? .delivered : .sent)
        } else {
            Log.debug("❌ Message not found by ID: \(messageId)", category: "ChatViewModel")

            // List all pending messages to debug
            let allMessagesRequest: NSFetchRequest<Message> = Message.fetchRequest()
            allMessagesRequest.predicate = NSPredicate(format: "chat == %@ AND isSentByMe == YES", chat)
            allMessagesRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

            if let allMessages = try? viewContext.fetch(allMessagesRequest) {
                Log.debug("📋 All sent messages in this chat:", category: "ChatViewModel")
                for msg in allMessages.prefix(5) {
                    Log.debug("  - ID: \(msg.id ?? "nil"), status: \(msg.deliveryStatus), timestamp: \(msg.timestamp)", category: "ChatViewModel")
                }

                // Try to match by most recent sending message
                if let mostRecentSending = allMessages.first(where: { $0.deliveryStatus == .sending }) {
                    Log.debug("🔄 Assuming ACK is for most recent sending message: \(mostRecentSending.id ?? "nil")", category: "ChatViewModel")
                    mostRecentSending.deliveryStatus = status == "delivered" ? .delivered : .sent
                    try? viewContext.save()
                    loadMessages()
                }
            }
        }
    }

    // ✅ REMOVED: handleIncomingMessage - ChatsViewModel handles ALL incoming messages
    // ChatViewModel only displays messages already saved to Core Data

    // MARK: - Core Data Operations
    private func saveMessage(_ message: ChatMessage, decryptedContent: String, isSentByMe: Bool, status: DeliveryStatus, replyTo: Message? = nil) {
        Log.debug("💾 Saving message \(message.id), isSentByMe: \(isSentByMe), status: \(status)", category: "ChatViewModel")

        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", message.id)

        if let existing = try? viewContext.fetch(fetchRequest).first {
            Log.debug("📝 Updating existing message \(message.id)", category: "ChatViewModel")
            existing.deliveryStatus = status
        } else {
            Log.debug("✨ Creating new message \(message.id)", category: "ChatViewModel")
            let newMessage = Message(context: viewContext)
            newMessage.id = message.id
            newMessage.fromUserId = message.from
            newMessage.toUserId = message.to
            newMessage.encryptedContent = message.content
            newMessage.decryptedContent = decryptedContent
            newMessage.timestamp = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
            newMessage.isSentByMe = isSentByMe
            newMessage.deliveryStatus = status
            newMessage.retryCount = 0  // ✅ FIX: Initialize required field
            newMessage.chat = chat

            // Set reply information
            if let replyMessage = replyTo {
                newMessage.replyToMessageId = replyMessage.id
                newMessage.replyToContent = replyMessage.decryptedContent
            }
        }

        do {
            try viewContext.save()
            Log.debug("✅ Message saved to Core Data", category: "ChatViewModel")
            loadMessages()
            Log.debug("📊 After loadMessages: \(messages.count) messages", category: "ChatViewModel")
        } catch {
            Log.error("Failed to save or update message: \(error.localizedDescription)", category: "ChatViewModel")
        }
    }

    private func updateMessageStatus(messageId: String, status: DeliveryStatus) {
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)

        if let message = try? viewContext.fetch(fetchRequest).first {
            message.deliveryStatus = status
            try? viewContext.save()
            loadMessages()
        }
    }
}
