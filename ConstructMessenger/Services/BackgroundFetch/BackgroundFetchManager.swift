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
                Log.error("❌ Invalid task type for message refresh", category: "BackgroundFetch")
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
                Log.error("❌ Invalid task type for maintenance", category: "BackgroundFetch")
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
        Log.info("📬 Background message refresh started")
        
        // Schedule next refresh immediately
        scheduleBackgroundFetch()
        
        // Set expiration handler (iOS gives 30 seconds)
        task.expirationHandler = {
            Log.error("⏰ Background task expired")
            self.cleanupFetch()
            task.setTaskCompleted(success: false)
        }
        
        // Check if we should perform fetch (battery, network, etc.)
        guard energyMonitor.shouldPerformBackgroundFetch() else {
            Log.info("⚠️ Skipping background fetch due to energy conditions")
            task.setTaskCompleted(success: true)
            return
        }
        
        // Perform the actual fetch with 20-second timeout
        performQuickMessageFetch { result in
            switch result {
            case .success(let messageCount):
                Log.info("✅ Background fetch completed: \(messageCount) new messages")
                self.lastFetchDate = Date()
                self.lastFetchResult = .success(messageCount)
                task.setTaskCompleted(success: true)
                
            case .failure(let error):
                Log.error("❌ Background fetch failed: \(error)")
                self.lastFetchResult = .failure(error)
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    /// Handle BGProcessingTask for maintenance operations
    private func handleMaintenance(task: BGProcessingTask) {
        Log.info("🔧 Maintenance task started")
        
        // Set expiration handler
        task.expirationHandler = {
            Log.error("⏰ Maintenance task expired")
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
        Log.info("🚀 Starting quick message fetch", category: "BackgroundFetch")
        
        // Check authentication
        guard SessionManager.shared.sessionToken != nil else {
            Log.error("❌ No session token available", category: "BackgroundFetch")
            completion(.failure(BackgroundFetchError.notAuthenticated))
            return
        }
        
        // Get Core Data context — use a standalone background context (not a child of viewContext)
        // to avoid triggering NSManagedObjectContextObjectsDidChange on the background thread,
        // which would fire FRC/Observable updates off the main thread (purple Xcode warning).
        let context = PersistenceController.shared.container.viewContext
        let backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundContext.persistentStoreCoordinator = context.persistentStoreCoordinator
        
        // ✅ Fetch pending messages via gRPC (unary, cursor-paginated)
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
                Log.error("❌ Failed to fetch offline messages: \(error.localizedDescription)", category: "BackgroundFetch")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    
    private func processOfflineMessages(_ messages: [ChatMessage], backgroundContext: NSManagedObjectContext, completion: @escaping (Result<Int, Error>) -> Void) {
        guard !messages.isEmpty else {
            completion(.success(0))
            return
        }
        
        Log.info("📬 Processing \(messages.count) offline messages", category: "BackgroundFetch")
        
        // Get Core Data context for processing
        let context = PersistenceController.shared.container.viewContext
        
        // Process messages in background context
        backgroundContext.perform {
            var newMessagesCount = 0
            var messagesByChat: [String: [ChatMessage]] = [:]
            var chatUserIds: [String: String] = [:] // chatId -> userId
            
            guard let currentUserId = SessionManager.shared.currentUserId else {
                DispatchQueue.main.async {
                    completion(.failure(BackgroundFetchError.notAuthenticated))
                }
                return
            }
            
            // Group messages by chat (skip control messages — they are not user-visible)
            for message in messages {
                guard message.messageType != "CONTROL_MESSAGE" && message.messageType != "SENDER_SYNC" else {
                    Log.debug("⏭️ Skipping control message \(message.id) (\(message.messageType ?? "nil")) in grouping phase", category: "BackgroundFetch")
                    continue
                }
                let otherUserId = message.from == currentUserId ? message.to : message.from

                // Skip messages from contacts that have been pruned. This must be the first
                // check after resolving otherUserId: pruneContact() already archives the
                // session and deletes User + Chat from Core Data. BackgroundFetch must not
                // recreate them, nor attempt decryption against a wiped session.
                guard !DeletedContactsStore.shared.isDeleted(otherUserId) else {
                    Log.debug("⏭️ Skipping message \(message.id.prefix(8))… from pruned contact \(otherUserId.prefix(8))…", category: "BackgroundFetch")
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
            
            // Process each chat's messages
            for (chatId, chatMessages) in messagesByChat {
                guard let otherUserId = chatUserIds[chatId] else { continue }
                
                // Find chat
                let chatFetch = Chat.fetchRequest()
                chatFetch.predicate = NSPredicate(format: "id == %@", chatId)
                guard let chat = try? backgroundContext.fetch(chatFetch).first else {
                    Log.error("❌ Chat not found: \(chatId)", category: "BackgroundFetch")
                    continue
                }
                
                // Process messages
                for messageData in chatMessages {
                    // Check if message already exists
                    let messageFetch = Message.fetchRequest()
                    messageFetch.predicate = NSPredicate(format: "id == %@", messageData.id)
                    
                    if (try? backgroundContext.fetch(messageFetch).first) != nil {
                        continue // Already exists
                    }

                    // Skip control messages (END_SESSION, SENDER_SYNC): these are session
                    // management signals, not user-visible messages. Attempting to decrypt
                    // "END_SESSION" as AEAD ciphertext corrupts the live session — causing
                    // subsequent messages to show as "Encrypted" in the UI. The real-time
                    // stream handles all control messages when the app comes to foreground.
                    if messageData.messageType == "CONTROL_MESSAGE" || messageData.messageType == "SENDER_SYNC" {
                        Log.debug("⏭️ Skipping control message \(messageData.id) (\(messageData.messageType ?? "nil")) in background fetch", category: "BackgroundFetch")
                        continue
                    }

                    // Try to decrypt message.
                    // CryptoManager is not thread-safe: all crypto calls must run on MainActor.
                    // Use DispatchQueue.main.sync to serialize with foreground session state.
                    // This is safe because backgroundContext.perform runs on a private queue,
                    // not the main queue, so there is no deadlock risk.
                    var decryptedContent: Data?

                    // Targeted session restore before the hasSession check.
                    _ = DispatchQueue.main.sync { CryptoManager.shared.restoreSession(for: otherUserId) }

                    if CryptoManager.shared.hasSession(for: otherUserId) {
                        DispatchQueue.main.sync {
                            do {
                                let result = try CryptoManager.shared.decryptMessage(messageData)
                                decryptedContent = result.plaintext
                                if !result.storageKey.isEmpty {
                                    MessageKeyStore.shared.store(messageId: messageData.id, key: result.storageKey, contactId: otherUserId)
                                }
                                Log.debug("✅ Decrypted message \(messageData.id)", category: "BackgroundFetch")
                                PersistentACKStore.shared.preemptACK(messageData.id)
                            } catch {
                                Log.error("❌ Failed to decrypt message \(messageData.id): \(error)", category: "BackgroundFetch")
                            }
                        }
                    } else {
                        Log.info("⚠️ No session for user \(otherUserId), message will be decrypted later", category: "BackgroundFetch")
                    }

                    // Chunk messages: if the decrypted bytes start with binary KNST magic or legacy
                    // "KNST1:" prefix, feed to ChunkedMessageReassembler.
                    let legacyPrefixBytes = Data(ChunkedMessageCodec.legacyPrefix.utf8)
                    let binaryMagic = Data([0x4B, 0x4E, 0x53, 0x54]) // "KNST"
                    if let dc = decryptedContent,
                       dc.starts(with: binaryMagic) || dc.starts(with: legacyPrefixBytes) {
                        var assembled: String? = nil
                        DispatchQueue.main.sync {
                            switch ChunkedMessageReassembler.shared.process(data: dc) {
                            case .assembled(let text, _):
                                assembled = text
                            case .legacy(let text):
                                assembled = text
                            case .incomplete, .invalid:
                                break
                            }
                        }
                        PersistentACKStore.shared.markProcessed(messageData.id, senderId: messageData.from, in: backgroundContext)
                        if let text = assembled {
                            Log.debug("✅ Chunk assembled in background fetch \(messageData.id.prefix(8))", category: "BackgroundFetch")
                            decryptedContent = Data(text.utf8)
                        } else {
                            Log.debug("⏭️ Chunk fragment \(messageData.id.prefix(8)) ACK'd; waiting for remaining chunks", category: "BackgroundFetch")
                            continue
                        }
                    }

                    // Persist the ACK to Core Data for non-chunk messages.
                    // The in-memory cache was already updated by preemptACK inside main.sync,
                    // which closed the stream race window.  This call durably persists across
                    // app restarts.  Idempotent — calling markProcessed on an already-cached
                    // ID is a no-op in Core Data (guarded by fetchLimit:1 check).
                    // Skip for failed decryptions (nil) so the stream can retry with the live session.
                    if decryptedContent != nil {
                        PersistentACKStore.shared.markProcessed(messageData.id, senderId: messageData.from, in: backgroundContext)
                    }
                    
                    // Save message
                    let message = Message(context: backgroundContext)
                    message.id = messageData.id
                    message.fromUserId = messageData.from
                    message.toUserId = messageData.to
                    let decryptedString = decryptedContent.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    message.contentType = .regular
                    message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
                    message.isSentByMe = false
                    message.deliveryStatus = .delivered
                    message.retryCount = 0
                    message.chat = chat

                    message.applyStoredEncryption(plaintext: decryptedString, contactId: messageData.from)
                    
                    newMessagesCount += 1
                    chat.unreadCount += 1

                    // Update chat's last message
                    if let lastMessage = chatMessages.last {
                        chat.lastMessageText = Chat.formatPreviewText(decryptedString.isEmpty ? NSLocalizedString("message_unavailable", comment: "") : decryptedString)
                        chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(lastMessage.timestamp))
                    }
                }
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

                Log.info("✅ Saved \(newMessagesCount) new messages to Core Data", category: "BackgroundFetch")

                let capturedNotification = saveNotification
                DispatchQueue.main.async {
                    // Merge changes into viewContext on main thread — FRC/Observable updates fire here safely.
                    if let notification = capturedNotification {
                        context.mergeChanges(fromContextDidSave: notification)
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
                Log.error("❌ Failed to save messages: \(error)", category: "BackgroundFetch")
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
            Log.info("⏭️ BackgroundFetch: unknown sender \(userId.prefix(8))… — skipping (no contact record)", category: "BackgroundFetch")
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
