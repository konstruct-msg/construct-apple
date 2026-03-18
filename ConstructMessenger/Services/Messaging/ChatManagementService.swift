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
            // Update raw server username always
            existingUser.username = normalizedUsername(from: user.username)
            // Only overwrite displayName if:
            //   a) the server provides a real (non-empty) username, OR
            //   b) the contact has NOT shared their profile with us yet
            // This prevents resetting a profile-shared name back to the generated one
            // when the server returns an empty/UUID username after app restart.
            let serverName = displayName(for: user)
            let serverHasRealName = !normalizedUsername(from: user.username).isEmpty
            if serverHasRealName || !existingUser.isSharingWithMe {
                existingUser.displayName = serverName
            }
            dbUser = existingUser
            Log.debug("Using existing user: id=\(user.id), username=\(user.username), displayName=\(existingUser.displayName)", category: "ChatManagementService")
        } else {
            // Create new user
            dbUser = User(context: context)
            dbUser.id = user.id
            dbUser.username = normalizedUsername(from: user.username)
            dbUser.displayName = displayName(for: user)
            dbUser.isSharingWithMe = false
            dbUser.isBlocked = false
            dbUser.amISharingWith = false
            Log.debug("Created new user: id=\(user.id), username=\(user.username), displayName=\(user.username)", category: "ChatManagementService")
        }
        
        // Create new chat
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = dbUser
        
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

    private func displayName(for user: PublicUserInfo) -> String {
        let normalized = normalizedUsername(from: user.username)
        if !normalized.isEmpty {
            return normalized
        }
        return DisplayNameGenerator.generate(from: user.id)
    }

    private func normalizedUsername(from value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if value.lowercased() == "anonymous" {
            return ""
        }
        if UUID(uuidString: value) != nil {
            return ""
        }
        return value
    }
    
    // MARK: - Chat Deletion
    
    /// Delete a chat and clean up all associated data
    /// - Parameter chat: Chat to delete
    /// - Note: Deletes messages, archives crypto sessions, clears shared secrets
    func deleteChat(_ chat: Chat) {
        guard let context = viewContext else {
            Log.error("❌ ChatManagementService: No viewContext available", category: "ChatManagementService")
            return
        }
        
        let chatId = chat.id
        let otherUser = chat.otherUser
        
        // Archive crypto session when deleting chat.
        // Skip if already cleared (e.g. by END_SESSION sent before this call).
        if let userId = otherUser?.id, CryptoManager.shared.hasSession(for: userId) {
            CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
            Log.info("🗑️ Archived crypto session for user: \(userId)", category: "ChatManagementService")
        }
        
        // Delete the chat (Core Data cascade rules will delete associated messages)
        context.delete(chat)
        
        // Also delete the User entity so the stream no longer subscribes to this contact
        // and findOrCreateChat cannot recreate an empty chat on restart.
        if let user = otherUser {
            // Persist the deletion so MessageRouter ignores future messages from this contact
            DeletedContactsStore.shared.add(user.id)
            context.delete(user)
            Log.info("🗑️ Deleted user entity: \(user.id)", category: "ChatManagementService")
        }
        
        do {
            try context.save()
            Log.info("✅ Chat deleted successfully: \(chatId)", category: "ChatManagementService")
            
            // Notify via callback
            onChatDeleted?(chatId)
        } catch {
            Log.error("❌ Failed to delete chat: \(error)", category: "ChatManagementService")
        }
    }
}
