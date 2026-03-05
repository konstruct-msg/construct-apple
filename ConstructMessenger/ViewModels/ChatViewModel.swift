import Foundation
import Combine
import CoreData
import UIKit
import os.log
import GRPCCore

// MARK: - Message Queue Models

/// Represents a message queued for sending when session is not ready
struct QueuedMessage {
    let text: String
    let images: [UIImage]
    let replyTo: Message?
    let timestamp: Date
    
    init(text: String, images: [UIImage] = [], replyTo: Message? = nil) {
        self.text = text
        self.images = images
        self.replyTo = replyTo
        self.timestamp = Date()
    }
}

@MainActor
@Observable
class ChatViewModel: NSObject {
    var messages: [Message] = []
    var isSending = false
    var errorMessage: String?
    var isLoadingMore = false
    var hasMoreMessages = true

    // ✅ FIXED: Track session initialization state
    var isSessionReady = false
    var isInitializingSession = false  // NEW: Show UI indicator

    // ✅ REFACTORED: Enhanced message queue with full support
    private var queuedMessages: [QueuedMessage] = []
    
    // ✅ NEW: Track public key fetch timeout
    nonisolated(unsafe) private var publicKeyFetchTimer: Timer?
    private let publicKeyFetchTimeout: TimeInterval = 10.0 // 10 seconds timeout
    
    // ✅ Pagination support - optimized for performance
    private let initialMessageLimit = 30  // Load 30 most recent messages initially
    private let loadMoreBatchSize = 20     // Load 20 older messages per "load more" request
    private var oldestLoadedTimestamp: Date?
    private var allLoadedMessageIds: Set<String> = []

    let chat: Chat
    private var recipientBundle: (identityPublic: String, signedPrekeyPublic: String, signature: String, verifyingKey: String)?

    private let connectionStatusManager = ConnectionStatusManager.shared
    private let messageQueueManager = MessageQueueManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var viewContext: NSManagedObjectContext

    // ✅ FIX: Use NSFetchedResultsController for automatic Core Data updates
    private var fetchedResultsController: NSFetchedResultsController<Message>?
    
    // ✅ REFACTOR: Extracted services
    private let sessionInitService = SessionInitializationService()
    private let persistenceService = MessagePersistenceService()
    private let mediaUploadManager = MediaUploadManager()
    private let retryManager = MessageRetryManager()

    init(chat: Chat, context: NSManagedObjectContext) {
        self.chat = chat
        self.viewContext = context
        
        super.init()  // ✅ REFACTOR: NSObject requires super.init()
        
        Log.debug("🔧 ChatViewModel init: chat.id=\(chat.id), chat.otherUser?.id=\(chat.otherUser?.id ?? "nil"), chat.otherUser?.username=\(chat.otherUser?.username ?? "nil")", category: "ChatViewModel")

        setupFetchedResultsController()  // ✅ Setup FRC - loads initial messages automatically
        setupSubscribers()
        checkExistingSession()  // ✅ FIXED: Check if session already exists
        fetchRecipientPublicKey()

        // ❌ REMOVED: loadMessages() - FRC already loaded messages in setupFetchedResultsController()
        Log.debug("🔧 ChatViewModel initialized with viewContext", category: "ChatViewModel")
        
        // Listen for queued messages processing
        setupMessageQueueListener()
    }

    deinit {
        publicKeyFetchTimer?.invalidate()
        Log.debug("🔧 ChatViewModel deinitialized", category: "ChatViewModel")
    }

    private func setupFetchedResultsController() {
        let fetchRequest = Message.fetchRequest()
        // Combine with additional predicate
        let chatPredicate = NSPredicate(format: "chat == %@", chat)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate])
        
        // ✅ OPTIMIZATION: Fetch newest 30 messages, then reverse to oldest-first
        // This ensures we get RECENT messages, not ancient history
        // Reversal happens ONCE on fetch, not on every SwiftUI render
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = initialMessageLimit  // Only load recent 30 messages

        fetchedResultsController = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )

        // ✅ REFACTOR: Use proper FRC delegate instead of NotificationCenter
        fetchedResultsController?.delegate = self
        
        do {
            try fetchedResultsController?.performFetch()
            // ✅ Reverse ONCE: FRC gives newest-first, we store oldest-first for UI
            let fetchedMessages = fetchedResultsController?.fetchedObjects ?? []
            messages = Array(fetchedMessages.reversed())
            oldestLoadedTimestamp = messages.first?.timestamp  // First = oldest after reversal
            allLoadedMessageIds = Set(messages.map { $0.id })
            
            Log.debug("✅ FRC initial fetch: \(messages.count) messages (reversed to oldest-first)", category: "ChatViewModel")
        } catch {
            Log.error("❌ FRC fetch failed: \(error)", category: "ChatViewModel")
        }
    }

    private func setupSubscribers() {
        // ✅ Listen for connection status changes (gRPC stream based)
        // Incoming messages are received via long polling in ChatsViewModel
        // and saved to Core Data, then picked up via NSManagedObjectContextObjectsDidChange
        connectionStatusManager.$connectionStatus
            .sink { [weak self] status in
                if status == .connected {
                    Log.info("✅ Network connected - processing queued messages", category: "ChatViewModel")
                    self?.sendQueuedMessages()
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupMessageQueueListener() {
        // Listen for queued messages processing requests
        NotificationCenter.default.publisher(for: .processQueuedMessages)
            .sink { [weak self] notification in
                self?.sendQueuedMessages()
            }
            .store(in: &cancellables)
    }

    // ✅ FIXED: Check if we already have a session for this user
    private func checkExistingSession() {
        guard let userId = chat.otherUser?.id else { return }
        
        isSessionReady = CryptoManager.shared.hasSession(for: userId)
        if isSessionReady {
            Log.info("✅ Session already exists for user: \(userId)", category: "ChatViewModel")
        } else {
            Log.debug("No session yet for user: \(userId)", category: "ChatViewModel")
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

        // ✅ NEW: Cancel any existing timer
        publicKeyFetchTimer?.invalidate()
        
        // ✅ NEW: Set timeout timer
        publicKeyFetchTimer = Timer.scheduledTimer(withTimeInterval: publicKeyFetchTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !self.isSessionReady {
                    Log.error("⏱️ Timeout waiting for public key bundle from server", category: "ChatViewModel")
                    self.errorMessage = "Failed to establish secure connection: server did not respond"
                    self.isSessionReady = false
                }
            }
        }

        // ✅ REFACTOR: Use SessionInitializationService with retry
        Task {
            do {
                let publicKeyBundle = try await sessionInitService.fetchPublicKeyWithRetry(userId: userId)
                
                await MainActor.run {
                    self.handlePublicKeyBundle(publicKeyBundle)
                }
            } catch {
                await MainActor.run {
                    Log.error("❌ Failed to fetch public key via gRPC after retries: \(error.localizedDescription)", category: "ChatViewModel")
                    self.errorMessage = "Failed to fetch public key after retries: \(error.localizedDescription)"
                    self.isSessionReady = false
                }
            }
        }
    }
    
    private func handlePublicKeyBundle(_ data: PublicKeyBundleData) {
        Log.debug("📦 Received publicKeyBundle for userId: \(data.userId), chat.otherUser?.id: \(chat.otherUser?.id ?? "nil"), match: \(data.userId == chat.otherUser?.id)", category: "ChatViewModel")
        guard data.userId == chat.otherUser?.id else { return }

        // Update username if we have the user in Core Data
        if let user = chat.otherUser {
            let normalized = data.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, normalized.lowercased() != "anonymous", UUID(uuidString: normalized) == nil {
                user.username = normalized
                user.displayName = normalized
            } else {
                user.username = ""
                user.displayName = DisplayNameGenerator.generate(from: data.userId)
            }
            try? viewContext.save()
            Log.info("Updated username for user: \(data.username)", category: "ChatViewModel")
        }

        // Cache the bundle for use when the user actually sends a message.
        // Do NOT create an INITIATOR session here — proactively initialising a session
        // while the remote side may already be mid-ratchet (messageNumber > 0) causes
        // AEAD failures → heal_impossible → END_SESSION notification loop.
        // Session creation as INITIATOR happens on-demand inside sendMessage/initializeSessionProactively.
        self.recipientBundle = (data.identityPublic, data.signedPrekeyPublic, data.signature, data.verifyingKey)

        // If a RECEIVER session was already created by ChatsViewModel (incoming message arrived
        // while we were fetching the bundle), mark as ready so the UI reflects that.
        if CryptoManager.shared.hasSession(for: data.userId) {
            Log.info("✅ SESSION_STATE[bundle_fetched_session_exists]: session already established for \(data.userId.prefix(8))…", category: "ChatViewModel")
            isSessionReady = true
        } else {
            Log.info("📦 SESSION_STATE[bundle_cached]: bundle ready for \(data.userId.prefix(8))…, session will be created on first send", category: "ChatViewModel")
        }
    }

    // ✅ NEW: Load initial messages (last N messages)
    
    // ✅ NEW: Load more messages (older messages)
    func loadMoreMessages() {
        guard !isLoadingMore, hasMoreMessages, let oldestTimestamp = oldestLoadedTimestamp else {
            return
        }
        
        isLoadingMore = true
        Log.debug("📥 Loading more messages before \(oldestTimestamp)", category: "ChatViewModel")
        
        let fetchRequest = Message.fetchRequest()
        // Combine with additional predicate
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate])
        // ✅ Sort ascending (oldest first) to match main array order
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        fetchRequest.fetchLimit = loadMoreBatchSize  // ✅ Use batch size for pagination
        
        if let fetchedMessages = try? viewContext.fetch(fetchRequest) {
            let newMessages = fetchedMessages.filter { !allLoadedMessageIds.contains($0.id) }
            
            if newMessages.isEmpty {
                hasMoreMessages = false
                isLoadingMore = false
                Log.debug("📭 No more older messages to load", category: "ChatViewModel")
                return
            }
            
            // Already in chronological order (oldest first), prepend to beginning
            messages = newMessages + messages
            oldestLoadedTimestamp = messages.first?.timestamp  // First = oldest
            allLoadedMessageIds.formUnion(Set(newMessages.map { $0.id }))
            
            // Check if there are more messages
            checkIfHasMoreMessages()
            
            Log.debug("📬 Loaded \(newMessages.count) more messages (total: \(messages.count))", category: "ChatViewModel")
        } else {
            Log.error("❌ Failed to fetch more messages", category: "ChatViewModel")
        }
        
        isLoadingMore = false
    }
    
    // ✅ NEW: Check if there are more messages to load
    private func checkIfHasMoreMessages() {
        guard let oldestTimestamp = oldestLoadedTimestamp else {
            hasMoreMessages = false
            return
        }
        
        let fetchRequest = Message.fetchRequest()
        // Combine with additional predicate
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate])
        fetchRequest.fetchLimit = 1
        
        hasMoreMessages = (try? viewContext.fetch(fetchRequest).first) != nil
    }
    
    // ✅ NEW: Reload messages when new ones are added (called from Core Data notifications)
    // MARK: - Delete Messages
    
    func deleteMessage(_ message: Message) {
        // ✅ REFACTOR: Use MessagePersistenceService
        do {
            try persistenceService.deleteMessage(message, chat: chat, in: viewContext)
        } catch {
            Log.error("❌ Failed to delete message: \(error)", category: "ChatViewModel")
        }
    }
    
    func deleteMessages(withIds messageIds: Set<String>) {
        // ✅ REFACTOR: Use MessagePersistenceService
        do {
            try persistenceService.deleteMessages(withIds: messageIds, chat: chat, in: viewContext)
        } catch {
            Log.error("❌ Failed to delete messages: \(error)", category: "ChatViewModel")
        }
    }
    
    // ✅ REFACTOR: Simplified - FRC now handles all updates automatically
    
    // MARK: - Session Initialization Utilities
    // ✅ REFACTOR: Session initialization logic moved to SessionInitializationService
    
    /// Proactively initialize session for a user
    /// Called when message is queued but session doesn't exist yet
    private func initializeSessionProactively(userId: String) async {
        await MainActor.run {
            isInitializingSession = true
        }
        
        // ✅ REFACTOR: Use SessionInitializationService
        await sessionInitService.initializeSessionProactively(
            userId: userId,
            onSuccess: { [weak self] in
                guard let self = self else { return }
                self.isSessionReady = true
                self.isInitializingSession = false
                self.errorMessage = nil
                
                // Send queued messages
                Task {
                    await self.sendQueuedMessages(userId: userId)
                }
            },
            onFailure: { [weak self] error in
                guard let self = self else { return }
                self.isInitializingSession = false
                self.errorMessage = "Failed to initialize secure connection: \(error.localizedDescription)"
                
                // Mark queued messages as failed
                self.failQueuedMessages(reason: error.localizedDescription)
            }
        )
    }
    
    /// Send all queued messages after session is ready
    private func sendQueuedMessages(userId: String) async {
        await MainActor.run {
            Log.info("📤 SESSION_STATE[send_queued]: userId=\(userId.prefix(8))..., queueSize=\(queuedMessages.count)", category: "SessionInit")
            
            let messagesToSend = queuedMessages
            queuedMessages.removeAll()
            
            for queued in messagesToSend {
                Log.info("📤 Sending queued message: \"\(queued.text.prefix(30))...\"", category: "ChatViewModel")
                sendMessage(text: queued.text, images: queued.images, replyTo: queued.replyTo)
            }
        }
    }
    
    /// Mark all queued messages as failed
    private func failQueuedMessages(reason: String) {
        Log.error("❌ Failing \(queuedMessages.count) queued messages: \(reason)", category: "ChatViewModel")
        queuedMessages.removeAll()
        // Messages are lost - user needs to retry manually
        // TODO: Could save to Core Data with .failed status for UI display
    }

    // MARK: - Send Message
    func sendMessage(text: String, images: [UIImage] = [], replyTo: Message? = nil) {
        Log.info("📤 sendMessage called with \(images.count) images", category: "ChatViewModel")

        guard let recipientId = chat.otherUser?.id else {
            Log.error("❌ No recipient ID", category: "ChatViewModel")
            return
        }
        guard let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ No current user ID", category: "ChatViewModel")
            return
        }
        // 🚫 BLOCK: Cannot send encrypted messages to yourself
        guard recipientId != currentUserId else {
            errorMessage = "Cannot send encrypted messages to yourself. Use notes app instead."
            Log.debug("❌ Blocked attempt to send message to self", category: "ChatViewModel")
            return
        }

        // Session check applies to ALL send paths (text AND media).
        // If no session yet, queue the message and init INITIATOR on-demand.
        // Previously the session was created proactively on chat open which caused
        // INITIATOR/RECEIVER conflicts and "session out of sync" notification loops.
        let hasSession = CryptoManager.shared.hasSession(for: recipientId)
        if !hasSession {
            let queued = QueuedMessage(text: text, images: images, replyTo: replyTo)
            queuedMessages.append(queued)
            errorMessage = "Initializing secure connection..."
            isInitializingSession = true
            Log.info("📝 SESSION_STATE[queue_message]: userId=\(recipientId.prefix(8))..., queueSize=\(queuedMessages.count)", category: "SessionInit")
            Task {
                await initializeSessionProactively(userId: recipientId)
            }
            return
        }

        Log.info("📤 Sending to: \(recipientId), from: \(currentUserId)", category: "ChatViewModel")

        // Handle images if provided
        if !images.isEmpty {
            sendMediaMessage(images: images, caption: text, replyTo: replyTo)
            return
        }

        // Validate message size
        do {
            try MessageValidator.validateText(text)
        } catch let error as MessageValidationError {
            errorMessage = error.localizedDescription
            Log.error("❌ Message validation failed: \(error.localizedDescription)", category: "ChatViewModel")
            return
        } catch {
            errorMessage = "Failed to validate message: \(error.localizedDescription)"
            Log.error("❌ Unexpected validation error: \(error)", category: "ChatViewModel")
            return
        }

        Log.info("✅ Session is ready, sending via gRPC...", category: "ChatViewModel")

        isSending = true
        errorMessage = nil

        do {
            // Create ChatMessage with proper format per server spec
            let messageId = UUID().uuidString
            let plan = ChunkedMessageSender.shared.buildPlan(plaintext: text, messageId: UUID(uuidString: messageId) ?? UUID())
            let firstPayload = plan.payloads.first ?? text
            let firstComponents = try CryptoManager.shared.encryptMessage(firstPayload, for: recipientId)
            let message = ChatMessage(
                id: messageId,
                from: currentUserId,
                to: recipientId,
                messageType: nil,  // Will be set by server as "DIRECT_MESSAGE"
                ephemeralPublicKey: firstComponents.ephemeralPublicKey,  // Binary 32 bytes
                messageNumber: firstComponents.messageNumber,
                content: firstComponents.content,  // Base64(nonce || ciphertext_with_tag)
                suiteId: firstComponents.suiteId,
                timestamp: UInt64(Date().timeIntervalSince1970)
                
            )

            Log.debug("📤 Sending message with ID: \(messageId)", category: "ChatViewModel")
            Log.debug("   Message number: \(firstComponents.messageNumber)", category: "ChatViewModel")
            Log.debug("   Content length: \(message.content.count) bytes", category: "ChatViewModel")

            // Save with .sending status
            saveMessage(
                message,
                decryptedContent: text,
                isSentByMe: true,
                status: .sending,
                replyTo: replyTo,
                suiteId: firstComponents.suiteId
            )

            // ✅ Send via gRPC
        Log.info("📮 Sending message via gRPC: \(messageId)", category: "ChatViewModel")
            Task {
                // Apply timing jitter for traffic analysis resistance (0–50ms for user messages)
                let jitterMs = TrafficProtectionService.shared.recommendedSendDelay(isHighPriority: true)
                if jitterMs > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(jitterMs)))
                }

                do {
                    let responses = try await ChunkedMessageSender.shared.sendChunks(
                        plan: plan,
                        senderId: currentUserId,
                        recipientId: recipientId,
                        conversationId: ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId),
                        timestamp: message.timestamp,
                        preEncryptedFirst: firstComponents
                    )
                    let response = responses.first ?? SendMessageResponse(messageId: messageId, status: "sent")

                    // Record real message sent for cover traffic coalescing
                    TrafficProtectionService.shared.recordRealMessageSent()

                    await MainActor.run {
                        // ✅ IMPROVED: Use server-provided status if available
                        let deliveryStatus: DeliveryStatus
                        
                        switch response.status.lowercased() {
                        case "delivered":
                            deliveryStatus = .delivered
                        case "queued":
                            deliveryStatus = .queued
                        case "sent", "success":
                            deliveryStatus = .sent
                        case "failed":
                            deliveryStatus = .failed
                            Log.error("❌ Server rejected message \(messageId): status=failed", category: "ChatViewModel")
                        default:
                            deliveryStatus = .sent  // Fallback to sent
                            Log.info("⚠️ Unknown server status: \(response.status), using .sent", category: "ChatViewModel")
                        }
                        
                        Log.info("🔄 Updating message status from sending → \(deliveryStatus) for \(messageId)", category: "ChatViewModel")
                        updateMessageStatus(messageId: messageId, status: deliveryStatus)
                        Log.info("✅ Message sent via gRPC: \(response.messageId), server status: \(response.status)", category: "ChatViewModel")
                    }
                } catch {
                    await MainActor.run {
                        if let networkError = error as? NetworkError,
                           case .serverError(let message, let responseBody) = networkError {
                            Log.error("❌ Failed to send message via gRPC: \(message)\nResponse: \(responseBody ?? "empty")", category: "ChatViewModel")
                        } else if let rpcError = error as? RPCError {
                            Log.error("❌ SendMessage gRPC error: code=\(rpcError.code), message=\(rpcError.message)", category: "ChatViewModel")
                        } else {
                            Log.error("❌ Failed to send message: \(error)", category: "ChatViewModel")
                        }
                        updateMessageStatus(messageId: messageId, status: .failed)
                        errorMessage = "Failed to send message: \(error.localizedDescription)"
                    }
                }
            }

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

                // Queue this message using new system
                let queued = QueuedMessage(text: text, images: [], replyTo: replyTo)
                queuedMessages.append(queued)
                errorMessage = "Session expired, reinitializing..."
                isInitializingSession = true
                Log.info("📝 Message queued for retry after session reinitialization", category: "ChatViewModel")

                // ✅ Request fresh public key bundle via gRPC with retry
                Task {
                    await initializeSessionProactively(userId: toUserId)
                }
            } else {
                errorMessage = "Failed to encrypt message: \(error.localizedDescription)"
                Log.error("Failed to encrypt message: \(error.localizedDescription)", category: "ChatViewModel")
            }
        }
        isSending = false
    }

    // ✅ DEPRECATED: Old method - replaced by sendQueuedMessages()
    // Kept for reference, can be removed
    private func processPendingMessages() {
        // Now handled by sendQueuedMessages() in Session Initialization Utilities
        Log.debug("processPendingMessages called - deprecated, use sendQueuedMessages()", category: "ChatViewModel")
    }

    // ✅ Send all queued messages when connection is restored
    private func sendQueuedMessages() {
        // ✅ REFACTOR: Use MessageRetryManager
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = SessionManager.shared.currentUserId else {
            return
        }
        
        retryManager.sendQueuedMessages(
            for: chat,
            recipientId: recipientId,
            currentUserId: currentUserId,
            context: viewContext
        )
    }

    func retryMessage(_ message: Message) {
        // ✅ REFACTOR: Use MessageRetryManager
        guard let recipientId = chat.otherUser?.id else {
            Log.error("❌ No recipient ID for retry", category: "ChatViewModel")
            return
        }
        
        retryManager.retryMessage(
            message,
            recipientId: recipientId,
            context: viewContext,
            onError: { [weak self] error in
                self?.errorMessage = error
            }
        )
    }

    // ✅ NOTE: Using gRPC for all messaging
    // Incoming messages are received via long polling in ChatsViewModel
    // and saved to Core Data, then picked up via NSManagedObjectContextObjectsDidChange
    // ACKs are received from gRPC SendMessage response

    // MARK: - Core Data Operations
    // MARK: - Media Messages

    private func sendMediaMessage(images: [UIImage], caption: String, replyTo: Message?) {
        guard let recipientId = chat.otherUser?.id else {
            Log.error("❌ No recipient ID for media message", category: "ChatViewModel")
            errorMessage = "Cannot send media: no recipient"
            return
        }
        // Note: session existence is already guaranteed by sendMessage() before this is called.

        isSending = true
        errorMessage = nil

        Task {
            do {
                let result = try await mediaUploadManager.uploadMediaAndBuildContent(
                    images: images,
                    caption: caption,
                    recipientId: recipientId
                )
                
                await MainActor.run {
                    sendTextMessage(text: result.messageContent, replyTo: replyTo, localThumbnails: result.thumbnails)
                }
            } catch {
                await MainActor.run {
                    Log.error("❌ Media upload failed: \(error.localizedDescription) | raw: \(error)", category: "ChatViewModel")
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    private func sendTextMessage(text: String, replyTo: Message?, localThumbnails: [Data] = []) {
        // Reuse existing logic for sending text messages
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = SessionManager.shared.currentUserId else {
            isSending = false
            return
        }

        do {
            let messageId = UUID().uuidString
            let plan = ChunkedMessageSender.shared.buildPlan(plaintext: text, messageId: UUID(uuidString: messageId) ?? UUID())
            let firstPayload = plan.payloads.first ?? text
            let firstComponents = try CryptoManager.shared.encryptMessage(firstPayload, for: recipientId)
            let message = ChatMessage(
                id: messageId,
                from: currentUserId,
                to: recipientId,
                messageType: nil,  // Will be set by server
                ephemeralPublicKey: firstComponents.ephemeralPublicKey,
                messageNumber: firstComponents.messageNumber,
                content: firstComponents.content,
                suiteId: firstComponents.suiteId,
                timestamp: UInt64(Date().timeIntervalSince1970)
                
            )

            saveMessage(message, decryptedContent: text, isSentByMe: true, status: .sending, replyTo: replyTo, localThumbnails: localThumbnails, suiteId: firstComponents.suiteId)

            // ✅ Send via gRPC
            Task {
                do {
                    let _ = try await ChunkedMessageSender.shared.sendChunks(
                        plan: plan,
                        senderId: currentUserId,
                        recipientId: recipientId,
                        conversationId: ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId),
                        timestamp: message.timestamp,
                        preEncryptedFirst: firstComponents
                    )
                    
                    await MainActor.run {
                        updateMessageStatus(messageId: message.id, status: .sent)
                        isSending = false
                    }
                } catch {
                    await MainActor.run {
                        if let networkError = error as? NetworkError,
                           case .serverError(let message, let responseBody) = networkError {
                            Log.error("❌ Failed to send message via gRPC: \(message)\nResponse: \(responseBody ?? "empty")", category: "ChatViewModel")
                        } else {
                            Log.error("❌ Failed to send message via gRPC: \(error.localizedDescription)", category: "ChatViewModel")
                        }
                        updateMessageStatus(messageId: message.id, status: .failed)
                        errorMessage = "Failed to send message: \(error.localizedDescription)"
                        isSending = false
                    }
                }
            }

        } catch {
            Log.error("❌ Failed to encrypt message: \(error)", category: "ChatViewModel")
            errorMessage = "Failed to encrypt message"
            isSending = false
        }
    }

    private func saveMessage(_ message: ChatMessage, decryptedContent: String, isSentByMe: Bool, status: DeliveryStatus, replyTo: Message? = nil, localThumbnails: [Data] = [], suiteId: UInt16) {
        // ✅ REFACTOR: Use MessagePersistenceService
        do {
            let isNewMessage = try persistenceService.saveMessage(
                message,
                decryptedContent: decryptedContent,
                isSentByMe: isSentByMe,
                status: status,
                chat: chat,
                replyTo: replyTo,
                localThumbnails: localThumbnails,
                suiteId: suiteId,
                in: viewContext
            )
            
            // ✅ REFACTOR: FRC will automatically update messages array via delegate
            Log.debug("📊 Messages will be updated by FRC. Current count: \(messages.count), isNew: \(isNewMessage)", category: "ChatViewModel")
        } catch {
            Log.error("Failed to save message: \(error.localizedDescription)", category: "ChatViewModel")
        }
    }

    private func updateMessageStatus(messageId: String, status: DeliveryStatus) {
        do {
            try persistenceService.updateMessageStatus(messageId: messageId, status: status, in: viewContext)
        } catch {
            Log.error("❌ Failed to save message status: \(error)", category: "ChatViewModel")
        }
    }
}

// MARK: - NSFetchedResultsControllerDelegate

extension ChatViewModel: NSFetchedResultsControllerDelegate {
    /// Called when FRC finishes processing changes to Core Data
    nonisolated func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        // ✅ FIX: Synchronous update to prevent UI rendering deleted objects
        // MainActor.assumeIsolated is safe here because FRC calls this on main thread
        MainActor.assumeIsolated {
            // ✅ REFACTOR: Automatic sync from Core Data - reverse to oldest-first
            let fetchedMessages = controller.fetchedObjects as? [Message] ?? []
            self.messages = Array(fetchedMessages.reversed())
            Log.debug("🔄 FRC updated messages: \(self.messages.count) total (reversed to oldest-first)", category: "ChatViewModel")
            
            // Update pagination tracking (first = oldest after reversal)
            if let first = self.messages.first {
                self.oldestLoadedTimestamp = first.timestamp
            }
            self.allLoadedMessageIds = Set(self.messages.map { $0.id })
        }
    }
}
