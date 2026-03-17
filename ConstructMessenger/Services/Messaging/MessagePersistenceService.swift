import Foundation
import CoreData
import os.log

/// Service responsible for message persistence in Core Data
@MainActor
class MessagePersistenceService {
    
    // MARK: - Save Message
    
    /// Save or update a message in Core Data
    /// - Parameters:
    ///   - message: Chat message from network
    ///   - decryptedContent: Decrypted message text
    ///   - isSentByMe: Whether current user sent this message
    ///   - status: Delivery status
    ///   - chat: Associated chat
    ///   - replyTo: Optional reply-to message
    ///   - localThumbnails: Optional thumbnails for media messages
    ///   - suiteId: Crypto suite ID
    ///   - context: Managed object context
    /// - Returns: True if this was a new message, false if updating existing
    func saveMessage(
        _ message: ChatMessage,
        decryptedContent: String,
        isSentByMe: Bool,
        status: DeliveryStatus,
        chat: Chat,
        replyTo: Message? = nil,
        replyToContentOverride: String? = nil,
        localThumbnails: [Data] = [],
        suiteId: UInt16,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        Log.debug("💾 Saving message \(message.id), isSentByMe: \(isSentByMe), status: \(status)", category: "MessagePersistence")
        
        let fetchRequest = Message.fetchRequest()
        let messagePredicate = NSPredicate(format: "id == %@", message.id)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [messagePredicate])
        
        let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        let isNewMessage: Bool
        
        if let existing = try? context.fetch(fetchRequest).first {
            Log.debug("📝 Updating existing message \(message.id)", category: "MessagePersistence")
            existing.deliveryStatus = status
            isNewMessage = false
        } else {
            Log.debug("✨ Creating new message \(message.id)", category: "MessagePersistence")
            let newMessage = Message(context: context)
            newMessage.id = message.id
            newMessage.fromUserId = message.from
            newMessage.toUserId = message.to
            newMessage.encryptedContent = message.content
            newMessage.decryptedContent = decryptedContent
            newMessage.timestamp = messageTimestamp
            newMessage.isSentByMe = isSentByMe
            newMessage.deliveryStatus = status
            newMessage.retryCount = 0
            newMessage.chat = chat
            newMessage.suiteId = suiteId
            
            // Set reply information
            if let replyMessage = replyTo {
                newMessage.replyToMessageId = replyMessage.id
                newMessage.replyToContent = replyToContentOverride ?? replyMessage.decryptedContent
            }
            
            // Store thumbnails locally for media messages
            if !localThumbnails.isEmpty, let firstThumbnail = localThumbnails.first {
                MediaManager.shared.storeThumbnail(firstThumbnail, for: message.id)
            }
            
            isNewMessage = true
        }
        
        // Save synchronously — a deferred Task risks permanent data loss if the app is
        // backgrounded or crashes before the Task executes.
        try context.save()
        if isNewMessage {
            if !isSentByMe { chat.unreadCount += 1 }
            try updateChatMetadata(
                chat: chat,
                lastMessageText: decryptedContent,
                lastMessageTime: messageTimestamp,
                in: context
            )
        }
        
        Log.debug("✅ Message saved to Core Data", category: "MessagePersistence")
        return isNewMessage
    }
    
    // MARK: - Update Message Status
    
    /// Update delivery status of an existing message
    /// - Parameters:
    ///   - messageId: Message ID
    ///   - status: New delivery status
    ///   - context: Managed object context
    func updateMessageContent(
        messageId: String,
        newContent: String,
        isEdited: Bool,
        editedAt: Date,
        in context: NSManagedObjectContext
    ) {
        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)
        fetchRequest.fetchLimit = 1
        guard let message = try? context.fetch(fetchRequest).first else {
            Log.error("❌ Cannot find message to update content: \(messageId)", category: "MessagePersistence")
            return
        }
        message.decryptedContent = newContent
        message.isEdited = isEdited
        message.editedAt = editedAt
        context.saveAndLog()
    }

    // MARK: - Upload Placeholder

    /// Save a "pending upload" placeholder that shows the local thumbnail while media is
    /// being uploaded to the server.  The placeholder carries a special sentinel JSON so
    /// `parseMediaContent` renders it as a media bubble (with local thumbnail) rather than
    /// a raw-text bubble.  Call `deleteMessage` on success and `updateMessageStatus(.failed)`
    /// on failure so the existing retry flow can kick in.
    func savePlaceholderMessage(
        id: String,
        fromUserId: String,
        toUserId: String,
        caption: String,
        thumbnail: Data?,
        replyTo: Message?,
        replyToContentOverride: String? = nil,
        chat: Chat,
        in context: NSManagedObjectContext
    ) {
        // Sentinel JSON — media array contains a single placeholder entry so that
        // parseMediaContent() returns non-nil and MediaMessageView is rendered.
        let placeholderJson = """
        {"type":"media","caption":\(jsonStringLiteral(caption)),"media":[{"_placeholder":true}]}
        """

        let now = Date()
        let newMessage = Message(context: context)
        newMessage.id = id
        newMessage.fromUserId = fromUserId
        newMessage.toUserId = toUserId
        newMessage.encryptedContent = ""
        newMessage.decryptedContent = placeholderJson
        newMessage.timestamp = now
        newMessage.isSentByMe = true
        newMessage.deliveryStatus = .sending
        newMessage.retryCount = 0
        newMessage.chat = chat

        if let replyMessage = replyTo {
            newMessage.replyToMessageId = replyMessage.id
            newMessage.replyToContent = replyToContentOverride ?? replyMessage.decryptedContent
        }

        if let thumb = thumbnail {
            MediaManager.shared.storeThumbnail(thumb, for: id)
        }

        context.saveAndLog()

        // Update chat metadata so the preview row shows something sensible.
        let preview = caption.isEmpty ? "📷 Photo" : caption
        try? updateChatMetadata(chat: chat, lastMessageText: preview, lastMessageTime: now, in: context)

        Log.debug("📎 Saved upload placeholder \(id.prefix(8))…", category: "MessagePersistence")
    }

    /// Delete a placeholder (or any) message by ID — used after upload succeeds so the
    /// real sent message can take its place.
    /// Delete a message by ID.
    ///
    /// Pass `autoSave: false` when you intend to batch this with another
    /// Core Data write (e.g., deleting a placeholder then inserting the real
    /// message).  The caller is then responsible for calling
    /// `context.saveAndLog()` once all changes are staged.
    func deleteMessage(id: String, in context: NSManagedObjectContext, autoSave: Bool = true) {
        let req = Message.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        guard let msg = try? context.fetch(req).first else { return }
        context.delete(msg)
        if autoSave { context.saveAndLog() }
        Log.debug("🗑️ Deleted placeholder \(id.prefix(8))…", category: "MessagePersistence")
    }

    // MARK: - Update Status

    func updateMessageStatus(
        messageId: String,
        status: DeliveryStatus,
        in context: NSManagedObjectContext
    ) {
        let fetchRequest = Message.fetchRequest()
        let messagePredicate = NSPredicate(format: "id == %@", messageId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [messagePredicate])
        
        guard let message = try? context.fetch(fetchRequest).first else {
            Log.error("❌ Message not found: \(messageId)", category: "MessagePersistence")
            return
        }
        
        message.deliveryStatus = status
        do {
            try context.save()
        } catch {
            Log.error("Core Data status save failed: \(error)", category: "MessagePersistence")
        }
        
        Log.debug("✅ Updated message status to \(status) for \(messageId)", category: "MessagePersistence")
    }
    
    // MARK: - Chat Metadata
    
    /// Update chat's last message metadata
    /// - Parameters:
    ///   - chat: Chat to update
    ///   - lastMessageText: Text of last message
    ///   - lastMessageTime: Timestamp of last message
    ///   - context: Managed object context
    private func updateChatMetadata(
        chat: Chat,
        lastMessageText: String,
        lastMessageTime: Date,
        in context: NSManagedObjectContext
    ) throws {
        // Only update if this message is newer than current last message
        if let currentLastTime = chat.lastMessageTime {
            guard lastMessageTime > currentLastTime else {
                Log.debug("⏭️ Skipping chat metadata update - message is older", category: "MessagePersistence")
                return
            }
        }
        
        chat.lastMessageText = Chat.formatPreviewText(lastMessageText)
        chat.lastMessageTime = lastMessageTime
        try context.save()
        
        Log.debug("✅ Updated chat.lastMessageText and lastMessageTime", category: "MessagePersistence")
    }
    
    // MARK: - Message Deletion
    
    /// Delete a single message from Core Data
    /// - Parameters:
    ///   - message: Message to delete
    ///   - chat: Chat containing the message
    ///   - context: Core Data context
    /// - Throws: Core Data error if save fails
    func deleteMessage(_ message: Message, chat: Chat, in context: NSManagedObjectContext) throws {
        guard !message.isDeleted,
              message.managedObjectContext == context else {
            Log.error("❌ Message is deleted or not in the correct context", category: "MessagePersistenceService")
            throw NSError(domain: "MessagePersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid message"])
        }
        
        let messageId = message.id
        Log.debug("🗑️ Deleting message: \(messageId)", category: "MessagePersistenceService")
        
        context.delete(message)
        context.processPendingChanges()
        try context.save()
        
        Log.info("✅ Message deleted from Core Data: \(messageId)", category: "MessagePersistenceService")
        
        // Sync parent context if needed
        if let parent = context.parent {
            parent.performAndWait {
                do { try parent.save() } catch { Log.error("⚠️ MessagePersistenceService: parent context save failed: \(error)", category: "Persistence") }
            }
        }
        
        // Update chat metadata
        try updateChatMetadataAfterDeletion(chat: chat, in: context)
    }
    
    /// Delete multiple messages by IDs
    /// - Parameters:
    ///   - messageIds: Set of message IDs to delete
    ///   - chat: Chat containing the messages
    ///   - context: Core Data context
    /// - Throws: Core Data error if save fails
    func deleteMessages(withIds messageIds: Set<String>, chat: Chat, in context: NSManagedObjectContext) throws {
        guard !messageIds.isEmpty else { return }
        
        Log.debug("🗑️ Deleting \(messageIds.count) messages", category: "MessagePersistenceService")
        
        let fetchRequest = Message.fetchRequest()
        let idsPredicate = NSPredicate(format: "id IN %@", messageIds)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [idsPredicate])
        
        guard let messagesToDelete = try? context.fetch(fetchRequest) else {
            Log.error("❌ Failed to fetch messages for deletion", category: "MessagePersistenceService")
            throw NSError(domain: "MessagePersistence", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch messages"])
        }
        
        Log.debug("🗑️ Found \(messagesToDelete.count) messages to delete", category: "MessagePersistenceService")
        
        for message in messagesToDelete {
            context.delete(message)
        }
        
        context.processPendingChanges()
        try context.save()
        
        Log.info("✅ \(messagesToDelete.count) messages deleted from Core Data", category: "MessagePersistenceService")
        
        // Sync parent context if needed
        if let parent = context.parent {
            parent.performAndWait {
                do { try parent.save() } catch { Log.error("⚠️ MessagePersistenceService: parent context save failed: \(error)", category: "Persistence") }
            }
        }
        
        // Update chat metadata
        try updateChatMetadataAfterDeletion(chat: chat, in: context)
    }
    
    // MARK: - Chat Metadata Update
    /// Update chat metadata after message deletion
    /// - Parameters:
    ///   - chat: Chat to update
    ///   - context: Managed object context
    func updateChatMetadataAfterDeletion(
        chat: Chat,
        in context: NSManagedObjectContext
    ) throws {
        // Find the most recent message for this chat
        let fetchRequest = Message.fetchRequest()
        let chatPredicate = NSPredicate(format: "chat == %@", chat)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [chatPredicate])
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = 1
        
        if let lastMessage = try context.fetch(fetchRequest).first {
            chat.lastMessageText = Chat.formatPreviewText(lastMessage.decryptedContent)
            chat.lastMessageTime = lastMessage.timestamp
        } else {
            // No messages left, clear metadata
            chat.lastMessageText = nil
            chat.lastMessageTime = nil
        }
        
        try context.save()
        Log.debug("✅ Updated chat metadata after deletion", category: "MessagePersistence")
    }

    // MARK: - Private Helpers

    private func jsonStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
