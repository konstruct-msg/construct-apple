//
//  User+CoreDataProperties.swift
//  Construct Messenger
//

import Foundation
import CoreData

// MARK: - Key Transparency status per contact

/// Reflects the result of the last Key Transparency verification for this contact.
enum KTStatus: Int16, Sendable {
    /// No bundle has been fetched yet (new contact, or no session established).
    case unverified = 0
    /// Last verification succeeded and identity key matches the Merkle log.
    case verified = 1
    /// No longer written. It meant "the one key we pinned for this account differs from the one
    /// just fetched", which a second device of the contact always satisfied. The value stays
    /// readable because stored rows may carry it; nothing raises an alert for it.
    case keyChanged = 2
    /// Last verification failed (proof invalid, signature mismatch, etc.).
    case failed = 3
}

// MARK: - Security events per contact

/// A security event about a contact, kept until the user acknowledges it. Same values as Android's
/// `SecurityNotice`.
///
/// 2 was "a device the contact's account did not have" from 2026-09-29 to 09-30. It could not tell
/// a device the contact linked from one the server added, so every honest link warned every
/// contact that someone may be reading along. It returns once a new device carries a signature by
/// one we already know (`decisions/new-device-alarm-waits-for-cross-signing.md`). Stored rows with
/// 2 read as `.none` through `securityNotice`, and the value is not reused.
enum SecurityNotice: Int16, Sendable {
    case none = 0
    /// The contact named an account address other than the one pinned for them.
    case addressChanged = 1
}

/// The warning shown for a contact, whichever source raised it.
enum ContactTrustAlert: Equatable, Sendable {
    case addressChanged
    /// The key server's proof for their bundle did not verify.
    case verificationFailed

    /// A pending event outranks a failed proof: it is the one the user has to acknowledge.
    init?(notice: SecurityNotice, ktStatus: KTStatus) {
        switch notice {
        case .addressChanged: self = .addressChanged
        case .none:
            guard ktStatus == .failed else { return nil }
            self = .verificationFailed
        }
    }

    var titleKey: String {
        switch self {
        case .addressChanged: return "security_notice_address_title"
        case .verificationFailed: return "key_change_banner_title_failed"
        }
    }

    func subtitle(contactName: String) -> String {
        switch self {
        case .addressChanged:
            return String(format: NSLocalizedString("security_notice_address_body_fmt", comment: ""), contactName)
        case .verificationFailed:
            return NSLocalizedString("key_change_banner_subtitle_failed", comment: "")
        }
    }
}

// MARK: - User Core Data properties

extension User {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<User> {
        return NSFetchRequest<User>(entityName: "User")
    }

    @NSManaged public var id: String
    @NSManaged public var username: String
    @NSManaged public var displayName: String
    @NSManaged public var publicKey: String?
    @NSManaged public var avatarData: Data?
    @NSManaged public var isSharingWithMe: Bool
    @NSManaged public var isBlocked: Bool
    @NSManaged public var sharedWithMeAt: Date?
    @NSManaged public var amISharingWith: Bool
    /// True when the user has been explicitly added as a Synaps contact.
    /// Persists across chat deletions — use pruneContact() to fully remove.
    @NSManaged public var isContact: Bool
    /// When the contact was first added (link, code, or incoming message).
    @NSManaged public var addedAt: Date?

    /// Local-only display override the user assigns to this contact. Never sent to the
    /// server or the contact — purely a presentation alias, resolved first in
    /// `resolvedDisplayName`. `nil`/empty means "use the server/generated name".
    @NSManaged public var localAlias: String?

    // MARK: Key Transparency

    /// The raw identity key bytes from the last successfully KT-verified bundle.
    /// `nil` until the first successful verification.
    @NSManaged public var knownIdentityKey: Data?
    /// Their account address (Ed25519 recovery public key), from their signed invite. Sealed
    /// sends name the recipient by it; nil for a contact added before invites carried it.
    @NSManaged public var accountAddress: Data?

    // MARK: Profile (model 14)

    /// `edited_at_ms` of the last typed profile (content type 29) applied for this contact; 0 when
    /// none has been. On our own row: when we last changed our name or avatar — what our profile
    /// carries, so a profile sent again is not mistaken for a newer one.
    /// decisions/profile-share-is-a-typed-versioned-state.md
    @NSManaged public var profileEditedAtMs: Int64
    /// An avatar a profile named that has not been downloaded yet (`AvatarRef` proto bytes).
    /// Retried on every stream connect until it arrives, the media store says it is gone, or it is
    /// older than the media store keeps anything.
    @NSManaged public var pendingAvatarRef: Data?
    @NSManaged public var pendingAvatarSince: Date?

    /// Raw `SecurityNotice` value stored in Core Data. Use `securityNotice`.
    @NSManaged public var securityNoticeRaw: Int16

    /// A security event about this contact the user has not acknowledged yet. Separate from
    /// `ktStatus` because that one is rewritten by every bundle fetch, and an event must stay until
    /// the user has seen it.
    var securityNotice: SecurityNotice {
        get { SecurityNotice(rawValue: securityNoticeRaw) ?? .none }
        set { securityNoticeRaw = newValue.rawValue }
    }

    /// What, if anything, the chat, the chat list and the profile warn about for this contact.
    var trustAlert: ContactTrustAlert? {
        ContactTrustAlert(notice: securityNotice, ktStatus: ktStatus)
    }

    /// Raw `KTStatus` value stored in Core Data. Use `ktStatus` accessor.
    @NSManaged public var ktStatusRaw: Int16

    /// Typed Key Transparency status for this contact.
    var ktStatus: KTStatus {
        get { KTStatus(rawValue: ktStatusRaw) ?? .unverified }
        set { ktStatusRaw = newValue.rawValue }
    }

    /// No longer written or read. It was the Swift downgrade pin for the hybrid identity (Phase 3);
    /// since PQXDH v2 the core refuses a bundle without a trusted hybrid identity outright and pins
    /// the hybrid key per device itself. The attribute stays so the Core Data model does not change.
    @NSManaged public var hybridCapable: Bool

    @NSManaged public var chats: NSSet?
}

// MARK: Generated accessors for chats
extension User {
    @objc(addChatsObject:)
    @NSManaged public func addToChats(_ value: Chat)

    @objc(removeChatsObject:)
    @NSManaged public func removeFromChats(_ value: Chat)

    @objc(addChats:)
    @NSManaged public func addToChats(_ values: NSSet)

    @objc(removeChats:)
    @NSManaged public func removeFromChats(_ values: NSSet)
}

extension User: Identifiable {

}
