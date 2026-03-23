//
//  ChatManagementService.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 02.02.2026.
//

import Foundation
import CoreData

/// Manages chat lifecycle: creation from invites and deletion with cleanup
/// Extracted from ChatsViewModel Phase 1.6
@MainActor
class ChatManagementService {
    
    // MARK: - Core Data
    
    private var viewContext: NSManagedObjectContext?
    
    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }
    
    // MARK: - Callbacks
    
    /// Called when a new chat is created
    var onChatCreated: ((Chat) -> Void)?
    
    /// Called when a chat is deleted
    var onChatDeleted: ((String) -> Void)?
    
    // MARK: - Chat Creation
    
    /// Start a new chat with a user (from invite link or QR code)
    /// - Parameter user: Public user information from invite
    /// - Returns: Created or existing chat, nil if context is unavailable
    func startChat(with user: PublicUserInfo) -> Chat? {
        guard let context = viewContext else { 
            Log.error("❌ ChatManagementService: No viewContext available", category: "ChatManagementService")
            return nil 
        }

        if user.id == SessionManager.shared.currentUserId {
            Log.info("📝 Self-chat detected — use Drafts instead", category: "ChatManagementService")
            return nil
        }
        
        // Check if chat already exists
        let fetchRequest = Chat.fetchRequest()
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", user.id)
        var chatPredicates: [NSPredicate] = [otherUserPredicate]
        if let chatOwnerPredicate = fetchRequest.predicate {
            chatPredicates.insert(chatOwnerPredicate, at: 0)
        }
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: chatPredicates)
        
        if let existingChat = try? context.fetch(fetchRequest).first {
            Log.debug("ℹ️ Chat already exists with user: \(user.username)", category: "ChatManagementService")
            return existingChat
        }
        
        // If this user was previously deleted, remove from deleted store so messages
        // from them are no longer silently discarded.
        DeletedContactsStore.shared.remove(user.id)

        // Check if User already exists before creating a new one
        let userFetchRequest = User.fetchRequest()
        let idPredicate = NSPredicate(format: "id == %@", user.id)
        var userPredicates: [NSPredicate] = [idPredicate]
        if let userOwnerPredicate = userFetchRequest.predicate {
            userPredicates.insert(userOwnerPredicate, at: 0)
        }
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: userPredicates)
        
        let dbUser: User
        if let existingUser = try? context.fetch(userFetchRequest).first {
            existingUser.applyServerUsername(user.username, userId: user.id)
            if !existingUser.isContact {
                existingUser.isContact = true
                existingUser.addedAt = existingUser.addedAt ?? Date()
            }
            dbUser = existingUser
            Log.debug("Using existing user: id=\(user.id), username=\(user.username), displayName=\(existingUser.displayName)", category: "ChatManagementService")
        } else {
            // Create new user
            dbUser = User(context: context)
            dbUser.id = user.id
            dbUser.isSharingWithMe = false
            dbUser.isBlocked = false
            dbUser.amISharingWith = false
            dbUser.isContact = true
            dbUser.addedAt = Date()
            dbUser.applyServerUsername(user.username, userId: user.id)
            Log.debug("Created new user: id=\(user.id), username=\(user.username), displayName=\(dbUser.displayName)", category: "ChatManagementService")
        }
        
        // Create new chat — set lastMessageTime so it sorts to the top of the list immediately
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = dbUser
        chat.lastMessageTime = Date()
        
        do {
            try context.save()
            Log.debug("✅ Chat saved successfully", category: "ChatManagementService")
            Log.debug("   chat.id = \(chat.id)", category: "ChatManagementService")
            Log.debug("   chat.otherUser?.id = \(chat.otherUser?.id ?? "nil")", category: "ChatManagementService")
            Log.debug("   chat.otherUser?.username = \(chat.otherUser?.username ?? "nil")", category: "ChatManagementService")
            Log.debug("   chat.otherUser?.displayName = \(chat.otherUser?.displayName ?? "nil")", category: "ChatManagementService")
            
            // Notify via callback
            onChatCreated?(chat)
            
            return chat
        } catch {
            Log.error("❌ Failed to save chat: \(error)", category: "ChatManagementService")
            return nil
        }
    }

    // MARK: - Chat Deletion

    /// Delete a chat while keeping the contact in Synaps.
    ///
    /// Removes Chat + Messages and archives the crypto session.
    /// The User entity is preserved with isContact=true so the contact
    /// remains visible in the Synaps list and can be messaged again.
    /// To fully remove a contact use pruneContact(userId:).
    func deleteChat(_ chat: Chat) {
        guard let context = viewContext else {
            Log.error("❌ ChatManagementService: No viewContext available", category: "ChatManagementService")
            return
        }

        let chatId = chat.id
        let otherUser = chat.otherUser

        // Archive crypto session.
        if let userId = otherUser?.id, CryptoManager.shared.hasSession(for: userId) {
            CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
            Log.info("🗑️ Archived crypto session for user: \(userId)", category: "ChatManagementService")
        }

        // Delete only the Chat (cascade removes Messages).
        // User entity is intentionally kept — contact lives in Synaps.
        context.delete(chat)

        do {
            try context.save()
            Log.info("✅ Chat deleted (contact retained): \(chatId)", category: "ChatManagementService")
            onChatDeleted?(chatId)
        } catch {
            Log.error("❌ Failed to delete chat: \(error)", category: "ChatManagementService")
        }
    }

    /// Fully remove a contact: delete User, associated Chat + Messages, session, and
    /// add to DeletedContactsStore so future messages from this person are ignored.
    ///
    /// This is the "prune synapse" action — irreversible from within the app.
    func pruneContact(userId: String) {
        guard let context = viewContext else {
            Log.error("❌ ChatManagementService: No viewContext available", category: "ChatManagementService")
            return
        }

        let userFetch = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "id == %@", userId)
        guard let user = (try? context.fetch(userFetch))?.first else {
            Log.info("⚠️ pruneContact: user \(userId.prefix(8)) not found", category: "ChatManagementService")
            return
        }

        // Archive crypto session if one exists.
        if CryptoManager.shared.hasSession(for: userId) {
            CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
        }

        // Delete the associated chat (if any) — cascade removes Messages.
        if let chats = user.chats as? Set<Chat> {
            for chat in chats {
                let chatId = chat.id
                context.delete(chat)
                onChatDeleted?(chatId)
            }
        }

        // Block future message delivery from this contact.
        DeletedContactsStore.shared.add(userId)
        context.delete(user)

        do {
            try context.save()
            Log.info("✂️ Synapse pruned: \(userId.prefix(8))…", category: "ChatManagementService")
        } catch {
            Log.error("❌ Failed to prune contact: \(error)", category: "ChatManagementService")
        }
    }
}
