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
        
        // Get Core Data context
        let context = PersistenceController.shared.container.viewContext
        let backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundContext.parent = context
        
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
                completion(.failure(error))
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
                    var decryptedContent: String?

                    // Targeted session restore before the hasSession check.
                    // Background fetch may run before restoreRecentSessions() has completed
                    // (e.g., silent push during app launch race). restoreSession(for:) is a
                    // synchronous Keychain lookup — no-op if session already in memory.
                    _ = DispatchQueue.main.sync { CryptoManager.shared.restoreSession(for: otherUserId) }

                    if CryptoManager.shared.hasSession(for: otherUserId) {
                        DispatchQueue.main.sync {
                            do {
                                decryptedContent = try CryptoManager.shared.decryptMessage(messageData)
                                Log.debug("✅ Decrypted message \(messageData.id)", category: "BackgroundFetch")
                                // Immediately mark in-memory on the main thread to close the race window
                                // with the live gRPC stream.  The stream's isProcessed check hits the
                                // Rust in-memory cache first — if it finds the ID there it skips the
                                // message entirely, preventing a double-decrypt AEAD failure that would
                                // trigger heal_impossible → END_SESSION → silent session destruction.
                                // Core Data persistence follows below on the background thread.
                                PersistentACKStore.shared.preemptACK(messageData.id)
                            } catch {
                                Log.error("❌ Failed to decrypt message \(messageData.id): \(error)", category: "BackgroundFetch")
                            }
                        }
                    } else {
                        Log.info("⚠️ No session for user \(otherUserId), message will be decrypted later", category: "BackgroundFetch")
                        // Message will be decrypted when user opens chat and session is initialized
                    }

                    // Chunk messages: if the decrypted plaintext starts with "KNST1:" it is a
                    // chunked-message fragment.  The Double Ratchet advanced above, and the
                    // in-memory ACK (preemptACK) was already written inside the main.sync block,
                    // so the stream cannot re-decrypt this chunk.  We still need:
                    //   1. Core Data ACK persist (markProcessed below) — survives app restart
                    //   2. Reassembly — feed to shared ChunkedMessageReassembler
                    // • .complete  → replace decryptedContent with assembled text, fall through to save
                    // • .incomplete → Core Data ACK + skip save; remaining chunks complete assembly
                    //                 via subsequent background fetches or the live stream
                    // • .invalid / .legacy → Core Data ACK + skip save
                    if let dc = decryptedContent, dc.hasPrefix("KNST1:") {
                        var assembled: String? = nil
                        DispatchQueue.main.sync {
                            switch ChunkedMessageReassembler.shared.process(decryptedText: dc) {
                            case .complete(let text):
                                assembled = text
                            case .legacy(let text):
                                assembled = text
                            case .incomplete, .invalid:
                                break
                            }
                        }
                        // Always ACK — ratchet is past this chunk, stream must not retry.
                        PersistentACKStore.shared.markProcessed(messageData.id, senderId: messageData.from, in: backgroundContext)
                        if let text = assembled {
                            Log.debug("✅ Chunk assembled in background fetch \(messageData.id.prefix(8))", category: "BackgroundFetch")
                            decryptedContent = text
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
                    message.encryptedContent = messageData.content
                    message.decryptedContent = decryptedContent
                    message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
                    message.isSentByMe = false
                    message.deliveryStatus = .delivered
                    message.retryCount = 0
                    message.chat = chat
                    
                    newMessagesCount += 1
                    chat.unreadCount += 1

                    // Update chat's last message
                    if let lastMessage = chatMessages.last {
                        chat.lastMessageText = Chat.formatPreviewText(decryptedContent ?? NSLocalizedString("message_unavailable", comment: ""))
                        chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(lastMessage.timestamp))
                    }
                }
            }
            
            // Save context
            do {
                try backgroundContext.save()
                context.performAndWait {
                    context.saveAndLog()
                }
                
                Log.info("✅ Saved \(newMessagesCount) new messages to Core Data", category: "BackgroundFetch")
                
                // Show notifications on main thread
                DispatchQueue.main.async {
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
        
        // Create new chat
        let userFetch = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "id == %@", userId)
        
        let dbUser: User
        if let existingUser = try? context.fetch(userFetch).first {
            dbUser = existingUser
            // ✅ FIX: If existing user has UUID as username, it will be updated when publicKeyBundle is requested
            // This happens automatically in ChatsViewModel.handleIncomingMessage
        } else {
            let newUser = User(context: context)
            newUser.id = userId
            newUser.username = ""
            newUser.displayName = DisplayNameGenerator.generate(from: userId)
            newUser.isSharingWithMe = false
            newUser.isBlocked = false
            newUser.amISharingWith = false
            newUser.isContact = true
            newUser.addedAt = Date()
            dbUser = newUser
            Log.debug("Created new user in BackgroundFetch: id=\(userId), username will be updated from publicKeyBundle", category: "BackgroundFetch")
        }
        
        let newChat = Chat(context: context)
        newChat.id = UUID().uuidString
        newChat.otherUser = dbUser
        
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
                // Try to get decrypted content if available
                let messageFetch = Message.fetchRequest()
                messageFetch.predicate = NSPredicate(format: "id == %@", msg.id)
                if let savedMessage = try? context.fetch(messageFetch).first,
                   let decrypted = savedMessage.decryptedContent {
                    return decrypted
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
            // Mint stealth tokens during maintenance window (device is charging)
            Task { @MainActor in
                // Mint up to 15 tokens per maintenance cycle (budget: ~1800-2700 per charging session)
                TokenWalletService.shared.mintTokens(count: 15)
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
