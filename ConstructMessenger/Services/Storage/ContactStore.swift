//
//  ContactStore.swift
//  Construct Messenger
//
//  The people we hold a row for, and our own profile, as repositories: values in, values out, no
//  managed object and no context. The contacts domain of the storage seam
//  (`client/specs/LOCAL_STORE_MIGRATION_PLAN.md` step 1). Core Data answers today; `LocalStore`
//  (construct-store schema 2, construct-core 0.35.0) takes over on macOS in step 3, with
//  `contact`, `every_contact`, `sharing_with`, `identity_key_pins` and `own_profile`.
//
//  Reads first. The writes — the field-by-field operations the crate already has — come in the
//  next step, with their callers.
//

import Foundation
import CoreData

/// One person we hold a row for: a contact, or someone we only hold a key or a blocked flag for.
/// Never our own account — that is `OwnProfileRecord`.
struct ContactRecord: Equatable, Sendable {
    let id: String
    var username: String
    var displayName: String
    /// The name the user gave them; never leaves the device.
    var localAlias: String?
    var avatar: Data?
    /// The identity key pinned for the account — one slot. The device set is `PeerDeviceStore`.
    var knownIdentityKey: Data?
    var accountAddress: Data?
    var isContact: Bool
    var isBlocked: Bool
    var isSharingWithMe: Bool
    var amISharingWith: Bool
    var sharedWithMeAt: Date?
    var addedAt: Date?
    var ktStatus: KTStatus
    var securityNotice: SecurityNotice
    var profileEditedAtMs: Int64
    var pendingAvatarRef: Data?
    var pendingAvatarSince: Date?

    var resolvedDisplayName: String {
        ContactName.resolved(alias: localAlias, displayName: displayName, username: username, id: id)
    }

    var trustAlert: ContactTrustAlert? {
        ContactTrustAlert(notice: securityNotice, ktStatus: ktStatus)
    }
}

/// Our own profile — what we share with the people we share it with.
struct OwnProfileRecord: Equatable, Sendable {
    let accountId: String
    var username: String
    var displayName: String
    var avatar: Data?
    var profileEditedAtMs: Int64
}

struct IdentityKeyPin: Equatable, Sendable {
    let contactId: String
    let key: Data
}

/// Reading the people we hold a row for.
///
/// `ownAccountId` exists for the Core Data store, which keeps our profile as a row of the same
/// table; a store that keeps it apart (`LocalStore`) ignores it. The caller passes it because "who
/// am I" is `AuthSessionManager`'s, on the main actor, and a store reading it a second way would
/// be a second carrier of it.
protocol ContactStore: Sendable {
    func contact(_ id: String) throws -> ContactRecord?

    /// Whether `id` is blocked — the receive path asks this of every message.
    func isBlocked(_ id: String) throws -> Bool

    /// Everyone we hold a row for, contacts or not, by id.
    func everyContact(except ownAccountId: String?) throws -> [ContactRecord]

    /// The ids we share our profile with, sorted.
    func sharingWith(except ownAccountId: String?) throws -> [String]

    /// Every pinned identity key, by contact id.
    func identityKeyPins() throws -> [IdentityKeyPin]
}

/// Reading our own profile. `accountId` as for `ContactStore`.
protocol OwnProfileStore: Sendable {
    func profile(accountId: String) throws -> OwnProfileRecord?
}

/// `User` rows. Each call runs on a fresh background context, for the reason
/// `CoreDataPeerDeviceStore` gives; it therefore sees what is saved, never another context's
/// pending changes.
final class CoreDataContactStore: ContactStore, OwnProfileStore, @unchecked Sendable {

    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func contact(_ id: String) throws -> ContactRecord? {
        try fetch(NSPredicate(format: "id == %@", id), limit: 1).first
    }

    func isBlocked(_ id: String) throws -> Bool {
        try run { context in
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@ AND isBlocked == YES", id)
            req.fetchLimit = 1
            return try context.count(for: req) > 0
        }
    }

    func everyContact(except ownAccountId: String?) throws -> [ContactRecord] {
        try fetch(NSPredicate(format: "id != %@", ownAccountId ?? ""))
    }

    func sharingWith(except ownAccountId: String?) throws -> [String] {
        try fetch(NSPredicate(format: "amISharingWith == YES AND id != %@", ownAccountId ?? "")).map(\.id)
    }

    func identityKeyPins() throws -> [IdentityKeyPin] {
        try run { context in
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "knownIdentityKey != nil")
            req.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            return try context.fetch(req).compactMap { user in
                guard let key = user.knownIdentityKey, !key.isEmpty, !user.id.isEmpty else { return nil }
                return IdentityKeyPin(contactId: user.id, key: key)
            }
        }
    }

    func profile(accountId: String) throws -> OwnProfileRecord? {
        guard !accountId.isEmpty else { return nil }
        return try run { context in
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", accountId)
            req.fetchLimit = 1
            return try context.fetch(req).first.map {
                OwnProfileRecord(
                    accountId: $0.id, username: $0.username, displayName: $0.displayName,
                    avatar: $0.avatarData, profileEditedAtMs: $0.profileEditedAtMs
                )
            }
        }
    }

    private func fetch(_ predicate: NSPredicate, limit: Int = 0) throws -> [ContactRecord] {
        try run { context in
            let req = User.fetchRequest()
            req.predicate = predicate
            req.fetchLimit = limit
            req.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            return try context.fetch(req).map(ContactRecord.init(row:))
        }
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}

extension ContactRecord {
    /// `publicKey` and `hybridCapable` are left out on purpose: nothing writes or reads them.
    init(row user: User) {
        self.init(
            id: user.id, username: user.username, displayName: user.displayName,
            localAlias: user.localAlias, avatar: user.avatarData,
            knownIdentityKey: user.knownIdentityKey, accountAddress: user.accountAddress,
            isContact: user.isContact, isBlocked: user.isBlocked,
            isSharingWithMe: user.isSharingWithMe, amISharingWith: user.amISharingWith,
            sharedWithMeAt: user.sharedWithMeAt, addedAt: user.addedAt,
            ktStatus: user.ktStatus, securityNotice: user.securityNotice,
            profileEditedAtMs: user.profileEditedAtMs,
            pendingAvatarRef: user.pendingAvatarRef, pendingAvatarSince: user.pendingAvatarSince
        )
    }
}
