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
    static func isCallableContact(_ userId: String) -> Bool {
        guard !userId.isEmpty, let contact = try? LocalRepositories.contacts.contact(userId) else { return false }
        return contact.isContact && !contact.isBlocked
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

        // Making someone a contact is the user's own act (scan, accept, our invite redeemed), so
        // an earlier prune stops shielding. The inviter side used to leave the flag set: it
        // opened the session itself, the peer answered with mid-ratchet traffic only, and
        // `MessageRouter` dropped all of it as "from deleted contact" — no handshake ever
        // arrived to clear it (2026-10-05, one-way chat after delete and re-add).
        DeletedContactsStore.shared.remove(userId)

        let contacts = LocalRepositories.contacts
        let now = Date()
        try contacts.insert(.new(id: userId, isContact: true, addedAt: now))
        try contacts.markContact(userId, addedAt: now)
        guard let row = try contacts.contact(userId) else { throw ContactLinkError.emptyUserId }

        // The server username's rule (`ContactName.applyingServerUsername`), then an explicit
        // display name that is not a placeholder — unless they shared their profile with us,
        // whose name outranks both.
        var names = ContactName.applyingServerUsername(
            username, username: row.username, displayName: row.displayName,
            isSharingWithMe: row.isSharingWithMe, id: userId
        )
        if let dn = displayName, !dn.isEmpty, !row.isSharingWithMe {
            let isPlaceholder = UUID(uuidString: dn) != nil || dn.lowercased() == "anonymous"
            if !isPlaceholder { names.displayName = dn }
        }
        if names.username != row.username || names.displayName != row.displayName {
            try contacts.setNames(userId, username: names.username, displayName: names.displayName)
        }

        if let key = identityPublicKey, !key.isEmpty {
            pinKnownIdentityKey(contactId: userId, identityKey: key)
        }

        return try User.row(userId, in: context)
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

        let user = try createOrUpdateContact(
            userId: info.userId,
            username: usernameForStore,
            displayName: nil,
            identityPublicKey: info.identityPublicKey,
            context: context
        )
        // Same rule as `ChatManagementService.startChat`: the signed invite outranks a card.
        if let address = info.accountAddress,
           AccountAddress.pin(address, contactId: info.userId, source: .invite) != .unchanged {
            context.refresh(user, mergeChanges: true)
        }
        return user
    }

    /// Pin inviter identity key from an OOB-verified invite (TOFU).
    /// Does **not** mark KT `.verified` — that remains for Merkle audit.
    ///
    /// The invite names one device of the account, and that device joins the account's pinned
    /// set. A different key from the one pinned before is not an event by itself: an invite from
    /// the contact's other device carries exactly that. A device outside the set the server has
    /// listed for the account is, and `SessionAddressing.recordDevices` raises it
    /// (`decisions/a-new-device-is-the-security-event.md`). The account slot takes the invite's
    /// key — it is the freshest one checked out of band.
    func pinKnownIdentityKey(contactId: String, identityKey: Data) {
        guard !identityKey.isEmpty, !contactId.isEmpty else { return }
        let contacts = LocalRepositories.contacts
        guard let row = try? contacts.contact(contactId) else {
            Log.error(
                "IK_PIN[no_row]: dropping identity key for \(contactId.prefix(8))… — no User row (source=invite)",
                category: "ContactLink"
            )
            return
        }
        if row.knownIdentityKey != identityKey {
            do {
                try contacts.setIdentityKey(contactId, identityKey)
                Log.info("TOFU: pinned knownIdentityKey for \(contactId.prefix(8))… from invite", category: "ContactLink")
            } catch {
                Log.error("IK_PIN[save_failed]: \(contactId.prefix(8))… (source=invite): \(error)", category: "ContactLink")
            }
        }
        SessionAddressing.recordDevices(
            [(deviceId: deriveDeviceId(identityPublicKey: identityKey), identityKey: identityKey)],
            ofPeer: contactId
        )
    }

    /// Keep a peer's identity key when nothing else did — the backstop for the sealed-sender
    /// send paths, which cannot seal without it.
    ///
    /// Three sites hold a peer's identity key and each independently decides whether to keep it:
    /// `updateContactKTStatus` (writes only on `.verified`, and bails silently when no `User` row
    /// exists), this file's invite TOFU, and `startChat`. (A fourth, `recordAndCheckHybrid`, went
    /// with the Swift hybrid-bundle check in PQXDH v2.) When none of them kept it, `knownIdentityKey` stays nil, `recipientIdentityKey`
    /// returns nil, and every sealed send to that peer fails closed with `StealthDowngradeBlocked`
    /// — a permanent, silent stall on session control (TODO #45).
    ///
    /// This never *overrides* an existing pin: which key the account slot holds is the KT path's
    /// and the invite path's decision. It only fills an absence. (A substituted key is raised from
    /// the device set, not from this slot — `decisions/a-new-device-is-the-security-event.md`.)
    ///
    /// Pinning here extends no trust we have not already extended: the same `identityPublic` is
    /// what X3DH is about to run against. `ktStatus` continues to carry the verification verdict
    /// separately — pinned is not verified.
    ///
    /// - Parameter createIfMissing: whether a missing `User` row may be created to hold the key.
    ///
    ///   True for a prekey-bundle fetch: **we** asked for that user, a session with them is being
    ///   established, and the row is needed either way. It is created as a non-contact, since
    ///   fetching a bundle is not the user adding someone.
    ///
    ///   False for anything driven by an **incoming** envelope. A sender we have never heard of —
    ///   or have deliberately deleted — must not be able to put a row in our store by sending to
    ///   us. Device logs 2026-08-19: a deleted contact came back after every deletion, because the
    ///   server keeps replaying their backlog (`since_cursor` is not honoured) and each replayed
    ///   sealed envelope re-created the row through this method. `IK_PIN[row_created] … source=
    ///   sealed_cert` is that happening. Pinning a key for someone we do not have is also pointless
    ///   on its own terms: the key exists to let a sealed *send* proceed, and there is nobody to
    ///   send to.
    func rememberIdentityKeyIfUnknown(
        userId: String,
        identityKey: Data,
        source: String,
        createIfMissing: Bool
    ) {
        guard !userId.isEmpty, !identityKey.isEmpty else {
            Log.error(
                "IK_PIN[empty]: nothing to pin for \(userId.prefix(8))… (source=\(source), key=\(identityKey.count)B)",
                category: "ContactLink"
            )
            return
        }
        let contacts = LocalRepositories.contacts
        do {
            if let existing = try contacts.contact(userId) {
                guard existing.knownIdentityKey == nil else { return }
                try contacts.setIdentityKey(userId, identityKey)
            } else {
                guard createIfMissing else {
                    Log.info(
                        "IK_PIN[no_row]: no User row for \(userId.prefix(8))… — not creating one (source=\(source))",
                        category: "ContactLink"
                    )
                    return
                }
                var row = ContactRecord.new(id: userId, isContact: false, addedAt: Date())
                let names = ContactName.applyingServerUsername(
                    nil, username: "", displayName: "", isSharingWithMe: false, id: userId
                )
                row.username = names.username
                row.displayName = names.displayName
                row.knownIdentityKey = identityKey
                try contacts.insert(row)
                Log.info(
                    "IK_PIN[row_created]: no User row for \(userId.prefix(8))… — created one to hold the identity key (source=\(source))",
                    category: "ContactLink"
                )
            }
        } catch {
            // A write that fails here loses the identity key: the sealed send paths stop for this
            // peer. Said, never swallowed.
            Log.error(
                "IK_PIN[save_failed]: identity key for \(userId.prefix(8))… not kept (source=\(source)): \(error)",
                category: "ContactLink"
            )
            return
        }
        Log.info(
            "IK_PIN[pinned]: \(userId.prefix(8))… (source=\(source))",
            category: "ContactLink"
        )
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
