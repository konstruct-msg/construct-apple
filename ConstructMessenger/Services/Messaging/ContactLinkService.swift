//
//  ContactLinkService.swift
//  Construct Messenger
//
//  Creates or updates a contact User entity in CoreData from server-provided
//  identity data (contact request acceptance, invite redemption, etc.).
//
//  Display name priority (same as User+DisplayName.swift):
//    1. server displayName if non-empty and not a placeholder
//    2. server username if non-empty and not a UUID / "anonymous"
//    3. generated deterministic fallback via DisplayNameGenerator
//

import Foundation
import CoreData

/// Local mutuality / block policy for sealed-sender-safe gates (calls, etc.).
enum ContactPolicy {
    /// True when the peer is a local contact and not blocked.
    /// Call permission under sealed sender is **client-authoritative** —
    /// server reciprocity cannot survive when the server does not see the caller.
    static func isCallableContact(_ userId: String, in context: NSManagedObjectContext) -> Bool {
        guard !userId.isEmpty else { return false }
        if BlockedContacts.isBlocked(userId, in: context) { return false }
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@ AND isContact == YES", userId)
        fetch.fetchLimit = 1
        return ((try? context.count(for: fetch)) ?? 0) > 0
    }
}

@MainActor
final class ContactLinkService {

    static let shared = ContactLinkService()
    private init() {}

    // MARK: - Create or update contact

    /// Creates or updates a `User` entity in CoreData for the given remote contact.
    ///
    /// - Parameters:
    ///   - userId: Remote user ID (non-empty UUID string).
    ///   - username: Server username handle (may be nil/empty → falls back to displayName or generated).
    ///   - displayName: Human-readable name provided by the server (may be nil/empty).
    ///   - identityPublicKey: Optional TOFU pin from a verified invite (thread 5.1).
    ///   - context: Managed object context to save into.
    /// - Returns: The created or updated `User` entity.
    @discardableResult
    func createOrUpdateContact(
        userId: String,
        username: String?,
        displayName: String?,
        identityPublicKey: Data? = nil,
        context: NSManagedObjectContext
    ) throws -> User {
        guard !userId.isEmpty else { throw ContactLinkError.emptyUserId }

        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        let user: User
        if let existing = try context.fetch(fetchRequest).first {
            user = existing
        } else {
            user = User(context: context)
            user.id = userId
            user.addedAt = Date()
            user.isBlocked = false
            user.isSharingWithMe = false
            user.amISharingWith = false
        }

        user.isContact = true

        // applyServerUsername handles username priority and sets displayName to
        // the username when no profile-shared name is present.
        user.applyServerUsername(username, userId: userId)

        // If the server provided an explicit displayName that is not a placeholder,
        // prefer it over the username-derived name — unless isSharingWithMe is true
        // (in that case the contact already shared their real name with us).
        if let dn = displayName, !dn.isEmpty, !user.isSharingWithMe {
            let isPlaceholder = UUID(uuidString: dn) != nil || dn.lowercased() == "anonymous"
            if !isPlaceholder {
                user.displayName = dn
            }
        }

        if let key = identityPublicKey, !key.isEmpty {
            pinKnownIdentityKey(on: user, identityKey: key)
        }

        try context.save()
        return user
    }

    /// Apply a verified invite redeem: ensure contact + optional TOFU identity pin.
    /// Prefer this over raw `startChat` when `ContactInfo.identityPublicKey` is present.
    @discardableResult
    func applyInviteRedeem(
        _ info: ContactInfo,
        context: NSManagedObjectContext
    ) throws -> User {
        let usernameForStore: String? = {
            let trimmed = info.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            // LinkParser uses userId as placeholder when `un` is absent.
            if trimmed == info.userId { return nil }
            if UUID(uuidString: trimmed) != nil { return nil }
            return trimmed
        }()

        return try createOrUpdateContact(
            userId: info.userId,
            username: usernameForStore,
            displayName: nil,
            identityPublicKey: info.identityPublicKey,
            context: context
        )
    }

    /// Pin inviter identity key from an OOB-verified invite (TOFU).
    /// Does **not** mark KT `.verified` — that remains for Merkle audit.
    /// On mismatch with a previously pinned key → `.keyChanged` + notification.
    func pinKnownIdentityKey(on user: User, identityKey: Data) {
        guard !identityKey.isEmpty else { return }
        if let known = user.knownIdentityKey, known != identityKey {
            user.ktStatus = .keyChanged
            user.knownIdentityKey = identityKey
            Log.error(
                "TOFU: identity key changed for user \(user.id.prefix(8))…",
                category: "ContactLink"
            )
            NotificationCenter.default.post(
                name: .contactKeyChanged,
                object: nil,
                userInfo: ["userId": user.id]
            )
            KeyChangeUX.notifyKeyChange(
                userId: user.id,
                displayName: user.resolvedDisplayName
            )
        } else if user.knownIdentityKey == nil {
            user.knownIdentityKey = identityKey
            Log.info(
                "TOFU: pinned knownIdentityKey for \(user.id.prefix(8))… from invite",
                category: "ContactLink"
            )
        }
    }

    /// Pin identity key for an existing user id (e.g. after `startChat` created the User).
    func pinKnownIdentityKey(userId: String, identityKey: Data, context: NSManagedObjectContext) {
        guard !identityKey.isEmpty else { return }
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", userId)
        fetch.fetchLimit = 1
        guard let user = try? context.fetch(fetch).first else { return }
        pinKnownIdentityKey(on: user, identityKey: identityKey)
        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - Invite-accepted (inviter side)

    /// Creates local contact when someone redeems our invite (`invite_accepted` push).
    /// Needed so both sides have `isContact` for client call mutuality.
    @discardableResult
    func handleInviteAccepted(peerUserId: String) async -> User? {
        let context = PersistenceController.shared.container.viewContext
        guard !peerUserId.isEmpty else { return nil }
        if peerUserId == AuthSessionManager.shared.currentUserId { return nil }

        do {
            let user = try createOrUpdateContact(
                userId: peerUserId,
                username: nil,
                displayName: nil,
                context: context
            )
            Log.info(
                "Invite accepted: local contact created for \(peerUserId.prefix(8))…",
                category: "ContactLink"
            )
            NotificationCenter.default.post(
                name: .inviteAcceptedContactCreated,
                object: nil,
                userInfo: ["userId": peerUserId]
            )
            InviteRedeemUX.presentInviterNotice(peerUserId: peerUserId)
            return user
        } catch {
            Log.error(
                "Invite accepted: failed to create contact for \(peerUserId.prefix(8))…: \(error)",
                category: "ContactLink"
            )
            return nil
        }
    }

    // MARK: - Errors

    enum ContactLinkError: LocalizedError {
        case emptyUserId

        var errorDescription: String? {
            switch self {
            case .emptyUserId: return "Contact user ID must not be empty."
            }
        }
    }
}

extension Notification.Name {
    /// Someone redeemed our invite — local contact created (inviter device).
    static let inviteAcceptedContactCreated = Notification.Name("construct.inviteAcceptedContactCreated")
}
