//
//  MessageRouter.swift
//  Construct Messenger
//
//  Routes and processes incoming messages
//  Extracted from ChatsViewModel as part of Phase 1.4 refactoring
//  Created on 2026-02-01
//

import Foundation
import CoreData

/// Routes and processes incoming messages
@MainActor
class MessageRouter {
    
    // MARK: - Core Data
    
    private var viewContext: NSManagedObjectContext?
    
    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }
    
    // MARK: - Callbacks
    
    /// Called when a new chat is created
    var onChatCreated: ((Chat) -> Void)?
    
    /// Called when username needs updating
    var onUsernameUpdateNeeded: ((String) -> Void)?
    
    /// Called when public key bundle is needed for session initialization
    var onPublicKeyBundleNeeded: ((String, ChatMessage) -> Void)?

    /// Called when receiver cannot init session (messageNumber > 0, no session).
    /// Caller should send END_SESSION to that userId so the sender restarts from messageNumber=0.
    var onEndSessionNeeded: ((String) -> Void)?

    /// Called when an existing session failed to decrypt a `messageNumber==0` message.
    /// The remote peer re-keyed — caller should archive the current session and
    /// attempt `initReceivingSession` with the supplied message as the new X3DH init.
    var onSessionHealNeeded: ((String, ChatMessage) -> Void)?

    /// Called when a receipt should be sent via the stream.
    /// Provides message IDs, the original sender's user ID (for server routing), and receipt status.
    var onReceiptNeeded: (([String], String, Shared_Proto_Signaling_V1_ReceiptStatus) -> Void)?

    private let chunkReassembler = ChunkedMessageReassembler()
    
    // MARK: - Message Routing
    
    /// Route incoming message to appropriate handler
    /// - Parameters:
    ///   - message: Incoming chat message
    ///   - context: Core Data context
    ///   - pendingMessages: Dictionary of pending first messages
    func routeIncomingMessage(
        _ message: ChatMessage,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        guard let currentUserId = SessionManager.shared.currentUserId else { return }
        
        let otherUserId = message.from == currentUserId ? message.to : message.from
        
        #if DEBUG
        Log.debug("📥 INCOMING message RAW from server:", category: "MessageRouter")
        Log.debug("   messageId: \(message.id)", category: "MessageRouter")
        Log.debug("   from: \(message.from)", category: "MessageRouter")
        Log.debug("   to: \(message.to)", category: "MessageRouter")
        Log.debug("   messageNumber: \(message.messageNumber)", category: "MessageRouter")
        Log.debug("   ephemeralPublicKey: \(message.ephemeralPublicKey.count) bytes", category: "MessageRouter")
        let ephemeralPreview = message.ephemeralPublicKey.prefix(16).map { String(format: "%02x", $0) }.joined()
        Log.debug("   ephemeralPublicKey preview: \(ephemeralPreview)...", category: "MessageRouter")
        Log.debug("   content (padded): \(message.content.count) chars", category: "MessageRouter")
        Log.debug("   content preview: \(message.content.prefix(32))...", category: "MessageRouter")
        Log.debug("   isEndSession: \(message.isEndSession)", category: "MessageRouter")
        #endif
        
        // 1. Check if this is an END_SESSION control message
        if message.isEndSession {
            Log.info("🛑 Received END_SESSION from \(otherUserId)", category: "MessageRouter")
            handleEndSession(from: otherUserId, in: context, pendingMessages: &pendingMessages)
            return
        }
        
        // 2. Skip if already processed (persistent ACK — survives app restart)
        if PersistentACKStore.shared.isProcessed(message.id, in: context) {
            Log.debug("⏭️ Skipping already-processed message \(message.id.prefix(8))… (ACK store)", category: "MessageRouter")
            // Re-send receipt so the server advances past this message in the pending queue.
            // Without this the cursor stays stuck and the same message is fetched on every reconnect.
            onReceiptNeeded?([message.id], otherUserId, .delivered)
            return
        }

        // 3. Skip if already saved to Core Data (deduplication for duplicate deliveries)
        let existingFetch = Message.fetchRequest()
        existingFetch.predicate = NSPredicate(format: "id == %@", message.id)
        existingFetch.fetchLimit = 1
        if (try? context.fetch(existingFetch))?.first != nil {
            Log.debug("⏭️ Skipping already-saved message \(message.id.prefix(8))…", category: "MessageRouter")
            return
        }

        // 3. Find or create chat
        let (chat, isNewChat) = findOrCreateChat(for: otherUserId, in: context)
        
        // 4. Check if we have a session for this user
        let hasSession = CryptoManager.shared.hasSession(for: otherUserId)
        Log.info("🔐 SESSION_STATE[incoming_message]: userId=\(otherUserId.prefix(8))..., hasSession=\(hasSession), messageId=\(message.id.prefix(8))...", category: "SessionInit")
        
        let decryptedContent: String
        if !hasSession {
            // First message from this user - need to initialize receiving session
            handleFirstMessage(
                message,
                from: otherUserId,
                chat: chat,
                isNewChat: isNewChat,
                in: context,
                pendingMessages: &pendingMessages
            )
            return
        } else {
            // Existing session - decrypt normally
            decryptedContent = handleMessageWithSession(
                message,
                from: otherUserId,
                chat: chat,
                in: context,
                pendingMessages: &pendingMessages
            ) ?? ""
            
            // If decryption failed, roll back any newly-created chat so it isn't persisted empty
            if decryptedContent.isEmpty {
                if isNewChat { context.delete(chat) }
                return
            }
        }

        switch chunkReassembler.process(decryptedText: decryptedContent) {
        case .legacy(let text), .complete(let text):
            // Continue with resolved plaintext
            return handleResolvedMessage(
                text,
                for: message,
                from: otherUserId,
                chat: chat,
                in: context
            )
        case .incomplete:
            Log.debug("🧩 Chunked message incomplete, waiting for more chunks", category: "MessageRouter")
            return
        case .invalid(let reason):
            Log.error("❌ Invalid chunked message: \(reason)", category: "MessageRouter")
            return
        }
    }

    private func handleResolvedMessage(
        _ decryptedContent: String,
        for message: ChatMessage,
        from otherUserId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        // 4. Check for special message types (profile sharing, etc.)
        if let specialMessageHandled = handleSpecialMessage(
            decryptedContent,
            from: otherUserId,
            in: context
        ), specialMessageHandled {
            PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
            return  // Special message handled, don't save as regular message
        }

        PersistentACKStore.shared.markProcessed(message.id, senderId: otherUserId, in: context)
        // 5. Save regular message
        saveMessage(for: chat, with: message, decryptedContent: decryptedContent, in: context)

        // 6. Acknowledge delivery to sender via stream
        onReceiptNeeded?([message.id], otherUserId, .delivered)

        // 7. Update chat metadata
        chat.lastMessageText = Chat.formatPreviewText(decryptedContent)
        chat.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(message.timestamp))

        Log.info("📬 Message received and saved: \(message.id)", category: "MessageRouter")
    }
    
    // MARK: - Chat Management
    
    /// Find or create chat for user
    /// - Parameters:
    ///   - userId: User ID
    ///   - context: Core Data context
    /// - Returns: Tuple of (chat, isNewChat)
    private func findOrCreateChat(
        for userId: String,
        in context: NSManagedObjectContext
    ) -> (Chat, Bool) {
        let fetchRequest = Chat.fetchRequest()
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [otherUserPredicate])
        
        if let existingChat = try? context.fetch(fetchRequest).first {
            return (existingChat, false)
        }
        
        // Create new user and chat
        let user = findOrCreateUser(for: userId, in: context)
        
        let newChat = Chat(context: context)
        newChat.id = UUID().uuidString
        newChat.otherUser = user
        
        return (newChat, true)
    }
    
    /// Find or create user
    /// - Parameters:
    ///   - userId: User ID
    ///   - context: Core Data context
    /// - Returns: User entity
    private func findOrCreateUser(
        for userId: String,
        in context: NSManagedObjectContext
    ) -> User {
        let userFetchRequest = User.fetchRequest()
        let userIdPredicate = NSPredicate(format: "id == %@", userId)
        var predicates: [NSPredicate] = [userIdPredicate]
        if let existingPredicate = userFetchRequest.predicate {
            predicates.insert(existingPredicate, at: 0)
        }
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        
        if let existingUser = try? context.fetch(userFetchRequest).first {
            Log.debug("Using existing user: id=\(userId)", category: "MessageRouter")
            return existingUser
        }
        
        // Create new user with temporary username (will be updated from publicKeyBundle)
        let newUser = User(context: context)
        newUser.id = userId
        newUser.username = ""
        newUser.displayName = DisplayNameGenerator.generate(from: userId)
        newUser.isSharingWithMe = false
        newUser.isBlocked = false
        newUser.amISharingWith = false
        
        Log.debug("Created new user: id=\(userId)", category: "MessageRouter")
        return newUser
    }
    
    // MARK: - First Message Handling
    
    /// Handle first message from user (no session yet)
    private func handleFirstMessage(
        _ message: ChatMessage,
        from userId: String,
        chat: Chat,
        isNewChat: Bool,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        let isFirstForUser = pendingMessages[userId] == nil || pendingMessages[userId]!.isEmpty

        // Deduplicate: skip if same message ID is already in the queue
        if pendingMessages[userId]?.contains(where: { $0.id == message.id }) == true {
            Log.debug("⏭️ Skipping duplicate queued message \(message.id.prefix(8))...", category: "MessageRouter")
            // ACK so server removes it from the pending queue — session init is already
            // in flight for this user and will handle the message from the queue.
            onReceiptNeeded?([message.id], userId, .delivered)
            return
        }

        // Guard: initReceivingSession requires messageNumber=0 (X3DH handshake).
        // If we have no session and the message is already mid-ratchet, we can never
        // initialize from it — request the sender to restart their session instead.
        if message.messageNumber > 0 && isFirstForUser {
            Log.info("⚠️ No session for \(userId.prefix(8)) but messageNumber=\(message.messageNumber) — requesting END_SESSION so sender restarts", category: "MessageRouter")
            // Mark as processed + send failed receipt so server removes it from pending queue.
            // Without this the same message is re-fetched on every reconnect, inserting a
            // duplicate system message each time.
            PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
            onReceiptNeeded?([message.id], userId, .failed)
            addSystemMessage(
                "Encrypted session out of sync. Asking contact to restart...",
                toUserId: userId,
                in: context
            )
            if isNewChat { context.delete(chat) }
            onEndSessionNeeded?(userId)
            return
        }

        // Append to the queue (do NOT overwrite — we need message_number=0 for session init)
        pendingMessages[userId, default: []].append(message)

        Log.info("📩 Message queued for session init from \(userId) — queue size: \(pendingMessages[userId]!.count)", category: "MessageRouter")
        Log.info("🔐 SESSION_STATE[first_message]: userId=\(userId.prefix(8))..., messageNumber=\(message.messageNumber), action=\(isFirstForUser ? "fetch_bundle" : "queued")", category: "SessionInit")

        // If we created a new chat, save it so it appears in UI
        if isNewChat {
            do {
                try context.save()
                Log.debug("✅ Saved new chat for \(userId)", category: "MessageRouter")
                onChatCreated?(chat)
            } catch {
                Log.error("❌ Failed to save new chat: \(error)", category: "MessageRouter")
            }
        }

        // Request bundle only once (on the first message; subsequent messages just queue)
        if isFirstForUser {
            onPublicKeyBundleNeeded?(userId, message)
        }
    }
    
    // MARK: - Session Message Handling
    
    /// Handle message when session exists
    /// - Returns: Decrypted content or nil if failed
    private func handleMessageWithSession(
        _ message: ChatMessage,
        from userId: String,
        chat: Chat,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) -> String? {
        Log.info("🔐 SESSION_STATE[decrypt_attempt]: userId=\(userId.prefix(8))..., hasSession=true", category: "SessionInit")
        
        guard let content = try? CryptoManager.shared.decryptMessage(message) else {
            Log.error("❌ Failed to decrypt incoming message \(message.id)", category: "MessageRouter")
            Log.error("🔐 SESSION_STATE[decrypt_failed]: userId=\(userId.prefix(8))..., messageId=\(message.id.prefix(8))..., messageNumber=\(message.messageNumber)", category: "SessionInit")

            if SessionHealingService.shared.canHeal(message) {
                // messageNumber == 0 means the sender RE-KEYED (new X3DH session init).
                // Session was already archived by decryptMessage (reason: decryptionFailed) — skip redundant archive.
                Log.info("🩹 SESSION_STATE[heal_triggered]: messageNumber=0 from \(userId.prefix(8))… — sender re-keyed, healing", category: "SessionInit")
                SessionHealingService.shared.enqueue(message, in: context)
                pendingMessages[userId, default: []].append(message)
                onSessionHealNeeded?(userId, message)
            } else {
                // messageNumber > 0 → DR ratchet diverged, healing is impossible.
                // Send FAILED receipt: server automatically relays SESSION_RESET to sender (server-side item 12).
                // Also send explicit END_SESSION message for defense-in-depth (sender handles both idempotently).
                Log.info("🔄 SESSION_STATE[heal_impossible]: messageNumber=\(message.messageNumber) — ratchet diverged, requesting END_SESSION", category: "SessionInit")
                onReceiptNeeded?([message.id], userId, .failed)
                pendingMessages.removeValue(forKey: userId)
                SessionHealingService.shared.clearQueue(for: userId, in: context)
                onEndSessionNeeded?(userId)
            }

            return nil
        }

        // Check if username is still UUID - request update if needed
        checkUsernameUpdate(for: userId, chat: chat, in: context)

        return content
    }
    
    /// Check if username needs updating
    private func checkUsernameUpdate(
        for userId: String,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        guard let user = chat.otherUser else { return }
        
        let usernameIsGuid = user.username == user.id || user.username == userId
        let displayNameIsGuid = user.displayName == user.id || user.displayName == userId
        
        if usernameIsGuid || displayNameIsGuid {
            Log.info("🔄 Username for \(userId) is still UUID, requesting update", category: "MessageRouter")
            onUsernameUpdateNeeded?(userId)
        }
    }
    
    // MARK: - Special Message Types
    
    /// Handle special message types (profile, etc.)
    /// - Returns: true if special message was handled
    private func handleSpecialMessage(
        _ decryptedContent: String,
        from userId: String,
        in context: NSManagedObjectContext
    ) -> Bool? {
        // Check for profile message
        if decryptedContent.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           let jsonData = decryptedContent.data(using: .utf8),
           let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let type = jsonDict["type"] as? String,
           type == "profile" {
            
            if let profileData = ProfileSharingManager.shared.parseProfileMessage(decryptedContent) {
                Log.info("📥 Received profile message from \(userId)", category: "MessageRouter")
                ProfileSharingManager.shared.handleProfileMessage(profileData, from: userId, in: context)
                return true
            } else {
                Log.info("⚠️ Failed to parse profile message from \(userId), skipping", category: "MessageRouter")
                return true  // Still skip saving as regular message
            }
        }
        
        return false  // Not a special message
    }
    
    // MARK: - END_SESSION Handling
    
    /// Handle END_SESSION message
    private func handleEndSession(
        from userId: String,
        in context: NSManagedObjectContext,
        pendingMessages: inout [String: [ChatMessage]]
    ) {
        Log.info("🛑 Handling END_SESSION from \(userId)", category: "MessageRouter")
        
        // 1. Archive the current session
        CryptoManager.shared.archiveSession(for: userId, reason: .endSessionReceived)
        Log.debug("✅ Session archived for \(userId)", category: "MessageRouter")
        
        // 2. Add system message to chat
        addSystemMessage(
            "Encrypted session was reset. Send a message to re-establish encryption.",
            toUserId: userId,
            in: context
        )
        
        // 3. Remove any pending messages and healing queue for this user
        pendingMessages.removeValue(forKey: userId)
        SessionHealingService.shared.clearQueue(for: userId, in: context)
        
        Log.info("✅ END_SESSION handled for \(userId)", category: "MessageRouter")
    }
    
    /// Add a system message to chat
    private func addSystemMessage(
        _ text: String,
        toUserId userId: String,
        in context: NSManagedObjectContext
    ) {
        guard let currentUserId = SessionManager.shared.currentUserId else { return }
        
        // Find chat
        let fetchRequest = Chat.fetchRequest()
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [otherUserPredicate])
        
        guard let chat = try? context.fetch(fetchRequest).first else {
            Log.error("❌ Cannot add system message: chat not found for \(userId)", category: "MessageRouter")
            return
        }
        
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.chat = chat
        message.fromUserId = "SYSTEM"
        message.toUserId = currentUserId
        message.encryptedContent = ""
        message.decryptedContent = text
        message.suiteId = 0
        message.timestamp = Date()
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        
        chat.lastMessageText = Chat.formatPreviewText(text)
        chat.lastMessageTime = Date()
        
        do {
            try context.save()
            Log.debug("✅ System message added to chat with \(userId)", category: "MessageRouter")
        } catch {
            Log.error("❌ Failed to save system message: \(error)", category: "MessageRouter")
        }
    }
    
    // MARK: - Message Persistence
    
    /// Save message to Core Data
    private func saveMessage(
        for chat: Chat,
        with messageData: ChatMessage,
        decryptedContent: String,
        in context: NSManagedObjectContext
    ) {
        let fetchRequest = Message.fetchRequest()
        let messagePredicate = NSPredicate(format: "id == %@", messageData.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [messagePredicate])
        
        // Check if message already exists (from background fetch)
        if let existingMessage = try? context.fetch(fetchRequest).first {
            // Update decryptedContent if it's nil
            if existingMessage.decryptedContent == nil {
                Log.debug("🔄 Updating decrypted content for message \(messageData.id)", category: "MessageRouter")
                existingMessage.decryptedContent = decryptedContent
                
                do {
                    try context.save()
                    Log.debug("✅ Updated message decryption", category: "MessageRouter")
                } catch {
                    Log.error("❌ Failed to update message: \(error)", category: "MessageRouter")
                }
            }
            return  // Message already exists
        }
        
        // Create new message
        let message = Message(context: context)
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
        
        do {
            try context.save()
        } catch {
            Log.error("❌ Failed to save message: \(error)", category: "MessageRouter")
        }
    }
}
