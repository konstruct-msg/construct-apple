//
//  ChatManagementService.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 02.02.2026.
//

import Foundation

/// Manages chat lifecycle: creation from invites and deletion with cleanup
/// Extracted from ChatsViewModel Phase 1.6
@MainActor
class ChatManagementService {
    
    // MARK: - Chat Creation
    
    /// Start a new chat with a user (from invite link or QR code)
    /// - Parameters:
    ///   - user: Public user information from invite
    ///   - identityPublicKey: Optional TOFU pin from a verified invite (thread 5.1)
    /// - Returns: Created or existing chat, nil if it could not be written
    func startChat(
        with user: PublicUserInfo,
        identityPublicKey: Data? = nil,
        accountAddress: Data? = nil
    ) -> ChatRecord? {
        if user.id == AuthSessionManager.shared.currentUserId {
            Log.info("Self-chat detected — use Drafts instead", category: "ChatManagementService")
            return nil
        }
        
        // If this user was previously deleted, remove from deleted store so messages
        // from them are no longer silently discarded.
        DeletedContactsStore.shared.remove(user.id)

        // The contact row, through the repository: created as a contact, or marked one, with the
        // names the server username leaves.
        let contacts = LocalRepositories.contacts
        do {
            let now = Date()
            if let existing = try contacts.contact(user.id) {
                let names = ContactName.applyingServerUsername(
                    user.username, username: existing.username, displayName: existing.displayName,
                    isSharingWithMe: existing.isSharingWithMe, id: user.id
                )
                try contacts.setNames(user.id, username: names.username, displayName: names.displayName)
                if !existing.isContact { try contacts.markContact(user.id, addedAt: now) }
                Log.debug("Using existing user: id=\(user.id), username=\(user.username), displayName=\(names.displayName)", category: "ChatManagementService")
            } else {
                var row = ContactRecord.new(id: user.id, isContact: true, addedAt: now)
                let names = ContactName.applyingServerUsername(
                    user.username, username: "", displayName: "", isSharingWithMe: false, id: user.id
                )
                row.username = names.username
                row.displayName = names.displayName
                try contacts.insert(row)
                Log.debug("Created new user: id=\(user.id), username=\(user.username), displayName=\(names.displayName)", category: "ChatManagementService")
            }

            if let key = identityPublicKey, !key.isEmpty {
                ContactLinkService.shared.pinKnownIdentityKey(contactId: user.id, identityKey: key)
            }
            // From the signed invite, already checked by the server against the account's recovery
            // key — it outranks a card, and a different one is a security event either way.
            if let address = accountAddress {
                AccountAddress.pin(address, contactId: user.id, source: .invite)
            }
        } catch {
            Log.error("ChatManagementService: contact \(user.id.prefix(8))… not written: \(error)", category: "ChatManagementService")
            return nil
        }

        // One chat per person; a re-scan or re-open still surfaces it at the top of the list.
        do {
            let result = try LocalRepositories.chats.openChat(withPeer: user.id)
            Log.debug(
                "Chat \(result.created ? "created" : "reused"): id=\(result.chat.id) user=\(user.username)",
                category: "ChatManagementService"
            )
            return result.chat
        } catch {
            Log.error("Failed to save chat: \(error)", category: "ChatManagementService")
            return nil
        }
    }

    // MARK: - Chat Deletion

    /// Remove the conversation from this device, and nothing else.
    ///
    /// Split out from `deleteChat` because the two halves have different deadlines. This one is
    /// what the person asked for and it depends on nothing: no network, no session, no peer. It
    /// must therefore land **before** anything that can block or die, which is the opposite of the
    /// order it used to run in.
    ///
    /// 2026-09-04 16:16:49 a delete was requested; the app died two seconds later while the
    /// END_SESSION it was waiting on was still in flight, and the conversation was there again on
    /// the next launch. The row had already gone from the list, so for those two seconds the
    /// screen and the store disagreed about something the user had been told was done.
    func deleteChatLocally(_ chatId: String) {
        do {
            // The chat and its messages; the contact stays — it lives in Synaps.
            try LocalRepositories.chats.delete(chatId)
            Log.info("Chat deleted (contact retained): \(chatId)", category: "ChatManagementService")
        } catch {
            Log.error("Failed to delete chat: \(error)", category: "ChatManagementService")
        }
    }

    /// Retire every stored session with this peer.
    ///
    /// Runs **after** any END_SESSION the caller wants to send, because sending one needs the
    /// session this destroys. Takes the peer id rather than the chat: by the time it is called the
    /// chat row may already be gone, which is the point.
    ///
    /// `hasStoredSessionState`, not `hasSession`: the latter sees only what the core has loaded,
    /// and a chat nobody opened this run has its session on disk only — so this guard used to
    /// skip, leaving a Keychain entry with no contact attached.
    func archiveSessions(ofPeer userId: String) {
        guard CryptoManager.shared.hasStoredSessionStateForAnyDevice(ofPeer: userId) else { return }
        let retired = CryptoManager.shared.archiveAllSessions(ofPeer: userId, reason: .manualReset)
        Log.info("Archived \(retired) crypto session(s) for user: \(userId)", category: "ChatManagementService")
    }

    /// Fully remove a contact: delete User, associated Chat + Messages, session, and
    /// add to DeletedContactsStore so future messages from this person are ignored.
    ///
    /// This is the "prune synapse" action — irreversible from within the app.
    /// Remove the contact, its chats and its messages from this device.
    ///
    /// Local only, and deliberately so. Whether the person may still write to us is the block
    /// button's question and the server answers it (`is_blocked_by`, checked before delivery);
    /// this one answers "what do I keep". Two controls that both partly refuse would be one
    /// meaning with two carriers, and the weaker carrier is this one — a client-side refusal
    /// still costs the delivery, the battery and the decrypt attempt.
    ///
    /// Sessions are **not** archived here. The caller announces the teardown first, and an
    /// announcement needs the session this would destroy — see `ChatsViewModel.pruneContact`.
    func pruneContactLocally(userId: String) {
        do {
            // The contact, its chat and the chat's messages.
            guard try LocalRepositories.contacts.delete(userId) else {
                Log.info("pruneContact: user \(userId.prefix(8)) not found", category: "ChatManagementService")
                return
            }
            // Not a block: a short-lived shield against the server replaying this contact's
            // backlog straight back into a fresh row. See `DeletedContactsStore`.
            DeletedContactsStore.shared.add(userId)
            Log.info("Synapse pruned: \(userId.prefix(8))…", category: "ChatManagementService")
        } catch {
            Log.error("Failed to prune contact: \(error)", category: "ChatManagementService")
        }
    }
}
