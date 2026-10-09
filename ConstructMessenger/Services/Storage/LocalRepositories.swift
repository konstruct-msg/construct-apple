//
//  LocalRepositories.swift
//  Construct Messenger
//
//  The storage seam (`client/specs/LOCAL_STORE_MIGRATION_PLAN.md`): the app reads and writes
//  through these repositories, never through a managed object or a context, and this is the one
//  place that decides which implementation answers. Core Data today; step 3 makes it `LocalStore`
//  (construct-store) on macOS.
//

import Foundation
import CoreData

enum LocalRepositories {
    private(set) nonisolated(unsafe) static var peerDevices: any PeerDeviceStore =
        CoreDataPeerDeviceStore(container: PersistenceController.shared.container)

    private(set) nonisolated(unsafe) static var serverMessageIds: any ServerMessageIdStore =
        CoreDataServerMessageIdStore(container: PersistenceController.shared.container)

    private(set) nonisolated(unsafe) static var contacts: any ContactStore =
        CoreDataContactStore(container: PersistenceController.shared.container)

    private(set) nonisolated(unsafe) static var ownProfile: any OwnProfileStore =
        CoreDataContactStore(container: PersistenceController.shared.container)

    private(set) nonisolated(unsafe) static var chats: any ChatStore =
        CoreDataChatStore(container: PersistenceController.shared.container)

    #if DEBUG
    /// A test's own store (an in-memory container); `nil` restores the app's.
    static func usePeerDevicesForTesting(_ store: (any PeerDeviceStore)?) {
        peerDevices = store ?? CoreDataPeerDeviceStore(container: PersistenceController.shared.container)
    }

    /// Both contact repositories over one test container; `nil` restores the app's.
    static func useContactsForTesting(_ container: NSPersistentContainer?) {
        let store = CoreDataContactStore(container: container ?? PersistenceController.shared.container)
        contacts = store
        ownProfile = store
    }

    static func useChatsForTesting(_ container: NSPersistentContainer?) {
        chats = CoreDataChatStore(container: container ?? PersistenceController.shared.container)
    }

    static func useServerMessageIdsForTesting(_ store: (any ServerMessageIdStore)?) {
        serverMessageIds = store ?? CoreDataServerMessageIdStore(container: PersistenceController.shared.container)
    }
    #endif
}
