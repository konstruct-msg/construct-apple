//
//  BackgroundFetchManager.swift
//  Construct Messenger
//
//

import Foundation
#if os(iOS)
import BackgroundTasks
#endif
#if os(iOS)
import UIKit
#endif
import os.log
import CoreData

/// Manages background task scheduling and execution for message fetching
/// Uses BGTaskScheduler for intelligent, energy-efficient background operations
@Observable
class BackgroundFetchManager: NSObject {
    
    // MARK: - Task Identifiers
    
    /// BGAppRefreshTask identifier for periodic message checking (15-30 min intervals)
    static let messageRefreshTaskID = "com.construct.message-refresh"
    
    /// BGProcessingTask identifier for maintenance operations
    static let maintenanceTaskID = "com.construct.maintenance"
    
    // MARK: - Properties
    
    static let shared = BackgroundFetchManager()
    
    /// Energy monitor for battery and network checks
    private let energyMonitor = EnergyMonitor()
    
    // ✅ Using gRPC for fetching messages (WebSocket removed)
    
    /// Indicates if background fetch is enabled by user
    private(set) var isBackgroundFetchEnabled = false
    
    /// Last successful fetch timestamp
    private(set) var lastFetchDate: Date?
    
    /// Last fetch result
    private(set) var lastFetchResult: Result<Int, Error>?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        BackgroundFetchConfig.initializeDefaults()
        
        // Initialize enabled state from config
        isBackgroundFetchEnabled = BackgroundFetchConfig.shouldBeEnabled
        
        // Monitor Low Power Mode changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        
        Log.info("BackgroundFetchManager initialized", category: "BackgroundFetch")
    }
    
    @objc private func lowPowerModeChanged() {
        checkLowPowerMode()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Registration
    
    /// Register background tasks with BGTaskScheduler
    /// Must be called in AppDelegate application(_:didFinishLaunchingWithOptions:)
    /// BEFORE the app finishes launching
    func registerBackgroundTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.messageRefreshTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                Log.error("Invalid task type for message refresh", category: "BackgroundFetch")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleMessageRefresh(task: refreshTask)
        }
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.maintenanceTaskID,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                Log.error("Invalid task type for maintenance", category: "BackgroundFetch")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleMaintenance(task: processingTask)
        }
        Log.info("Background tasks registered successfully")
        #endif
    }
    
    // MARK: - Scheduling
    
    /// Schedule next background fetch task
    func scheduleBackgroundFetch() {
        #if os(iOS)
        guard BackgroundFetchConfig.shouldBeEnabled else {
            Log.info("Background fetch disabled (user setting or Low Power Mode)", category: "BackgroundFetch")
            cancelAllBackgroundTasks()
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.messageRefreshTaskID)
        let interval = BackgroundFetchConfig.interval
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("Background fetch scheduled (interval: \(Int(interval / 60)) min)", category: "BackgroundFetch")
        } catch {
            Log.error("Failed to schedule background fetch: \(error)", category: "BackgroundFetch")
        }
        #endif
    }
    
    /// Schedule maintenance task
    func scheduleMaintenanceTask() {
        #if os(iOS)
        let request = BGProcessingTaskRequest(identifier: Self.maintenanceTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("Maintenance task scheduled successfully")
        } catch {
            Log.error("Failed to schedule maintenance task: \(error)")
        }
        #endif
    }
    
    /// Cancel all scheduled background tasks
    func cancelAllBackgroundTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.messageRefreshTaskID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.maintenanceTaskID)
        #endif
        Log.info("All background tasks cancelled")
    }
    
    // MARK: - Task Handlers
    
    #if os(iOS)
    /// Handle BGAppRefreshTask for message fetching
    private func handleMessageRefresh(task: BGAppRefreshTask) {
        Log.info("Background message refresh started")
        
        // Schedule next refresh immediately
        scheduleBackgroundFetch()
        
        // Set expiration handler (iOS gives 30 seconds)
        task.expirationHandler = {
            Log.error("Background task expired")
            self.cleanupFetch()
            task.setTaskCompleted(success: false)
        }
        
        // Check if we should perform fetch (battery, network, etc.)
        guard energyMonitor.shouldPerformBackgroundFetch() else {
            Log.info("Skipping background fetch due to energy conditions")
            task.setTaskCompleted(success: true)
            return
        }
        
        // Perform the actual fetch with 20-second timeout
        performQuickMessageFetch { result in
            switch result {
            case .success(let messageCount):
                Log.info("Background fetch completed: \(messageCount) new messages")
                self.lastFetchDate = Date()
                self.lastFetchResult = .success(messageCount)
                task.setTaskCompleted(success: true)
                
            case .failure(let error):
                Log.error("Background fetch failed: \(error)")
                self.lastFetchResult = .failure(error)
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    /// Handle BGProcessingTask for maintenance operations
    private func handleMaintenance(task: BGProcessingTask) {
        Log.info("Maintenance task started")
        
        // Set expiration handler
        task.expirationHandler = {
            Log.error("Maintenance task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Perform maintenance operations
        performMaintenance { success in
            Log.info("Maintenance task completed: \(success)")
            task.setTaskCompleted(success: success)
            self.scheduleMaintenanceTask()
        }
    }
    #endif
    
    // MARK: - Fetch Logic
    
    /// Perform quick message fetch with connect-fetch-disconnect pattern
    /// Target execution time: 2-5 seconds
    private func performQuickMessageFetch(completion: @escaping (Result<Int, Error>) -> Void) {
        Log.info("Starting quick message fetch", category: "BackgroundFetch")
        
        // Check authentication
        guard GRPCAuthCache.shared.snapshot.token != nil else {
            Log.error("No session token available", category: "BackgroundFetch")
            completion(.failure(BackgroundFetchError.notAuthenticated))
            return
        }
        
        // Get Core Data context — use a standalone background context (not a child of viewContext)
        // to avoid triggering NSManagedObjectContextObjectsDidChange on the background thread,
        // which would fire FRC/Observable updates off the main thread (purple Xcode warning).
        let context = PersistenceController.shared.container.viewContext
        let backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundContext.persistentStoreCoordinator = context.persistentStoreCoordinator
        
        // Fetch pending messages via gRPC (unary, cursor-paginated)
        Task {
            do {
                var allMessages: [ChatMessage] = []
                var cursor: String? = nil

                repeat {
                    let result = try await MessagingServiceClient.shared.getPendingMessages(
                        sinceCursor: cursor,
                        limit: 50
                    )
                    allMessages.append(contentsOf: result.messages)
                    cursor = result.nextCursor

                    if !result.hasMore { break }
                } while true

                await MainActor.run { [allMessages] in
                    self.processOfflineMessages(allMessages, backgroundContext: backgroundContext, completion: completion)
                }
            } catch {
                Log.error("Failed to fetch offline messages: \(error.localizedDescription)", category: "BackgroundFetch")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    
    private func processOfflineMessages(_ messages: [ChatMessage], backgroundContext: NSManagedObjectContext, completion: @escaping (Result<Int, Error>) -> Void) {
        guard !messages.isEmpty else {
            completion(.success(0))
            return
        }
        
        Log.info("Processing \(messages.count) offline messages", category: "BackgroundFetch")
        
        // Get Core Data context for processing
        let context = PersistenceController.shared.container.viewContext
        
        // Process messages in background context
        backgroundContext.perform {
            var newMessagesCount = 0
            var messagesByChat: [String: [ChatMessage]] = [:]
            var chatUserIds: [String: String] = [:] // chatId -> userId
            
            guard let currentUserId = GRPCAuthCache.shared.snapshot.userId else {
                DispatchQueue.main.async {
                    completion(.failure(BackgroundFetchError.notAuthenticated))
                }
                return
            }
            
            // Group messages by chat (skip control messages — they are not user-visible)
            for message in messages {
                guard message.messageType != "CONTROL_MESSAGE" && message.messageType != "SENDER_SYNC" else {
                    Log.debug("Skipping control message \(message.id) (\(message.messageType ?? "nil")) in grouping phase", category: "BackgroundFetch")
                    continue
                }
                let otherUserId = message.from == currentUserId ? message.to : message.from

                // Skip messages from contacts that have been pruned. This must be the first
                // check after resolving otherUserId: pruneContact() already archives the
                // session and deletes User + Chat from Core Data. BackgroundFetch must not
                // recreate them, nor attempt decryption against a wiped session.
                guard !DeletedContactsStore.shared.isDeleted(otherUserId) else {
                    Log.debug("Skipping message \(message.id.prefix(8))… from pruned contact \(otherUserId.prefix(8))…", category: "BackgroundFetch")
                    continue
                }

                // Find or create chat
                let chatId = self.findOrCreateChat(
                    for: otherUserId,
                    in: backgroundContext,
                    currentUserId: currentUserId
                )
                
                if let chatId = chatId {
                    if messagesByChat[chatId] == nil {
                        messagesByChat[chatId] = []
                    }
                    messagesByChat[chatId]?.append(message)
                    chatUserIds[chatId] = otherUserId
                }
            }
            
            // ── Pass 1: Filter eligible messages ───────────────────────────────────────
            // Check Core Data + ACK guards per message, collect all eligible messages
            // with their chat/contact context so the batch decrypt can operate on them.
            var eligible: [(chatId: String, chat: Chat, otherUserId: String, messageData: ChatMessage)] = []

            for (chatId, chatMessages) in messagesByChat {
                guard let otherUserId = chatUserIds[chatId] else { continue }

                let chatFetch = Chat.fetchRequest()
                chatFetch.predicate = NSPredicate(format: "id == %@", chatId)
                guard let chat = try? backgroundContext.fetch(chatFetch).first else {
                    Log.error("Chat not found: \(chatId)", category: "BackgroundFetch")
                    continue
                }

                for messageData in chatMessages {
                    // Guard 1: Core Data dedup (survives app restart via ProcessedMessage entity).
                    let messageFetch = Message.fetchRequest()
                    messageFetch.predicate = NSPredicate(format: "id == %@", messageData.id)
                    if (try? backgroundContext.fetch(messageFetch).first) != nil { continue }

                    // Guard 2: RustAckStore in-memory cache — catches the race where the
                    // foreground stream called markProcessed but the save hasn't propagated.
                    if PersistentACKStore.shared.isProcessed(messageData.id, in: backgroundContext) {
                        Log.debug("BackgroundFetch: \(messageData.id.prefix(8))… already ACK'd, skipping", category: "BackgroundFetch")
                        continue
                    }

                    // Guard 3: Skip session-management control messages — the real-time
                    // stream handles these; decrypting them here would corrupt DR state.
                    if messageData.messageType == "CONTROL_MESSAGE" || messageData.messageType == "SENDER_SYNC" {
                        Log.debug("Skipping control message \(messageData.id) (\(messageData.messageType ?? "nil")) in BG fetch", category: "BackgroundFetch")
                        continue
                    }

                    eligible.append((chatId: chatId, chat: chat, otherUserId: otherUserId, messageData: messageData))
                }
            }

            // ── Batch decrypt ───────────────────────────────────────────────────────────
            // Restore sessions for unique contactIds (once per user, not once per message),
            // then call decryptOfflineBatch — a single Rust mutex acquisition for all messages.
            // No archiveSession is called on per-message failure; the foreground stream owns
            // all session recovery (END_SESSION, re-init, healing).
            var resultsByMessageId: [String: OfflineBatchDecryptResult] = [:]

            if !eligible.isEmpty {
                let uniqueUserIds = Set(eligible.map { $0.otherUserId })
                for userId in uniqueUserIds {
                    _ = DispatchQueue.main.sync { CryptoManager.shared.restoreSession(for: userId) }
                }

                let batchResults: [OfflineBatchDecryptResult] = DispatchQueue.main.sync {
                    CryptoManager.shared.decryptOfflineBatch(eligible.map { $0.messageData })
                }

                for result in batchResults {
                    resultsByMessageId[result.message.id] = result
                    if result.succeeded {
                        // Claim the message in the ACK cache before any Core Data write —
                        // closes the race window where the stream could re-decrypt the same msg.
                        PersistentACKStore.shared.preemptACK(result.message.id)
                        if !result.storageKey.isEmpty {
                            MessageKeyStore.shared.store(
                                messageId: result.message.id,
                                key: result.storageKey,
                                contactId: result.message.from
                            )
                        }
                    } else {
                        Log.info("BackgroundFetch: \(result.message.id.prefix(8))… decrypt failed — foreground stream will recover", category: "BackgroundFetch")
                    }
                }
            }

            // ── Pass 2: Post-decrypt processing and Core Data writes ────────────────────
            // Track per-chat last-message info (overwritten on each successful message so
            // the final successful message per chat wins — matches original behaviour).
            var lastDecryptedByChatId: [String: (text: String, timestamp: UInt64)] = [:]
            // Profile-share messages found in this batch — applied on the main actor after the
            // background save merges into viewContext (ProfileSharingManager is @MainActor and
            // operates on the viewContext). Routing these (and edits below) mirrors the live
            // stream's handleSpecialMessage; the batch path previously saved them as regular
            // rows, so profile updates and edits delivered via background fetch were never applied.
            var deferredProfileMessages: [(from: String, contentData: Data, legacyString: String?)] = []

            for item in eligible {
                // Ephemeral control/signaling messages are NOT chat content: call signals (12),
                // heartbeat (13), delivery receipt (14), webrtc (10), presence (11). The live
                // stream routes these via the orchestrator (callSignalDecrypted / receipt
                // handler / discard); the background batch path has no such routing and would
                // otherwise save them as a regular bubble whose non-text bytes render as
                // "Message not available". Consume (ACK) and skip — they are moot in the
                // background (e.g. an old call signal for a call that is already over), and
                // ACKing stops the server re-delivering a stuck, never-decryptable one.
                // Session-control types (20-24) are left to the foreground orchestrator.
                if (10...14).contains(item.messageData.contentType) {
                    PersistentACKStore.shared.markProcessed(item.messageData.id, senderId: item.messageData.from, in: backgroundContext)
                    continue
                }

                guard let batchResult = resultsByMessageId[item.messageData.id],
                      batchResult.succeeded else {
                    // Decrypt failed — do not create Message entity. The foreground stream
                    // will receive this message on next app foreground and handle recovery.
                    continue
                }

                var decryptedContent: Data? = batchResult.plaintext

                // Chunk messages: feed KNST-prefixed payloads to ChunkedMessageReassembler.
                let legacyPrefixBytes = Data(ChunkedMessageCodec.legacyPrefix.utf8)
                let binaryMagic = Data([0x4B, 0x4E, 0x53, 0x54]) // "KNST"
                if let dc = decryptedContent,
                   dc.starts(with: binaryMagic) || dc.starts(with: legacyPrefixBytes) {
                    var assembled: String? = nil
                    DispatchQueue.main.sync {
                        switch ChunkedMessageReassembler.shared.process(data: dc) {
                        case .assembled(let text, _): assembled = text
                        case .legacy(let text):        assembled = text
                        case .incomplete, .invalid:    break
                        }
                    }
                    PersistentACKStore.shared.markProcessed(item.messageData.id, senderId: item.messageData.from, in: backgroundContext)
                    if let text = assembled {
                        Log.debug("Chunk assembled in BG fetch \(item.messageData.id.prefix(8))", category: "BackgroundFetch")
                        decryptedContent = Data(text.utf8)
                    } else {
                        Log.debug("Chunk fragment \(item.messageData.id.prefix(8)) ACK'd; waiting for remaining chunks", category: "BackgroundFetch")
                        continue
                    }
                }

                let decryptedString = decryptedContent.flatMap { String(data: $0, encoding: .utf8) } ?? ""

                // Edit: update the original message in place instead of saving a new row.
                // editsMessageId is a wire-envelope field, so this is independent of content.
                if !item.messageData.editsMessageId.isEmpty {
                    let editsId = item.messageData.editsMessageId
                    let fr = Message.fetchRequest()
                    fr.predicate = NSPredicate(format: "id == %@", editsId)
                    fr.fetchLimit = 1
                    if let original = try? backgroundContext.fetch(fr).first {
                        original.applyStoredEncryption(plaintext: decryptedString, contactId: item.messageData.from)
                        original.isEdited = true
                        original.editedAt = Date(timeIntervalSince1970: TimeInterval(item.messageData.timestamp))
                        Log.info("BG fetch: applied edit to \(editsId.prefix(8))…", category: "BackgroundFetch")
                    } else {
                        Log.error("BG fetch: original message to edit not found: \(editsId.prefix(8))…", category: "BackgroundFetch")
                    }
                    PersistentACKStore.shared.markProcessed(item.messageData.id, senderId: item.messageData.from, in: backgroundContext)
                    continue
                }

                // Profile share: defer application to the main actor (post-merge). Supports binary wire (no JSON) + legacy.
                if let dc = decryptedContent, ProfileShareData.fromBinaryData(dc) != nil ||
                   decryptedString.contains("\"type\":\"profile\"") {
                    deferredProfileMessages.append((from: item.messageData.from, contentData: dc ?? Data(), legacyString: decryptedString.isEmpty ? nil : decryptedString))
                    PersistentACKStore.shared.markProcessed(item.messageData.id, senderId: item.messageData.from, in: backgroundContext)
                    continue
                }

                // Persist ACK to Core Data (durable across restarts).
                PersistentACKStore.shared.markProcessed(item.messageData.id, senderId: item.messageData.from, in: backgroundContext)

                // Create Message entity.
                let message = Message(context: backgroundContext)
                message.id = item.messageData.id
                message.fromUserId = item.messageData.from
                message.toUserId = item.messageData.to
                message.contentType = .regular
                message.timestamp = Date(timeIntervalSince1970: TimeInterval(item.messageData.timestamp))
                message.isSentByMe = false
                message.deliveryStatus = .delivered
                message.retryCount = 0
                message.chat = item.chat
                message.applyStoredEncryption(plaintext: decryptedString, contactId: item.messageData.from)

                newMessagesCount += 1
                item.chat.unreadCount += 1

                lastDecryptedByChatId[item.chatId] = (text: decryptedString, timestamp: item.messageData.timestamp)
            }

            // Apply last-message preview to each chat.
            for (chatId, last) in lastDecryptedByChatId {
                guard let chat = eligible.first(where: { $0.chatId == chatId })?.chat else { continue }
                chat.lastMessageText = Chat.formatPreviewText(
                    last.text.isEmpty ? NSLocalizedString("message_unavailable", comment: "") : last.text
                )
                chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(last.timestamp))
            }

            // Save context — standalone context writes directly to disk.
            // Capture the NSManagedObjectContextDidSave notification so we can merge
            // into viewContext on the main thread (keeps FRC/Observable updates on main thread).
            do {
                var saveNotification: Notification?
                let token = NotificationCenter.default.addObserver(
                    forName: .NSManagedObjectContextDidSave,
                    object: backgroundContext,
                    queue: nil
                ) { saveNotification = $0 }
                defer { NotificationCenter.default.removeObserver(token) }

                try backgroundContext.save()

                Log.info("Saved \(newMessagesCount) new messages to Core Data", category: "BackgroundFetch")

                let capturedNotification = saveNotification
                DispatchQueue.main.async {
                    // Merge changes into viewContext on main thread — FRC/Observable updates fire here safely.
                    if let notification = capturedNotification {
                        context.mergeChanges(fromContextDidSave: notification)
                    }
                    // Apply profile shares from this batch now that the contact's User row is
                    // merged into viewContext. Mirrors the live stream's handleSpecialMessage.
                    for profile in deferredProfileMessages {
                        let parsed = ProfileSharingManager.shared.parseProfileMessage(from: profile.contentData) ??
                                     (profile.legacyString.flatMap { ProfileSharingManager.shared.parseProfileMessage($0) })
                        if let parsed = parsed {
                            ProfileSharingManager.shared.handleProfileMessage(parsed, from: profile.from, in: context)
                        }
                    }
                    context.saveAndLog()

                    if newMessagesCount > 0 {
                        self.showNotificationsForMessages(
                            messagesByChat: messagesByChat,
                            chatUserIds: chatUserIds,
                            totalCount: newMessagesCount
                        )
                    }

                    completion(.success(newMessagesCount))
                }
            } catch {
                Log.error("Failed to save messages: \(error)", category: "BackgroundFetch")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Find or create chat for a user
    func findOrCreateChat(
        for userId: String,
        in context: NSManagedObjectContext,
        currentUserId: String
    ) -> String? {
        let chatFetch = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "otherUser.id == %@", userId)

        if let existingChat = try? context.fetch(chatFetch).first {
            return existingChat.id
        }

        // Only create a new chat when the User already exists in Core Data.
        // BackgroundFetch must not bootstrap contacts: if the sender is unknown
        // (pruned or first-ever contact) return nil so the message is skipped.
        // The foreground stream handles session init, user creation, and decryption.
        // Creating ghost User+Chat objects here causes Core Data validation errors
        // (encryptedContent required) and recreates pruned contacts on every cycle.
        let userFetch = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "id == %@", userId)
        guard let existingUser = try? context.fetch(userFetch).first else {
            Log.info("BackgroundFetch: unknown sender \(userId.prefix(8))… — skipping (no contact record)", category: "BackgroundFetch")
            return nil
        }

        let newChat = Chat(context: context)
        newChat.id = UUID().uuidString
        newChat.otherUser = existingUser

        return newChat.id
    }
    
    /// Show notifications for new messages
    private func showNotificationsForMessages(
        messagesByChat: [String: [ChatMessage]],
        chatUserIds: [String: String],
        totalCount: Int
    ) {
        let notificationManager = LocalNotificationManager.shared
        
        if messagesByChat.count == 1, let (chatId, messages) = messagesByChat.first {
            // Single chat - show individual notification
            let _ = chatUserIds[chatId] ?? "Unknown"
            
            let context = PersistenceController.shared.container.viewContext
            
            _ = messages.first.flatMap { msg -> String? in
                let messageFetch = Message.fetchRequest()
                messageFetch.predicate = NSPredicate(format: "id == %@", msg.id)
                if let savedMessage = try? context.fetch(messageFetch).first {
                    let text = savedMessage.displayText
                    return text.isEmpty ? nil : text
                }
                return nil
            }
            
            notificationManager.showNewMessageNotification()
        } else {
            // Multiple chats - show batch notification
            notificationManager.showMultipleMessagesNotification(
                messageCount: totalCount,
                fromContacts: messagesByChat.count
            )
        }
        
        // Update badge
        notificationManager.updateBadge(totalCount)
    }
    
    /// Cleanup fetch resources
    private func cleanupFetch() {
        // WebSocket cleanup is handled by gRPC channel teardown
        // which creates its own temporary connection
        Log.info("Cleaning up fetch resources", category: "BackgroundFetch")
    }
    
    /// Perform maintenance operations (cache cleanup, token minting, etc.)
    private func performMaintenance(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            Task { @MainActor in
                // Replenish blind tokens during maintenance window (up to 15 per cycle).
                // BlindTokenService enforces 1-hour cooldown to respect server rate limit.
                await BlindTokenService.shared.replenish(count: 15)

                // Session health audit: send heartbeats to contacts silent for 12+ hours,
                // then log a health summary for diagnostics. Mirrors the foreground path in
                // applicationWillEnterForeground — keeps sessions alive between launches.
                await SessionActivityTracker.shared.sendStaleSessionHeartbeats()
                SessionActivityTracker.shared.logSessionHealthSummary()
            }
            completion(true)
        }
    }
    
    // MARK: - User Controls
    
    /// Enable background fetch
    /// Call this when user enables background refresh in settings
    /// Manual pull-to-refresh: fetches pending messages immediately via gRPC.
    func fetchPendingMessages() async {
        await withCheckedContinuation { continuation in
            performQuickMessageFetch { _ in continuation.resume() }
        }
    }

    func enableBackgroundFetch() {
        // Check Low Power Mode
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            Log.info("Cannot enable background fetch: Low Power Mode is enabled", category: "BackgroundFetch")
            BackgroundFetchConfig.isEnabled = false
            isBackgroundFetchEnabled = false
            return
        }
        
        BackgroundFetchConfig.isEnabled = true
        isBackgroundFetchEnabled = true
        scheduleBackgroundFetch()
        Log.info("Background fetch enabled by user", category: "BackgroundFetch")
    }
    
    /// Disable background fetch
    /// Call this when user disables background refresh in settings
    func disableBackgroundFetch() {
        BackgroundFetchConfig.isEnabled = false
        isBackgroundFetchEnabled = false
        cancelAllBackgroundTasks()
        Log.info("Background fetch disabled by user", category: "BackgroundFetch")
    }
    
    /// Update fetch interval
    func updateFetchInterval(_ minutes: Int) {
        BackgroundFetchConfig.intervalMinutes = minutes
        // Reschedule with new interval if enabled
        if isBackgroundFetchEnabled {
            cancelAllBackgroundTasks()
            scheduleBackgroundFetch()
        }
        Log.info("Background fetch interval updated to \(minutes) minutes", category: "BackgroundFetch")
    }
    
    /// Check if Low Power Mode is enabled and disable background fetch if needed
    func checkLowPowerMode() {
        if ProcessInfo.processInfo.isLowPowerModeEnabled && isBackgroundFetchEnabled {
            Log.info("Low Power Mode detected - disabling background fetch", category: "BackgroundFetch")
            disableBackgroundFetch()
        }
    }
    
    /// Get readable status string for UI
    var statusDescription: String {
        if !isBackgroundFetchEnabled {
            return "Disabled"
        }
        
        if let lastFetch = lastFetchDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Last check: \(formatter.localizedString(for: lastFetch, relativeTo: Date()))"
        }
        
        return "Enabled, waiting for first check"
    }
    
    // MARK: - Errors
    
    enum BackgroundFetchError: LocalizedError {
        case timeout
        case networkUnavailable
        case lowBattery
        case notAuthenticated
        
        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Background fetch timed out"
            case .networkUnavailable:
                return "Network is not available"
            case .lowBattery:
                return "Battery level too low"
            case .notAuthenticated:
                return "User not authenticated"
            }
        }
    }
}
