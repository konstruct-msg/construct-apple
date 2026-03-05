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
                newMessage.replyToContent = replyMessage.decryptedContent
            }
            
            // Store thumbnails locally for media messages
            if !localThumbnails.isEmpty, let firstThumbnail = localThumbnails.first {
                MediaManager.shared.storeThumbnail(firstThumbnail, for: message.id)
            }
            
            isNewMessage = true
        }
        
        try context.save()
        
        // Update chat metadata if this is a new message
        if isNewMessage {
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
    func updateMessageStatus(
        messageId: String,
        status: DeliveryStatus,
        in context: NSManagedObjectContext
    ) throws {
        let fetchRequest = Message.fetchRequest()
        let messagePredicate = NSPredicate(format: "id == %@", messageId)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [messagePredicate])
        
        guard let message = try? context.fetch(fetchRequest).first else {
            Log.error("❌ Message not found: \(messageId)", category: "MessagePersistence")
            return
        }
        
        message.deliveryStatus = status
        try context.save()
        
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
                try? parent.save()
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
                try? parent.save()
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
}
