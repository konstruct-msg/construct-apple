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
//  Writes are field by field, as the crate's are: each changes its named fields of one row and
//  nothing else, so two writers of different fields cannot undo each other. `false` means there
//  is no such row.
//

import Foundation
import CoreData

/// One person we hold a row for: a contact, or someone we only hold a key or a blocked flag for.
/// Never our own account — that is `OwnProfileRecord`.
struct ContactRecord: Equatable, Sendable, Identifiable {
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

extension OwnProfileRecord {
    /// Our name or avatar changed: the profile we send carries this as its version
    /// (`ProfileShare.editedAtMs`), so contacts apply it over the one they hold and ignore older ones.
    mutating func markEdited(now: Date = Date()) {
        profileEditedAtMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
    }
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

    /// People marked as contacts, by id. Shown in an order the screen picks for the reader's
    /// language (`ContactsLive.contacts`), which a store collation cannot.
    func contacts() throws -> [ContactRecord]

    /// The ids we share our profile with, sorted.
    func sharingWith(except ownAccountId: String?) throws -> [String]

    /// Every pinned identity key, by contact id.
    func identityKeyPins() throws -> [IdentityKeyPin]

    /// Rows with an avatar announced and not yet downloaded, by id.
    func contactsWithPendingAvatar() throws -> [ContactRecord]

    /// The ids of rows written or deleted, once per save — the replacement for `@FetchRequest` and
    /// `@ObservedObject User` on the screens (`ContactsLive`). Subscribe before the first read, or
    /// a write between the two is missed.
    func changes() -> AsyncStream<Set<String>>

    // MARK: Writes

    /// Adds the row unless one with its id exists; true when added. A row that exists is left as it
    /// is — changing it is the field writes' job.
    @discardableResult func insert(_ contact: ContactRecord) throws -> Bool

    /// A contact from now on; `addedAt` is kept if it was set.
    @discardableResult func markContact(_ id: String, addedAt: Date) throws -> Bool
    @discardableResult func setBlocked(_ id: String, _ blocked: Bool) throws -> Bool
    /// `nil` shows their own name again.
    @discardableResult func setAlias(_ id: String, _ alias: String?) throws -> Bool
    /// Whether we share our profile with them.
    @discardableResult func setSharingWith(_ id: String, _ sharing: Bool) throws -> Bool
    @discardableResult func setIdentityKey(_ id: String, _ key: Data?) throws -> Bool
    @discardableResult func setKTStatus(_ id: String, _ status: KTStatus) throws -> Bool
    @discardableResult func setAccountAddress(_ id: String, _ address: Data?) throws -> Bool
    @discardableResult func setSecurityNotice(_ id: String, _ notice: SecurityNotice) throws -> Bool
    @discardableResult func setNames(_ id: String, username: String, displayName: String) throws -> Bool
    /// A profile they shared: sharing on, with the name and times the caller chose.
    @discardableResult func applySharedProfile(
        _ id: String, displayName: String, sharedWithMeAt: Date, profileEditedAtMs: Int64
    ) throws -> Bool
    /// The avatar and the one still to download, set together.
    @discardableResult func setAvatar(
        _ id: String, _ avatar: Data?, pendingRef: Data?, pendingSince: Date?
    ) throws -> Bool
}

/// Our own profile. `accountId` as for `ContactStore`.
protocol OwnProfileStore: Sendable {
    func profile(accountId: String) throws -> OwnProfileRecord?
    /// Replaces our profile — there is one.
    func save(_ profile: OwnProfileRecord) throws
}

/// `User` rows. Each call runs on a fresh background context, for the reason
/// `CoreDataPeerDeviceStore` gives; it therefore sees what is saved, never another context's
/// pending changes.
final class CoreDataContactStore: ContactStore, OwnProfileStore, @unchecked Sendable {

    private let container: NSPersistentContainer
    private let feed: ContactChangeFeed

    init(container: NSPersistentContainer) {
        self.container = container
        self.feed = ContactChangeFeed(coordinator: container.persistentStoreCoordinator)
    }

    func changes() -> AsyncStream<Set<String>> { feed.stream() }

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

    func contacts() throws -> [ContactRecord] {
        try fetch(NSPredicate(format: "isContact == YES"))
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

    func contactsWithPendingAvatar() throws -> [ContactRecord] {
        try fetch(NSPredicate(format: "pendingAvatarRef != nil"))
    }

    // MARK: Writes

    func insert(_ contact: ContactRecord) throws -> Bool {
        try run { context in
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", contact.id)
            req.fetchLimit = 1
            guard try context.count(for: req) == 0 else { return false }
            let user = User(context: context)
            user.id = contact.id
            contact.write(to: user)
            try context.saveOrThrow(category: "Contacts")
            return true
        }
    }

    func markContact(_ id: String, addedAt: Date) throws -> Bool {
        try update(id) { $0.isContact = true; $0.addedAt = $0.addedAt ?? addedAt }
    }
    func setBlocked(_ id: String, _ blocked: Bool) throws -> Bool { try update(id) { $0.isBlocked = blocked } }
    func setAlias(_ id: String, _ alias: String?) throws -> Bool { try update(id) { $0.localAlias = alias } }
    func setSharingWith(_ id: String, _ sharing: Bool) throws -> Bool { try update(id) { $0.amISharingWith = sharing } }
    func setIdentityKey(_ id: String, _ key: Data?) throws -> Bool { try update(id) { $0.knownIdentityKey = key } }
    func setKTStatus(_ id: String, _ status: KTStatus) throws -> Bool { try update(id) { $0.ktStatus = status } }
    func setAccountAddress(_ id: String, _ address: Data?) throws -> Bool { try update(id) { $0.accountAddress = address } }
    func setSecurityNotice(_ id: String, _ notice: SecurityNotice) throws -> Bool { try update(id) { $0.securityNotice = notice } }
    func setNames(_ id: String, username: String, displayName: String) throws -> Bool {
        try update(id) { $0.username = username; $0.displayName = displayName }
    }
    func applySharedProfile(
        _ id: String, displayName: String, sharedWithMeAt: Date, profileEditedAtMs: Int64
    ) throws -> Bool {
        try update(id) {
            $0.isSharingWithMe = true
            $0.displayName = displayName
            $0.sharedWithMeAt = sharedWithMeAt
            $0.profileEditedAtMs = profileEditedAtMs
        }
    }
    func setAvatar(_ id: String, _ avatar: Data?, pendingRef: Data?, pendingSince: Date?) throws -> Bool {
        try update(id) {
            $0.avatarData = avatar
            $0.pendingAvatarRef = pendingRef
            $0.pendingAvatarSince = pendingSince
        }
    }

    /// The fields named in `change` and nothing else; saved only when something did change.
    private func update(_ id: String, _ change: (User) -> Void) throws -> Bool {
        try run { context in
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id)
            req.fetchLimit = 1
            guard let user = try context.fetch(req).first else { return false }
            change(user)
            if context.hasChanges { try context.saveOrThrow(category: "Contacts") }
            return true
        }
    }

    func save(_ profile: OwnProfileRecord) throws {
        try run { context in
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", profile.accountId)
            req.fetchLimit = 1
            let user = try context.fetch(req).first ?? {
                // Our row in the contacts table, as the app has always created it: no sharing,
                // no block, not a contact.
                let row = User(context: context)
                row.id = profile.accountId
                row.isSharingWithMe = false
                row.isBlocked = false
                row.amISharingWith = false
                return row
            }()
            user.username = profile.username
            user.displayName = profile.displayName
            user.avatarData = profile.avatar
            user.profileEditedAtMs = profile.profileEditedAtMs
            if context.hasChanges { try context.saveOrThrow(category: "Contacts") }
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
    /// A new contact as the app creates one: nothing shared, nothing blocked, nothing pinned.
    static func new(id: String, isContact: Bool, addedAt: Date?) -> ContactRecord {
        ContactRecord(
            id: id, username: "", displayName: "", localAlias: nil, avatar: nil,
            knownIdentityKey: nil, accountAddress: nil, isContact: isContact, isBlocked: false,
            isSharingWithMe: false, amISharingWith: false, sharedWithMeAt: nil, addedAt: addedAt,
            ktStatus: .unverified, securityNotice: .none, profileEditedAtMs: 0,
            pendingAvatarRef: nil, pendingAvatarSince: nil
        )
    }

    /// Every field but the id onto a row. `publicKey` and `hybridCapable` are left out on purpose.
    fileprivate func write(to user: User) {
        user.username = username
        user.displayName = displayName
        user.localAlias = localAlias
        user.avatarData = avatar
        user.knownIdentityKey = knownIdentityKey
        user.accountAddress = accountAddress
        user.isContact = isContact
        user.isBlocked = isBlocked
        user.isSharingWithMe = isSharingWithMe
        user.amISharingWith = amISharingWith
        user.sharedWithMeAt = sharedWithMeAt
        user.addedAt = addedAt
        user.ktStatus = ktStatus
        user.securityNotice = securityNotice
        user.profileEditedAtMs = profileEditedAtMs
        user.pendingAvatarRef = pendingAvatarRef
        user.pendingAvatarSince = pendingAvatarSince
    }

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

extension User {
    /// The row `id` in `context`, as last saved — for a caller that still needs the managed object
    /// (a chat to link, a screen to open) after writing through `ContactStore`. Refreshed, since
    /// the write landed in another context and `context` may hold the row from before it; the
    /// merge into the view context comes later, on its queue. Disappears with step 3 of the plan.
    static func row(_ id: String, in context: NSManagedObjectContext) throws -> User {
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        req.shouldRefreshRefetchedObjects = true
        guard let user = try context.fetch(req).first else {
            throw NSError(domain: "ContactStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "no User row \(id.prefix(8))…"])
        }
        return user
    }
}

/// Every save on `coordinator` that touched a `User` row, as the row ids — whichever context saved,
/// so a write that still goes around the repository (the chats domain, until it moves) is seen too.
final class ContactChangeFeed: @unchecked Sendable {

    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Set<String>>.Continuation] = [:]
    private var token: NSObjectProtocol?

    init(coordinator: NSPersistentStoreCoordinator) {
        token = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: nil, queue: nil
        ) { [weak self] note in
            // Posted on the saving context's queue, so its objects may be read here.
            guard let context = note.object as? NSManagedObjectContext,
                  context.persistentStoreCoordinator === coordinator else { return }
            let ids = Self.userIds(in: note)
            if !ids.isEmpty { self?.send(ids) }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        lock.withLock { subscribers.values.forEach { $0.finish() } }
    }

    func stream() -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            let key = UUID()
            lock.withLock { subscribers[key] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: key) }
            }
        }
    }

    private func send(_ ids: Set<String>) {
        let targets = lock.withLock { Array(subscribers.values) }
        targets.forEach { $0.yield(ids) }
    }

    private static func userIds(in note: Notification) -> Set<String> {
        var ids = Set<String>()
        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            for object in (note.userInfo?[key] as? Set<NSManagedObject>) ?? [] {
                if let user = object as? User, !user.id.isEmpty { ids.insert(user.id) }
            }
        }
        return ids
    }
}
