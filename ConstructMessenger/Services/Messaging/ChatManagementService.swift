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
    /// - Parameters:
    ///   - user: Public user information from invite
    ///   - identityPublicKey: Optional TOFU pin from a verified invite (thread 5.1)
    /// - Returns: Created or existing chat, nil if context is unavailable
    func startChat(with user: PublicUserInfo, identityPublicKey: Data? = nil) -> Chat? {
        guard let context = viewContext else { 
            Log.error("ChatManagementService: No viewContext available", category: "ChatManagementService")
            return nil 
        }

        if user.id == AuthSessionManager.shared.currentUserId {
            Log.info("Self-chat detected — use Drafts instead", category: "ChatManagementService")
            return nil
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

        if let key = identityPublicKey, !key.isEmpty {
            ContactLinkService.shared.pinKnownIdentityKey(on: dbUser, identityKey: key)
        }

        // 1:1 Chat per User — shared finder (also collapses accidental duplicates).
        let result = Chat.findOrCreate(
            for: dbUser,
            in: context,
            touchLastMessageTimeOnCreate: true
        )
        // Re-scan / re-open should still surface the row at the top of the list.
        if !result.created, result.chat.lastMessageTime == nil {
            result.chat.lastMessageTime = Date()
        }

        do {
            try context.save()
            Log.debug(
                "Chat \(result.created ? "created" : "reused"): id=\(result.chat.id) user=\(user.username)",
                category: "ChatManagementService"
            )
            if result.created {
                onChatCreated?(result.chat)
            }
            return result.chat
        } catch {
            Log.error("Failed to save chat: \(error)", category: "ChatManagementService")
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
            Log.error("ChatManagementService: No viewContext available", category: "ChatManagementService")
            return
        }

        let chatId = chat.id
        let otherUser = chat.otherUser

        // Archive crypto session. `hasStoredSessionState`, not `hasSession`: the latter sees only
        // what the core has loaded, and a chat nobody opened this run has its session on disk
        // only — so this guard used to skip, leaving a Keychain entry with no contact attached.
        if let userId = otherUser?.id, CryptoManager.shared.hasStoredSessionState(for: userId) {
            CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
            Log.info("Archived crypto session for user: \(userId)", category: "ChatManagementService")
        }

        // Delete only the Chat (cascade removes Messages).
        // User entity is intentionally kept — contact lives in Synaps.
        context.delete(chat)

        do {
            try context.save()
            Log.info("Chat deleted (contact retained): \(chatId)", category: "ChatManagementService")
            onChatDeleted?(chatId)
        } catch {
            Log.error("Failed to delete chat: \(error)", category: "ChatManagementService")
        }
    }

    /// Fully remove a contact: delete User, associated Chat + Messages, session, and
    /// add to DeletedContactsStore so future messages from this person are ignored.
    ///
    /// This is the "prune synapse" action — irreversible from within the app.
    func pruneContact(userId: String) {
        guard let context = viewContext else {
            Log.error("ChatManagementService: No viewContext available", category: "ChatManagementService")
            return
        }

        let userFetch = User.fetchRequest()
        userFetch.predicate = NSPredicate(format: "id == %@", userId)
        guard let user = (try? context.fetch(userFetch))?.first else {
            Log.info("pruneContact: user \(userId.prefix(8)) not found", category: "ChatManagementService")
            return
        }

        // Archive crypto session if one exists — in the core or on disk. Pruning is the
        // irreversible action of the two, so leaving an unreachable session behind here is the
        // worse half of the same defect: the contact is gone from every list and its ratchet is
        // still in the Keychain, ready to be picked up by the next pairing with the same person.
        if CryptoManager.shared.hasStoredSessionState(for: userId) {
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
            Log.info("Synapse pruned: \(userId.prefix(8))…", category: "ChatManagementService")
        } catch {
            Log.error("Failed to prune contact: \(error)", category: "ChatManagementService")
        }
    }
}
