//
//  LocalRepositories.swift
//  Construct Messenger
//
//  The storage seam (`client/specs/LOCAL_STORE_MIGRATION_PLAN.md`): the app reads and writes
//  through these repositories, never through a managed object or a context, and this is the one
//  place that decides which implementation answers: `LocalStore` (construct-store) on macOS since
//  step 3, and on iOS once the install has moved (`LocalStoreImport`, step 4) — Core Data until then.
//

import Foundation
import CoreData

enum LocalRepositories {

    /// Every repository over one store, so they are installed and replaced together: a message
    /// names its chat and the chat its contact, and half of them on another store is broken links.
    struct Backing {
        let peerDevices: any PeerDeviceStore
        let serverMessageIds: any ServerMessageIdStore
        let contacts: any ContactStore
        let ownProfile: any OwnProfileStore
        let chats: any ChatStore
        let messages: any MessageStore
        let reactions: any ReactionStore
        let processedMessages: any ProcessedMessageStore
        let calls: any CallStore
        let pendingChunks: any PendingChunkStore
        let keyValue: any KeyValueStore
        let issuedInvites: any IssuedInviteStore

        /// iOS: Core Data, and the three service stores where they have always been — sealed files
        /// for chunks, `UserDefaults` for the key-value pairs and the invite journal.
        static func coreData(_ container: NSPersistentContainer) -> Backing {
            let contacts = CoreDataContactStore(container: container)
            return Backing(
                peerDevices: CoreDataPeerDeviceStore(container: container),
                serverMessageIds: CoreDataServerMessageIdStore(container: container),
                contacts: contacts, ownProfile: contacts,
                chats: CoreDataChatStore(container: container),
                messages: CoreDataMessageStore(container: container),
                reactions: CoreDataReactionStore(container: container),
                processedMessages: CoreDataProcessedMessageStore(container: container),
                calls: CoreDataCallStore(container: container),
                pendingChunks: FilePendingChunkStore(),
                keyValue: DefaultsKeyValueStore(),
                issuedInvites: DefaultsIssuedInviteStore()
            )
        }

        static func localStore(_ session: LocalStoreSession) -> Backing {
            let contacts = LocalStoreContactStore(session: session)
            return Backing(
                peerDevices: LocalStorePeerDeviceStore(session: session),
                serverMessageIds: LocalStoreServerMessageIdStore(session: session),
                contacts: contacts, ownProfile: contacts,
                chats: LocalStoreChatStore(session: session),
                messages: LocalStoreMessageStore(session: session),
                reactions: LocalStoreReactionStore(session: session),
                processedMessages: LocalStoreProcessedMessageStore(session: session),
                calls: LocalStoreCallStore(session: session),
                pendingChunks: LocalStorePendingChunkStore(session: session),
                keyValue: LocalStoreKeyValueStore(session: session),
                issuedInvites: LocalStoreIssuedInviteStore(session: session)
            )
        }
    }

    private static let lock = NSLock()

    /// The app's store, or the closed one the repositories stand on when it would not open.
    private(set) nonisolated(unsafe) static var session: LocalStoreSession?
    /// Why the app's store is not open; nil when it is. The root view shows this instead of the
    /// app, and nothing is written meanwhile: every call on the closed store throws.
    private(set) nonisolated(unsafe) static var storeFailure: LocalStoreSession.Failure?

    /// Once, and without the lock: the getters below take it, and the first of them to run
    /// evaluates this. An iOS install that has not moved yet stands on Core Data and does not open
    /// the store at all — an import may be about to create it.
    private static let initial: Backing = LocalStoreImport.hasMoved
        ? openAppStore()
        : .coreData(PersistenceController.shared.container)

    /// Whether the repositories stand on `construct.db` — always on macOS, on iOS once moved.
    static var isOnStore: Bool {
        _ = initial
        return lock.withLock { session != nil || storeFailure != nil }
    }

    /// Called once for `initial`, then with the lock held.
    private static func openAppStore() -> Backing {
        let opened: Result<LocalStoreSession, LocalStoreSession.Failure>
        do {
            opened = LocalStoreSession.open(at: try LocalStoreSession.defaultURL, key: LocalStoreKey.current())
        } catch {
            opened = .failure(.storage("\(error)"))
        }
        switch opened {
        case .success(let open):
            session = open
            storeFailure = nil
            return .localStore(open)
        case .failure(let failure):
            Log.error("LocalRepositories: the app's store is not open — \(failure)", category: "Storage")
            session = nil
            storeFailure = failure
            return .localStore(.closed())
        }
    }

    /// Open the app's store now — at launch, before anything reads a repository — and say why
    /// not. Again after a failure: the Keychain may answer once the Mac is unlocked.
    @discardableResult
    static func openAppStoreIfNeeded() -> LocalStoreSession.Failure? {
        guard LocalStoreImport.hasMoved else { return nil }
        _ = initial
        lock.withLock {
            guard storeFailure != nil else { return }
            install(openAppStore())
        }
        if storeFailure == nil {
            NotificationCenter.default.post(name: .localStoreReplaced, object: nil)
        }
        return storeFailure
    }

    /// The account's store goes, and an empty one under a new key takes its place: the key first
    /// (`LocalStoreKey.destroy`, whatever is left behind is unreadable), then the open store,
    /// closed and its files removed, then `between` — `LocalDataWipe`'s file sweep runs with no
    /// store open. Observers of the old store's changes are finished; `.localStoreReplaced`
    /// tells the screens to read again.
    static func replaceAppStore(between: () -> Void = {}) {
        _ = initial
        lock.withLock {
            LocalStoreKey.destroy()
            do {
                try session?.wipe()
            } catch {
                Log.error("LocalRepositories: the store did not wipe — \(error)", category: "Storage")
            }
            between()
            install(openAppStore())
        }
        NotificationCenter.default.post(name: .localStoreReplaced, object: nil)
    }

    /// iOS, once: copy the Core Data install into `construct.db` and stand on it. The lock is held
    /// from the first read to the switch, so a write that arrives meanwhile — a push handled while
    /// the import screen is up — waits and lands in the new store instead of in the old one after
    /// it was copied. The import reads and writes the stores directly, never these getters.
    ///
    /// A store left by an import that did not finish is wiped first; one that did finish and only
    /// missed the flag is taken as it is. On failure the store is wiped and Core Data stays.
    @discardableResult
    static func importFromCoreData(
        ownAccountId: String?,
        progress: (Double) -> Void = { _ in }
    ) throws -> LocalStoreImport.Counts {
        _ = initial
        var counts = LocalStoreImport.Counts()
        try lock.withLock {
            guard !LocalStoreImport.hasMoved else { return }
            let url = try LocalStoreSession.defaultURL
            var opened = try LocalStoreSession.open(at: url, key: LocalStoreKey.current()).get()
            if LocalStoreImport.isComplete(.localStore(opened)) {
                Log.info("LocalRepositories: an earlier import had finished — taking it", category: "Storage")
            } else {
                // Created by this call, or left half-written by one that was interrupted.
                try opened.wipe()
                opened = try LocalStoreSession.open(at: url, key: LocalStoreKey.current()).get()
                let source = Backing.coreData(PersistenceController.shared.container)
                do {
                    counts = try LocalStoreImport.run(
                        from: source,
                        extras: LocalStoreImport.coreDataExtras(PersistenceController.shared.container, ownAccountId: ownAccountId),
                        into: .localStore(opened),
                        progress: progress
                    )
                } catch {
                    try? opened.wipe()
                    throw error
                }
            }
            LocalStoreImport.markMoved()
            session = opened
            storeFailure = nil
            install(.localStore(opened))
        }
        NotificationCenter.default.post(name: .localStoreReplaced, object: nil)
        return counts
    }

    private static func install(_ backing: Backing) {
        _peerDevices = backing.peerDevices
        _serverMessageIds = backing.serverMessageIds
        _contacts = backing.contacts
        _ownProfile = backing.ownProfile
        _chats = backing.chats
        _messages = backing.messages
        _reactions = backing.reactions
        _processedMessages = backing.processedMessages
        _calls = backing.calls
        _pendingChunks = backing.pendingChunks
        _keyValue = backing.keyValue
        _issuedInvites = backing.issuedInvites
    }

    // Read under the lock: `replaceAppStore` swaps them all while the app runs, and an
    // existential read during its assignment is torn.
    static var peerDevices: any PeerDeviceStore { lock.withLock { _peerDevices } }
    static var serverMessageIds: any ServerMessageIdStore { lock.withLock { _serverMessageIds } }
    static var contacts: any ContactStore { lock.withLock { _contacts } }
    static var ownProfile: any OwnProfileStore { lock.withLock { _ownProfile } }
    static var chats: any ChatStore { lock.withLock { _chats } }
    static var messages: any MessageStore { lock.withLock { _messages } }
    static var reactions: any ReactionStore { lock.withLock { _reactions } }
    static var processedMessages: any ProcessedMessageStore { lock.withLock { _processedMessages } }
    static var calls: any CallStore { lock.withLock { _calls } }
    static var pendingChunks: any PendingChunkStore { lock.withLock { _pendingChunks } }
    static var keyValue: any KeyValueStore { lock.withLock { _keyValue } }
    static var issuedInvites: any IssuedInviteStore { lock.withLock { _issuedInvites } }

    nonisolated(unsafe) private static var _peerDevices: any PeerDeviceStore = initial.peerDevices
    nonisolated(unsafe) private static var _serverMessageIds: any ServerMessageIdStore = initial.serverMessageIds
    nonisolated(unsafe) private static var _contacts: any ContactStore = initial.contacts
    nonisolated(unsafe) private static var _ownProfile: any OwnProfileStore = initial.ownProfile
    nonisolated(unsafe) private static var _chats: any ChatStore = initial.chats
    nonisolated(unsafe) private static var _messages: any MessageStore = initial.messages
    nonisolated(unsafe) private static var _reactions: any ReactionStore = initial.reactions
    nonisolated(unsafe) private static var _processedMessages: any ProcessedMessageStore = initial.processedMessages
    nonisolated(unsafe) private static var _calls: any CallStore = initial.calls
    nonisolated(unsafe) private static var _pendingChunks: any PendingChunkStore = initial.pendingChunks
    nonisolated(unsafe) private static var _keyValue: any KeyValueStore = initial.keyValue
    nonisolated(unsafe) private static var _issuedInvites: any IssuedInviteStore = initial.issuedInvites

    #if DEBUG
    /// Every repository on `session`, as macOS runs — a test that drives a whole path on the
    /// crate; `nil` restores the app's.
    static func useLocalStoreForTesting(_ session: LocalStoreSession?) {
        lock.withLock { install(session.map(Backing.localStore) ?? initial) }
    }

    /// A test's own store (an in-memory container); `nil` restores the app's.
    static func usePeerDevicesForTesting(_ store: (any PeerDeviceStore)?) {
        _peerDevices = store ?? CoreDataPeerDeviceStore(container: PersistenceController.shared.container)
    }

    /// Both contact repositories over one test container; `nil` restores the app's.
    static func useContactsForTesting(_ container: NSPersistentContainer?) {
        let store = CoreDataContactStore(container: container ?? PersistenceController.shared.container)
        _contacts = store
        _ownProfile = store
    }

    static func useChatsForTesting(_ container: NSPersistentContainer?) {
        _chats = CoreDataChatStore(container: container ?? PersistenceController.shared.container)
    }

    static func useMessagesForTesting(_ container: NSPersistentContainer?) {
        _messages = CoreDataMessageStore(container: container ?? PersistenceController.shared.container)
    }

    /// A store a test wrote itself — one that refuses, say.
    static func useMessagesForTesting(_ store: any MessageStore) {
        _messages = store
    }

    static func useReactionsForTesting(_ container: NSPersistentContainer?) {
        _reactions = CoreDataReactionStore(container: container ?? PersistenceController.shared.container)
    }

    static func useProcessedMessagesForTesting(_ store: (any ProcessedMessageStore)?) {
        _processedMessages = store ?? CoreDataProcessedMessageStore(container: PersistenceController.shared.container)
    }

    static func useCallsForTesting(_ container: NSPersistentContainer?) {
        _calls = CoreDataCallStore(container: container ?? PersistenceController.shared.container)
    }

    static func useCallsForTesting(_ store: any CallStore) {
        _calls = store
    }

    static func useIssuedInvitesForTesting(_ store: (any IssuedInviteStore)?) {
        _issuedInvites = store ?? initial.issuedInvites
    }

    static func useKeyValueForTesting(_ store: (any KeyValueStore)?) {
        _keyValue = store ?? initial.keyValue
    }

    static func usePendingChunksForTesting(_ store: (any PendingChunkStore)?) {
        _pendingChunks = store ?? initial.pendingChunks
    }

    static func useServerMessageIdsForTesting(_ store: (any ServerMessageIdStore)?) {
        _serverMessageIds = store ?? CoreDataServerMessageIdStore(container: PersistenceController.shared.container)
    }
    #endif
}
