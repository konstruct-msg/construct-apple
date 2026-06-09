//
//  User+CoreDataProperties.swift
//  Construct Messenger
//

import Foundation
import CoreData

// MARK: - Key Transparency status per contact

/// Reflects the result of the last Key Transparency verification for this contact.
enum KTStatus: Int16 {
    /// No bundle has been fetched yet (new contact, or no session established).
    case unverified = 0
    /// Last verification succeeded and identity key matches the Merkle log.
    case verified = 1
    /// Identity key changed since the last verified bundle — requires user acknowledgement.
    case keyChanged = 2
    /// Last verification failed (proof invalid, signature mismatch, etc.).
    case failed = 3
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

    // MARK: Key Transparency

    /// The raw identity key bytes from the last successfully KT-verified bundle.
    /// `nil` until the first successful verification.
    @NSManaged public var knownIdentityKey: Data?

    /// Raw `KTStatus` value stored in Core Data. Use `ktStatus` accessor.
    @NSManaged public var ktStatusRaw: Int16

    /// Typed Key Transparency status for this contact.
    var ktStatus: KTStatus {
        get { KTStatus(rawValue: ktStatusRaw) ?? .unverified }
        set { ktStatusRaw = newValue.rawValue }
    }

    /// Hybrid PQ downgrade protection (Phase 3). `true` once a valid hybrid bundle has been seen
    /// for the current `knownIdentityKey`. A subsequent Ed25519-only bundle for the same identity
    /// is treated as a downgrade attack and rejected. Reset when the identity key changes.
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
