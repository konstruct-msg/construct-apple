import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif
import os.log
import GRPCCore
import SwiftProtobuf

// MARK: - Message Queue Models

/// Represents a message queued for sending when session is not ready
struct QueuedMessage {
    let text: String
    let images: [PlatformImage]
    let replyTo: Message?
    let timestamp: Date
    
    init(text: String, images: [PlatformImage] = [], replyTo: Message? = nil) {
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
    var isLoadingMore = false
    var hasMoreMessages = true
    var editingMessage: Message?
    /// Set to true when the server rejects a message with ERROR_CODE_BLOCKED.
    /// The UI should show a one-time banner (e.g. "You have been blocked by this user").
    /// Reset to false after the UI has consumed it.
    var blockedByRecipient = false

    // ✅ FIXED: Track session initialization state
    var isSessionReady = false
    var isInitializingSession = false  // NEW: Show UI indicator

    // ✅ REFACTORED: Enhanced message queue with full support
    private var queuedMessages: [QueuedMessage] = []
    
    // ✅ NEW: Track public key fetch timeout
    private var publicKeyFetchTimer: Timer?
    private let publicKeyFetchTimeout: TimeInterval = 10.0 // 10 seconds timeout
    
    // ✅ Pagination support - optimized for performance
    private let initialMessageLimit = 30  // Load 30 most recent messages initially
    private let loadMoreBatchSize = 20     // Load 20 older messages per "load more" request
    private var oldestLoadedTimestamp: Date?
    private var allLoadedMessageIds: Set<String> = []

    /// Shared predicate that excludes all session-handshake control signals.
    /// Applied by the FRC, older-message pagination, and hasMoreMessages check
    /// so control messages never appear anywhere in the conversation view.
    ///
    /// Primary filter: `contentTypeRaw == 0` (MessageContentType.regular) for all
    /// messages written by v2+ of the schema.
    /// Fallback string-prefix guards cover legacy DB rows that predate contentTypeRaw
    /// (their contentTypeRaw is nil/0, but decryptedContent may contain control sentinels
    /// that leaked before the system-message gate was enforced).
    static let controlMessageFilterPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: "contentTypeRaw == 0"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__session_ready')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH 'session_ready_')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__session_ping')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__END_SESSION')"),
        NSPredicate(format: "NOT (decryptedContent BEGINSWITH '__binary_init_')")
    ])

    let chat: Chat
    private var recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data)?

    private let connectionStatusManager = ConnectionStatusManager.shared
    private let messageQueueManager = MessageQueueManager.shared
    private var observationTasks: [Task<Void, Never>] = []
    private var viewContext: NSManagedObjectContext

    // ✅ FIX: Use NSFetchedResultsController for automatic Core Data updates
    private var fetchedResultsController: NSFetchedResultsController<Message>?
    /// Pending debounce task for FRC updates. Multiple rapid Core Data saves (e.g. after
    /// sending a message: insert + updateChatMetadata + status update) fire
    /// controllerDidChangeContent many times in quick succession. We coalesce them into
    /// a single UI refresh after a short idle window to avoid dozens of SwiftUI redraws.
    private var frcDebounceTask: Task<Void, Never>?
    
    // ✅ REFACTOR: Extracted services
    private let sessionInitService = SessionInitializationService.shared
    private let persistenceService = MessagePersistenceService()
    private let mediaUploadManager = MediaUploadManager()
    private let retryManager = MessageRetryManager.shared

    // MARK: - Pending media uploads
    // Maps placeholder message-ID → the original payload so retryMessage() can
    // re-launch the upload instead of trying to re-encrypt an empty placeholder.
    private struct MediaUploadPayload {
        let images: [PlatformImage]
        let fileURLs: [URL]
        let caption: String
        let replyTo: Message?
    }
    private var pendingMediaUploads: [String: MediaUploadPayload] = [:]

    /// Unique per-instance ID used to guard InAppNotificationService ownership.
    private let instanceID = UUID()

    init(chat: Chat, context: NSManagedObjectContext) {
        self.chat = chat
        self.viewContext = context
        
        super.init()  // ✅ REFACTOR: NSObject requires super.init()
        
        Log.debug("🔧 ChatViewModel init: chat.id=\(chat.id), chat.otherUser?.id=\(chat.otherUser?.id ?? "nil"), chat.otherUser?.username=\(chat.otherUser?.username ?? "nil")", category: "ChatViewModel")

        setupFetchedResultsController()  // ✅ Setup FRC - loads initial messages automatically
        setupSubscribers()
        checkExistingSession()  // ✅ FIXED: Check if session already exists
        // fetchRecipientPublicKey() is intentionally NOT called here.
        // ChatView.init (and therefore this init) is invoked on every SwiftUI parent re-render
        // due to the @State(wrappedValue:) pattern — hundreds of times per session.
        // The gRPC bundle fetch is deferred to onViewAppear() which fires only once per
        // actual view appearance, eliminating spurious gRPC channel creation.

        // ❌ REMOVED: loadMessages() - FRC already loaded messages in setupFetchedResultsController()
        Log.debug("🔧 ChatViewModel initialized with viewContext", category: "ChatViewModel")
        
        // Listen for queued messages processing
        setupMessageQueueListener()

        // Suppress in-app banners while this chat is open.
        // Uses instanceID so a discarded SwiftUI-diffing copy's deinit can't clear it.
        InAppNotificationService.shared.registerActiveChat(chat.id, ownerID: instanceID)
    }

    isolated deinit {
        publicKeyFetchTimer?.invalidate()
        observationTasks.forEach { $0.cancel() }
        InAppNotificationService.shared.unregisterActiveChat(ownerID: instanceID)
        Log.debug("🔧 ChatViewModel deinitialized", category: "ChatViewModel")
    }

    private func setupFetchedResultsController() {
        let fetchRequest = Message.fetchRequest()
        // Combine with additional predicate
        let chatPredicate = NSPredicate(format: "chat == %@", chat)
        // Exclude session-handshake control signals that should never appear in the message list.
        let noControlPredicate = ChatViewModel.controlMessageFilterPredicate
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate, noControlPredicate])
        
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
        // Listen for connection status changes using @Observable tracking.
        // IMPORTANT: guard let self is inside the loop so the strong binding is
        // released on every suspension point (await). This breaks the retain cycle
        // that the original guard-before-loop created, allowing deinit to fire.
        let connTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.connectionStatusManager.connectionStatus
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                if self.connectionStatusManager.connectionStatus == .connected {
                    Log.info("✅ Network connected - processing queued messages", category: "ChatViewModel")
                    self.sendQueuedMessages()
                }
            }
        }
        observationTasks.append(connTask)
    }
    
    private func setupMessageQueueListener() {
        // Listen for queued messages processing requests
        let queueTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .processQueuedMessages) {
                self?.sendQueuedMessages()
            }
        }
        observationTasks.append(queueTask)
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

    // Called by ChatView.onAppear — deferred from init to avoid hundreds of gRPC calls.
    func onViewAppear() {
        fetchRecipientPublicKey()
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
            ErrorRouter.shared.report(.validation(.selfSend))
            Log.debug("Blocked attempt to initialize session with self", category: "ChatViewModel")
            return
        }

        // Don't fetch if session already exists AND we already know the display name.
        // Username might be empty for contacts restored from cache — always fetch in that case.
        let hasUsername = !(chat.otherUser?.username ?? "").isEmpty
        if isSessionReady && hasUsername {
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
                    ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                        self?.fetchRecipientPublicKey()
                    })
                    self.isSessionReady = false
                }
            }
        }

        // ✅ REFACTOR: Use SessionInitializationService with retry
        Task { [weak self] in
            guard let self else { return }
            do {
                let publicKeyBundle = try await sessionInitService.fetchPublicKeyWithRetry(userId: userId)
                
                await MainActor.run { [weak self] in
                    self?.handlePublicKeyBundle(publicKeyBundle)
                }
            } catch {
                await MainActor.run { [weak self] in
                    Log.error("❌ Failed to fetch public key via gRPC after retries: \(error.localizedDescription)", category: "ChatViewModel")
                    ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                        self?.fetchRecipientPublicKey()
                    })
                    self?.isSessionReady = false
                }
            }
        }
    }
    
    /// Silently refresh the contact's username from the server in the background.
    /// Called when a session already exists so the full bundle fetch is skipped,
    // refreshUsernameInBackground removed — server no longer returns plaintext username.
    // Username comes from invite payload (un field) or profile sharing only.

    private func handlePublicKeyBundle(_ data: PublicKeyBundleData) {
        Log.debug("📦 Received publicKeyBundle for userId: \(data.userId), chat.otherUser?.id: \(chat.otherUser?.id ?? "nil"), match: \(data.userId == chat.otherUser?.id)", category: "ChatViewModel")
        guard data.userId == chat.otherUser?.id else { return }

        // Username comes from invite payload or profile sharing — server bundle carries no username.
        // Cache the bundle for use when the user actually sends a message.
        // Do NOT create an INITIATOR session here — proactively initialising a session
        // while the remote side may already be mid-ratchet (messageNumber > 0) causes
        // AEAD failures → heal_impossible → END_SESSION notification loop.
        // Session creation as INITIATOR happens on-demand inside sendMessage/initializeSessionProactively.
        self.recipientBundle = (data.identityPublic, data.signedPrekeyPublic, data.signature, data.verifyingKey)

        // If a RECEIVER session was already created by ChatsViewModel (incoming message arrived
        // while we were fetching the bundle), mark as ready so the UI reflects that.
        // Bundle is ready — cancel the fetch timer regardless of whether a session exists yet.
        // For RESPONDER-role contacts the session is created on first send; the bundle cache
        // is sufficient to enable sending, so mark the channel as ready now.
        publicKeyFetchTimer?.invalidate()
        publicKeyFetchTimer = nil
        isSessionReady = true

        if CryptoManager.shared.hasSession(for: data.userId) {
            Log.info("✅ SESSION_STATE[bundle_fetched_session_exists]: session already established for \(data.userId.prefix(8))…", category: "ChatViewModel")
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
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        let noControlPredicate = ChatViewModel.controlMessageFilterPredicate
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate, noControlPredicate])
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
        let chatPredicate = NSPredicate(format: "chat == %@ AND timestamp < %@", chat, oldestTimestamp as NSDate)
        let noControlPredicate = ChatViewModel.controlMessageFilterPredicate
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate, noControlPredicate])
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

                // Send ping as msgNum=0 first, then user messages as msgNum=1+.
                // This ensures initReceivingSession on the peer side gets a UTF-8
                // ping (which it can convert to String), not a binary protobuf payload.
                Task { [weak self] in
                    guard let self else { return }
                    await self.sendSessionInitPing(to: userId)
                    await self.sendQueuedMessages(userId: userId)
                }
            },
            onFailure: { [weak self] error in
                guard let self = self else { return }
                self.isInitializingSession = false
                // coreNotInitialized is fatal — no recovery until the user re-registers.
                if case CryptoManagerError.coreNotInitialized = error {
                    Log.error("🚨 coreNotInitialized in initializeSessionProactively — OrchestratorCore missing", category: "ChatViewModel")
                    ErrorRouter.shared.report(error)
                    self.failQueuedMessages(reason: error.userFacingMessage)
                    return
                }
                ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                    self?.fetchRecipientPublicKey()
                })

                // Mark queued messages as failed
                self.failQueuedMessages(reason: error.userFacingMessage)
            }
        )
    }
    
    /// Send a session-init ping as the first DR message (msgNum=0).
    ///
    /// The receiver's `init_receiving_session` expects the first message to be convertible
    /// to a UTF-8 String. If we send a binary user message as msgNum=0 the Rust FFI does
    /// `String::from_utf8(plaintext)` → DecryptionFailed, the session is torn down, and the
    /// user's first message is permanently lost.  Sending an ASCII ping as msgNum=0 makes
    /// `init_receiving_session` succeed; the receiver's `saveMessage` already silently drops
    /// it (`"__session_ping_*__"` guard).  Real user messages then start at msgNum=1.
    private func sendSessionInitPing(to userId: String) async {
        guard CryptoManager.shared.hasSession(for: userId) else { return }
        guard let myId = SessionManager.shared.currentUserId, !myId.isEmpty else { return }

        let pingId = UUID().uuidString.lowercased()
        let pingContent = "__session_ping_\(UUID().uuidString)__"

        do {
            let payload = try MessageRouter.shared.encryptSessionControl(
                plaintext: pingContent,
                messageId: pingId,
                recipientId: userId
            )
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: pingId,
                recipientId: userId,
                senderId: myId,
                conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                encryptedPayload: payload,
                timestamp: UInt64(Date().timeIntervalSince1970)
            )
            Log.info("🏓 SESSION_STATE[init_ping_sent]: msgNum=0 ping sent to \(userId.prefix(8))… — user messages follow as msgNum=1+", category: "SessionInit")
        } catch {
            Log.error("⚠️ SESSION_STATE[init_ping_failed]: \(error.localizedDescription) for \(userId.prefix(8))… — user messages will be sent anyway", category: "SessionInit")
            // Non-fatal: send user messages even if the ping failed. The old bug (message loss)
            // can only re-occur if the ping fails AND the peer's Rust version does utf-8 check.
        }
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
    
    /// Mark all queued messages as failed and persist them to CoreData so user can see them
    private func failQueuedMessages(reason: String) {
        Log.error("❌ Failing \(queuedMessages.count) queued messages: \(reason)", category: "ChatViewModel")
        guard !queuedMessages.isEmpty else { return }
        guard let currentUserId = SessionManager.shared.currentUserId,
              let recipientId = chat.otherUser?.id else {
            queuedMessages.removeAll()
            return
        }
        for queued in queuedMessages {
            let msg = Message(context: viewContext)
            msg.id = UUID().uuidString
            msg.fromUserId = currentUserId
            msg.toUserId = recipientId
            msg.contentType = .regular
            msg.timestamp = queued.timestamp
            msg.deliveryStatus = .failed
            msg.isSentByMe = true
            msg.chat = chat
            msg.applyStoredEncryption(plaintext: queued.text, contactId: recipientId)
        }
        viewContext.saveAndLog()
        queuedMessages.removeAll()
    }

    // MARK: - Send Message
    func sendMessage(text: String, images: [PlatformImage] = [], fileURLs: [URL] = [], replyTo: Message? = nil, replyToContentOverride: String? = nil) {
        Log.info("📤 sendMessage called with \(images.count) images, \(fileURLs.count) files", category: "ChatViewModel")

        // Normalise: strip leading/trailing whitespace before any further processing.
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Auto-split oversized plain-text pastes into sequential messages.
        // Only the first chunk carries the replyTo context; subsequent ones are independent.
        if images.isEmpty && fileURLs.isEmpty && text.count > MessageSizeLimits.maxTextCharacters {
            let chunks = MessageValidator.splitIntoChunks(text)
            Log.info("📋 Long paste split into \(chunks.count) messages", category: "ChatViewModel")
            for (index, chunk) in chunks.enumerated() {
                sendMessage(text: chunk,
                            replyTo: index == 0 ? replyTo : nil,
                            replyToContentOverride: index == 0 ? replyToContentOverride : nil)
            }
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
        // 🚫 BLOCK: Cannot send encrypted messages to yourself
        guard recipientId != currentUserId else {
            ErrorRouter.shared.report(.validation(.selfSend))
            Log.debug("❌ Blocked attempt to send message to self", category: "ChatViewModel")
            return
        }

        // Session check applies to ALL send paths (text, media, files).
        let hasSession = CryptoManager.shared.hasSession(for: recipientId)
        if !hasSession {
            let queued = QueuedMessage(text: text, images: images, replyTo: replyTo)
            queuedMessages.append(queued)
            isInitializingSession = true
            Log.info("📝 SESSION_STATE[queue_message]: userId=\(recipientId.prefix(8))..., queueSize=\(queuedMessages.count)", category: "SessionInit")
            Task { [weak self] in
                await self?.initializeSessionProactively(userId: recipientId)
            }
            return
        }

        // Two-phase handshake: if we are the INITIATOR and haven't received session_ready
        // from the RESPONDER yet, buffer the message as .queued. SessionCoordinator will
        // call MessageRetryManager.sendQueuedMessages once session_ready arrives.
        if SessionConfirmationTracker.shared.isPending(recipientId) {
            let bufferedId = UUID().uuidString
            let stub = ChatMessage(
                id: bufferedId,
                from: currentUserId,
                to: recipientId,
                messageType: nil,
                ephemeralPublicKey: Data(),
                messageNumber: 0,
                content: Data(),
                suiteId: 0,
                timestamp: UInt64(Date().timeIntervalSince1970)
            )
            saveMessage(stub, decryptedContent: text, isSentByMe: true, status: .queued,
                        replyTo: replyTo, replyToContentOverride: replyToContentOverride, suiteId: 0)
            Log.info("🔒 SESSION_CONFIRM[buffered]: message \(bufferedId.prefix(8))… queued — waiting for RESPONDER session_ready from \(recipientId.prefix(8))…", category: "SessionConfirm")
            return
        }

        Log.info("📤 Sending to: \(recipientId), from: \(currentUserId)", category: "ChatViewModel")

        // Pre-flight: if this contact has been silent for >6h, check session health before
        // spending an encryption attempt. Returns true immediately when activity is recent.
        // If session is unhealthy (e.g. skipped-key count too high), preflight triggers reinit
        // and we queue the message for delivery after the new session is ready.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await SessionActivityTracker.shared.preflight(for: recipientId)
            guard ok else {
                let queued = QueuedMessage(text: text, images: images, replyTo: replyTo)
                self.queuedMessages.append(queued)
                self.isInitializingSession = true
                Log.info("⏳ Pre-flight failed — message queued, triggering proactive reinit for \(recipientId.prefix(8))…", category: "ChatViewModel")
                await self.initializeSessionProactively(userId: recipientId)
                return
            }
            self.dispatchSend(text: text, images: images, fileURLs: fileURLs,
                              replyTo: replyTo, replyToContentOverride: replyToContentOverride)
        }
    }

    /// Validate and dispatch a message to the appropriate send path (file / media / text).
    /// Called after preflight confirms the session is healthy.
    private func dispatchSend(
        text: String,
        images: [PlatformImage],
        fileURLs: [URL],
        replyTo: Message?,
        replyToContentOverride: String?
    ) {
        // Handle files if provided (document attachments)
        if !fileURLs.isEmpty {
            do {
                try MessageValidator.validateMessage(text: text, fileURLs: fileURLs)
            } catch let error as MessageValidationError {
                ErrorRouter.shared.report(error)
                Log.error("❌ File message validation failed: \(error.localizedDescription)", category: "ChatViewModel")
                return
            } catch {
                ErrorRouter.shared.report(.unknown(error.userFacingMessage))
                Log.error("❌ Unexpected file validation error: \(error)", category: "ChatViewModel")
                return
            }
            sendFileMessage(fileURLs: fileURLs, caption: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
            return
        }

        // Handle images if provided
        if !images.isEmpty {
            do {
                try MessageValidator.validateCaption(text)
            } catch let error as MessageValidationError {
                ErrorRouter.shared.report(error)
                Log.error("❌ Caption validation failed: \(error.localizedDescription)", category: "ChatViewModel")
                return
            } catch {
                ErrorRouter.shared.report(.unknown(error.userFacingMessage))
                return
            }
            sendMediaMessage(images: images, caption: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
            return
        }

        // Validate text before delegating — media/file paths skip this since content is already encoded
        do {
            try MessageValidator.validateText(text)
        } catch let error as MessageValidationError {
            ErrorRouter.shared.report(error)
            Log.error("❌ Message validation failed: \(error.localizedDescription)", category: "ChatViewModel")
            return
        } catch {
            ErrorRouter.shared.report(.unknown(error.userFacingMessage))
            Log.error("❌ Unexpected validation error: \(error)", category: "ChatViewModel")
            return
        }

        sendTextMessage(text: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
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
        // If this is a failed upload placeholder, re-launch the upload instead of
        // trying to re-encrypt an empty placeholder via retryManager.
        if let payload = pendingMediaUploads[message.id] {
            pendingMediaUploads.removeValue(forKey: message.id)
            persistenceService.deleteMessage(id: message.id, in: viewContext)
            if !payload.images.isEmpty {
                sendMediaMessage(images: payload.images, caption: payload.caption, replyTo: payload.replyTo)
            } else {
                sendFileMessage(fileURLs: payload.fileURLs, caption: payload.caption, replyTo: payload.replyTo)
            }
            return
        }

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
                guard let self else { return }
                if error == "payload_expired" {
                    let text = message.displayText
                    guard !text.isEmpty else { return }
                    Log.info("🔁 Retry: payload expired — sending '\(text.prefix(20))…' as fresh message", category: "ChatViewModel")
                    self.sendTextMessage(text: text, replyTo: nil)
                } else {
                    ErrorRouter.shared.report(.unknown(error))
                }
            }
        )
    }

    // ✅ NOTE: Using gRPC for all messaging
    // Incoming messages are received via long polling in ChatsViewModel
    // and saved to Core Data, then picked up via NSManagedObjectContextObjectsDidChange
    // ACKs are received from gRPC SendMessage response

    // MARK: - Core Data Operations
    // MARK: - Media Messages

    private func sendMediaMessage(images: [PlatformImage], caption: String, replyTo: Message?, replyToContentOverride: String? = nil) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ No recipient/user ID for media message", category: "ChatViewModel")
            ErrorRouter.shared.report(.unknown("Cannot send media: no recipient"))
            return
        }
        // Note: session existence is already guaranteed by sendMessage() before this is called.

        // 1. Generate a local thumbnail and save a placeholder bubble immediately so the
        //    user sees the image in the chat even before the upload completes.
        let placeholderId = UUID().uuidString
        let thumbnail: Data? = images.first.flatMap { MediaManager.shared.generateThumbnail(from: $0) }
        persistenceService.savePlaceholderMessage(
            id: placeholderId,
            fromUserId: currentUserId,
            toUserId: recipientId,
            caption: caption,
            thumbnail: thumbnail,
            replyTo: replyTo,
            replyToContentOverride: replyToContentOverride,
            chat: chat,
            in: viewContext
        )

        // 2. Track the payload for retry support.
        pendingMediaUploads[placeholderId] = MediaUploadPayload(
            images: images, fileURLs: [], caption: caption, replyTo: replyTo)

        isSending = true
        Log.info("📤 Uploading \(images.count) image(s) (placeholder \(placeholderId.prefix(8))…)", category: "ChatViewModel")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await mediaUploadManager.uploadMediaAndBuildContent(
                    images: images,
                    caption: caption,
                    recipientId: recipientId
                )

                await MainActor.run {
                    // 3a. Upload succeeded — delete placeholder and send the real message.
                    // Use autoSave:false so the delete and the new message insertion are
                    // batched into a single Core Data save (and single FRC notification),
                    // avoiding a window where SwiftUI tries to render the deleted object.
                    self.pendingMediaUploads.removeValue(forKey: placeholderId)
                    self.persistenceService.deleteMessage(id: placeholderId, in: self.viewContext, autoSave: false)
                    self.sendTextMessage(text: result.messageContent, replyTo: replyTo, replyToContentOverride: replyToContentOverride, localThumbnails: result.thumbnails)
                }
            } catch {
                await MainActor.run {
                    // 3b. Upload failed — mark placeholder as failed so the user sees the
                    //     red "!" badge and the context-menu retry option.
                    Log.error("❌ Media upload failed: \(error.localizedDescription) | raw: \(error)", category: "ChatViewModel")
                    self.updateMessageStatus(messageId: placeholderId, status: .failed)
                    // pendingMediaUploads[placeholderId] stays so retryMessage() can reuse it.
                    ErrorRouter.shared.report(
                        AppError.mediaUploadFailed(error.localizedDescription),
                        recovery: { [weak self] in
                            self?.retryMessage_byId(placeholderId)
                        }
                    )
                    self.isSending = false
                }
            }
        }
    }

    func sendVoiceMessage(url: URL, duration: TimeInterval, waveform: [Float]) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = SessionManager.shared.currentUserId else {
            Log.error("❌ No recipient/user ID for voice message", category: "ChatViewModel")
            return
        }

        let placeholderId = UUID().uuidString
        persistenceService.saveVoicePlaceholderMessage(
            id: placeholderId,
            fromUserId: currentUserId,
            toUserId: recipientId,
            duration: duration,
            waveform: waveform,
            chat: chat,
            in: viewContext
        )

        isSending = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let voiceContent = try await MediaManager.shared.uploadAudio(url, duration: duration, waveform: waveform)
                let jsonData = try JSONEncoder().encode(voiceContent)
                guard let json = String(data: jsonData, encoding: .utf8) else {
                    throw MediaUploadError.uploadFailed("JSON encode failed")
                }
                await MainActor.run {
                    try? FileManager.default.removeItem(at: url)
                    self.persistenceService.deleteMessage(id: placeholderId, in: self.viewContext, autoSave: false)
                    self.sendTextMessage(text: json, replyTo: nil)
                }
            } catch {
                await MainActor.run {
                    Log.error("❌ Voice upload failed: \(error.localizedDescription)", category: "ChatViewModel")
                    self.updateMessageStatus(messageId: placeholderId, status: .failed)
                    ErrorRouter.shared.report(AppError.mediaUploadFailed(error.localizedDescription))
                    self.isSending = false
                }
            }
        }
    }

    private func sendFileMessage(fileURLs: [URL], caption: String, replyTo: Message?, replyToContentOverride: String? = nil) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = SessionManager.shared.currentUserId else {
            isSending = false
            return
        }

        // 1. Save a placeholder so the file appears in chat immediately.
        let placeholderId = UUID().uuidString
        persistenceService.savePlaceholderMessage(
            id: placeholderId,
            fromUserId: currentUserId,
            toUserId: recipientId,
            caption: caption.isEmpty ? (fileURLs.first?.lastPathComponent ?? "File") : caption,
            thumbnail: nil,
            replyTo: replyTo,
            replyToContentOverride: replyToContentOverride,
            chat: chat,
            in: viewContext
        )
        pendingMediaUploads[placeholderId] = MediaUploadPayload(
            images: [], fileURLs: fileURLs, caption: caption, replyTo: replyTo)

        isSending = true
        Log.info("📎 Uploading \(fileURLs.count) file(s) (placeholder \(placeholderId.prefix(8))…)", category: "ChatViewModel")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await mediaUploadManager.uploadFilesAndBuildContent(
                    urls: fileURLs,
                    caption: caption
                )
                await MainActor.run {
                    self.pendingMediaUploads.removeValue(forKey: placeholderId)
                    self.persistenceService.deleteMessage(id: placeholderId, in: self.viewContext, autoSave: false)
                    self.sendTextMessage(text: result.messageContent, replyTo: replyTo, replyToContentOverride: replyToContentOverride)
                }
            } catch {
                await MainActor.run {
                    Log.error("❌ File upload failed: \(error.localizedDescription)", category: "ChatViewModel")
                    self.updateMessageStatus(messageId: placeholderId, status: .failed)
                    ErrorRouter.shared.report(
                        AppError.mediaUploadFailed(error.localizedDescription),
                        recovery: { [weak self] in
                            self?.retryMessage_byId(placeholderId)
                        }
                    )
                    self.isSending = false
                }
            }
        }
    }

    // MARK: - Core Text Delivery
    // All send paths (text, media, files, voice) ultimately call this method.
    // It is the single place that encrypts, attaches PQXDH KEM ciphertext, sends chunks,
    // maps server status, and handles session recovery on encryption failure.

    /// Retry a media upload / file upload placeholder by its message ID.
    /// Used by both the ErrorToast "Retry" button and `retryMessage(_:)`.
    private func retryMessage_byId(_ messageId: String) {
        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
        fetchRequest.fetchLimit = 1
        guard let msg = try? viewContext.fetch(fetchRequest).first else { return }
        retryMessage(msg)
    }

    private func sendTextMessage(text: String, replyTo: Message?, replyToContentOverride: String? = nil, localThumbnails: [Data] = []) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = SessionManager.shared.currentUserId else {
            isSending = false
            return
        }

        isSending = true

        do {
            let messageId = UUID().uuidString.lowercased()

            // Build MessageContent proto — embeds reply reference inside ciphertext (private, not in envelope).
            var textMsg = Shared_Proto_Messaging_V1_TextMessage()
            textMsg.text = text
            if let reply = replyTo {
                var quoted = Shared_Proto_Messaging_V1_QuotedMessage()
                quoted.messageID = reply.id
                quoted.textPreview = replyToContentOverride ?? reply.displayText
                textMsg.quoted = quoted
            }
            var content = Shared_Proto_Messaging_V1_MessageContent()
            content.text = textMsg
            guard let plaintextData = try? content.serializedData(), !plaintextData.isEmpty else {
                Log.error("❌ Failed to serialize MessageContent proto", category: "ChatViewModel")
                isSending = false
                return
            }

            let plan = ChunkedMessageSender.shared.buildPlan(plaintext: plaintextData, messageId: UUID(uuidString: messageId) ?? UUID())
            guard !plan.payloads.isEmpty else {
                Log.error("❌ Message too large to send", category: "ChatViewModel")
                isSending = false
                ErrorRouter.shared.report(.validation(.textTooLarge(currentSize: text.count, maxSize: MessageSizeLimits.maxTextCharacters)))
                return
            }
            let message = ChatMessage(
                id: messageId,
                from: currentUserId,
                to: recipientId,
                messageType: nil,
                ephemeralPublicKey: Data(),
                messageNumber: 0,
                content: Data(),
                suiteId: 0,
                timestamp: UInt64(Date().timeIntervalSince1970),
                oneTimePreKeyId: 0
            )

            Log.debug("📤 Sending message with ID: \(messageId)", category: "ChatViewModel")

            saveMessage(message, decryptedContent: text, isSentByMe: true, status: .sending, replyTo: replyTo, replyToContentOverride: replyToContentOverride, localThumbnails: localThumbnails, suiteId: 0)

            Log.info("📮 Sending message via gRPC: \(messageId)", category: "ChatViewModel")
            Task { [weak self] in
                guard let self else { return }
                let jitterMs = TrafficProtectionService.shared.recommendedSendDelay(isHighPriority: true)
                if jitterMs > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(jitterMs)))
                }

                do {
                    let aggregated = try await OutboundMessagePipeline.shared.sendChunks(
                        plan: plan,
                        baseMessageId: messageId,
                        senderId: currentUserId,
                        recipientId: recipientId,
                        conversationId: ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId),
                        timestamp: message.timestamp,
                        recipientIdentityKey: UserDefaults.standard.bool(forKey: "stealth_mode_enabled")
                            ? self.recipientBundle?.identityPublic
                            : nil
                    )

                    TrafficProtectionService.shared.recordRealMessageSent()

                    // SenderSync: fire-and-forget copy to own other devices.
                    // Fan-out to other recipient devices is handled in the coordinator.
                    if let myDeviceId = SessionManager.shared.currentDeviceId, !myDeviceId.isEmpty {
                        Task { [weak self] in
                            _ = self
                            await MultiDeviceSendCoordinator.shared.sendSenderSync(
                                plaintext: Data(text.utf8),
                                messageId: messageId,
                                originalRecipientUserId: recipientId,
                                senderUserId: currentUserId,
                                senderDeviceId: myDeviceId,
                                conversationId: ConversationId.direct(
                                    myUserId: currentUserId,
                                    theirUserId: recipientId
                                ),
                                timestamp: message.timestamp
                            )
                        }
                    }

                    await MainActor.run {
                        let deliveryStatus: DeliveryStatus
                        let ecStr = aggregated.errorCode.isEmpty ? "" : " errorCode=\(aggregated.errorCode)"
                        let raStr = aggregated.retryAfterMs > 0 ? " retryAfterMs=\(aggregated.retryAfterMs)" : ""
                        let traceTag = aggregated.attemptId.isEmpty ? "" : " attemptId=\(aggregated.attemptId.prefix(8))"
                        switch aggregated.status.lowercased() {
                        case "delivered": deliveryStatus = .delivered
                        case "queued":    deliveryStatus = .queued
                        case "sent", "success": deliveryStatus = .sent
                        case "blocked":
                            deliveryStatus = .failed
                            self.blockedByRecipient = true
                            Log.error("🚫 Message blocked by recipient — suppressing retry for \(messageId)\(traceTag)", category: "ChatViewModel")
                        case "failed":
                            if aggregated.errorCode == "encryptionFailed" {
                                // Server rejected our ciphertext — our DR state is desynced.
                                // Trigger END_SESSION so both sides re-init from scratch.
                                deliveryStatus = .failed
                                OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                                Log.error("🔐 encryptionFailed from server — triggering END_SESSION for \(self.chat.otherUser?.id.prefix(8) ?? "?")\(traceTag)", category: "ChatViewModel")
                                if let peerId = self.chat.otherUser?.id {
                                    Task {
                                        try? await SessionCoordinator().sendEndSession(
                                            to: peerId,
                                            reason: "server_encryption_rejected"
                                        )
                                    }
                                }
                            } else if aggregated.retryable {
                                deliveryStatus = .queued
                                Log.error("❌ Server rejected message \(messageId): retryable=true\(ecStr)\(raStr)\(traceTag) — queued for retry", category: "ChatViewModel")
                            } else {
                                deliveryStatus = .failed
                                OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                                Log.error("❌ Server rejected message \(messageId): retryable=false\(ecStr)\(traceTag)", category: "ChatViewModel")
                            }
                        default:
                            deliveryStatus = .sent
                            Log.info("⚠️ Unknown server status: \(aggregated.status), using .sent\(traceTag)", category: "ChatViewModel")
                        }
                        Log.info("🔄 Updating message status from sending → \(deliveryStatus) for \(messageId)\(traceTag)", category: "ChatViewModel")
                        self.updateMessageStatus(messageId: messageId, status: deliveryStatus)
                        if deliveryStatus == .sent || deliveryStatus == .delivered {
                            OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                        }
                        Log.info("✅ Message sent via gRPC: \(messageId) status=\(aggregated.status)\(ecStr)\(traceTag)", category: "ChatViewModel")
                        SessionActivityTracker.shared.recordActivity(for: recipientId)
                        self.isSending = false
                    }
                } catch {
                    await MainActor.run {
                        // Transport failures are ambiguous: the server may have accepted the message
                        // even if the client didn't receive the response (e.g. deadlineExceeded).
                        // Never re-encrypt on retry — instead queue and re-send the exact same wire
                        // payload bytes using the SAME messageId (OutgoingWirePayloadStore).
                        let isRetryableTransportFailure: Bool = {
                            if let rpcError = error as? RPCError {
                                let code = String(describing: rpcError.code).lowercased()
                                return code == "deadlineexceeded" || code == "unavailable" || code == "cancelled"
                            }
                            if let networkError = error as? NetworkError {
                                switch networkError {
                                case .connectionFailed, .disconnected, .notConnected:
                                    return true
                                default:
                                    return false
                                }
                            }
                            return false
                        }()

                        if let networkError = error as? NetworkError,
                           case .serverError(let message, let responseBody) = networkError {
                            Log.error("❌ Failed to send message via gRPC: \(message)\nResponse: \(responseBody ?? "empty")", category: "ChatViewModel")
                        } else if let rpcError = error as? RPCError {
                            Log.error("❌ SendMessage gRPC error: code=\(rpcError.code), message=\(rpcError.message)", category: "ChatViewModel")
                        } else {
                            Log.error("❌ Failed to send message: \(error)", category: "ChatViewModel")
                        }

                        if isRetryableTransportFailure {
                            Log.info("⏸️ Transport failure — queueing \(messageId.prefix(8))… for safe retry (same messageId, same wire payload)", category: "ChatViewModel")
                            self.updateMessageStatus(messageId: messageId, status: .queued)
                        } else {
                            self.updateMessageStatus(messageId: messageId, status: .failed)
                            OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
                            ErrorRouter.shared.report(error, recovery: { [weak self] in
                                self?.sendTextMessage(text: text, replyTo: replyTo, replyToContentOverride: replyToContentOverride, localThumbnails: localThumbnails)
                            })
                        }
                        self.isSending = false
                    }
                }
            }

        } catch {
            // coreNotInitialized is fatal — OrchestratorCore was never created (lost device keys).
            // Retrying will never succeed. Surface as non-recoverable error.
            if case CryptoManagerError.coreNotInitialized = error {
                Log.error("🚨 coreNotInitialized in sendTextMessage — OrchestratorCore missing, not retrying", category: "ChatViewModel")
                ErrorRouter.shared.report(error)
                isSending = false
                return
            }
            // Encryption failure = session likely corrupted; re-initialize and re-queue
            Log.debug("🔄 Encryption failed, session was deleted. Reinitializing...", category: "ChatViewModel")
            guard let toUserId = chat.otherUser?.id else {
                ErrorRouter.shared.report(error)
                Log.error("❌ Failed to encrypt message: \(error.localizedDescription)", category: "ChatViewModel")
                isSending = false
                return
            }
            isSessionReady = false
            let queued = QueuedMessage(text: text, images: [], replyTo: replyTo)
            queuedMessages.append(queued)
            isInitializingSession = true
            isSending = false
            Log.info("📝 Message queued for retry after session reinitialization", category: "ChatViewModel")
            Task { [weak self] in await self?.initializeSessionProactively(userId: toUserId) }
        }
    }

    // MARK: - Edit Message

    func editMessage(_ message: Message, newText: String) {
        guard let recipientId = chat.otherUser?.id,
              let currentUserId = SessionManager.shared.currentUserId else { return }
        let conversationId = ConversationId.direct(myUserId: currentUserId, theirUserId: recipientId)

        Task {
            do {
                let wirePayload = try MessageRouter.shared.encryptOutgoing(
                    plaintext: Data(newText.utf8),
                    messageId: message.id,
                    recipientId: recipientId
                )
                let response = try await MessagingServiceClient.shared.editMessage(
                    messageId: message.id,
                    conversationId: conversationId,
                    newEncryptedContent: wirePayload,
                    recipientUserId: recipientId
                )
                guard response.success else { return }
                await MainActor.run {
                    let editedDate = Date(timeIntervalSince1970: TimeInterval(response.editedAt))
                    self.persistenceService.updateMessageContent(
                        messageId: message.id,
                        newContent: newText,
                        isEdited: true,
                        editedAt: editedDate,
                        in: self.viewContext
                    )
                    self.editingMessage = nil
                }
            } catch {
                await MainActor.run {
                    ErrorRouter.shared.report(.unknown(String(format: NSLocalizedString("edit_message_failed", comment: ""), error.localizedDescription)))
                }
            }
        }
    }

    private func saveMessage(_ message: ChatMessage, decryptedContent: String, isSentByMe: Bool, status: DeliveryStatus, replyTo: Message? = nil, replyToContentOverride: String? = nil, localThumbnails: [Data] = [], suiteId: UInt16) {
        // ✅ REFACTOR: Use MessagePersistenceService
        do {
            let isNewMessage = try persistenceService.saveMessage(
                message,
                decryptedContent: decryptedContent,
                isSentByMe: isSentByMe,
                status: status,
                chat: chat,
                replyTo: replyTo,
                replyToContentOverride: replyToContentOverride,
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
        persistenceService.updateMessageStatus(messageId: messageId, status: status, in: viewContext)
    }
}

// MARK: - NSFetchedResultsControllerDelegate

extension ChatViewModel: NSFetchedResultsControllerDelegate {
    /// Called when FRC finishes processing changes to Core Data.
    /// Multiple rapid Core Data saves (insert → updateChatMetadata → status update) each
    /// fire this delegate. We cancel any pending debounce and schedule a fresh one so that
    /// the UI refresh happens only ONCE after the last save in a burst, instead of 10-20×.
    nonisolated func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.frcDebounceTask?.cancel()
            self.frcDebounceTask = Task { @MainActor [weak self] in
                // 40 ms idle window — short enough to feel instant, long enough to collapse
                // the typical burst of 5-20 saves that follows a single send/receive event.
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self else { return }
                self.applyFRCSnapshot(controller)
            }
        }
    }

    @MainActor
    private func applyFRCSnapshot(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
            // If the parent chat was deleted, clear messages and stop — accessing
            // properties on deleted Core Data objects crashes with EXC_BREAKPOINT.
            guard !self.chat.isDeleted, self.chat.managedObjectContext != nil else {
                self.messages = []
                return
            }

            // Helper: a message is only safe to use if its context is non-nil AND it isn't
            // marked deleted. Check managedObjectContext FIRST — it is not an @NSManaged
            // property and is safe on zombies. Only after that check @NSManaged properties
            // like .id or .timestamp, which throw on zombies.
            func isValid(_ msg: Message) -> Bool {
                msg.managedObjectContext != nil && !msg.isDeleted
            }

            let fetchedMessages = (controller.fetchedObjects as? [Message] ?? [])
                .filter { isValid($0) }
                .reversed() as [Message]

            let fetchedIds = Set(fetchedMessages.map { $0.id })

            // Keep historic messages loaded via pagination (not in current FRC window).
            // Guard validity before accessing $0.id to avoid zombie property access.
            let historicMessages = self.messages.filter {
                isValid($0) && !fetchedIds.contains($0.id)
            }

            self.messages = historicMessages + fetchedMessages
            Log.debug("🔄 FRC updated: \(fetchedMessages.count) recent + \(historicMessages.count) historic = \(self.messages.count) total", category: "ChatViewModel")

            if let first = self.messages.first, isValid(first) {
                self.oldestLoadedTimestamp = first.timestamp
            }
            self.allLoadedMessageIds = Set(self.messages.compactMap {
                isValid($0) ? $0.id : nil
            })
    }
}
