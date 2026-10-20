//
//  AuthViewModel+LocalStore.swift
//  Construct Messenger
//
//  Part of AuthViewModel: local store ownership and wipe: the ownership gate, the wipe of the previous
//  identity's data and the entity list shared with account deletion.
//

import Foundation
import CoreData
import GRPCCore
#if canImport(UIKit)
import UIKit
#endif

extension AuthViewModel {
    /// Wipe the local store unless `userId` owns it, then record ownership.
    ///
    /// The gate, not a wipe-on-sign-out: signing out and recovering with a seed phrase keeps the
    /// same `userId`, and deleting history there would be a second bug. Data belongs to an
    /// identity; nobody else may see it. See `LocalStoreOwnership`.
    func enforceLocalStoreOwnership(for userId: String) {
        guard !userId.isEmpty else { return }

        let stored = LocalStoreOwnership.storedOwner()
        let hasData = localStoreHasUserData(previousOwner: stored)

        switch LocalStoreOwnership.disposition(
            storedOwner: stored,
            incomingUser: userId,
            storeHasData: hasData
        ) {
        case .keep:
            LocalStoreOwnership.claim(userId)
        case .wipe:
            Log.error(
                "Local store belongs to \(stored?.prefix(8).description ?? "an unknown identity") — " +
                "wiping before \(userId.prefix(8))… is shown anything",
                category: "Auth"
            )
            wipeLocalStoreContents()
            LocalStoreOwnership.claim(userId)
        }
    }

    /// True when the store holds anything that identifies people or conversations.
    ///
    /// Deliberately narrow: people (a contact list with no transcript is the more sensitive half),
    /// chats (a message needs its chat), and the last owner's own profile, which the crate keeps
    /// apart from the people and Core Data keeps among them.
    private func localStoreHasUserData(previousOwner: String?) -> Bool {
        let people = (try? LocalRepositories.contacts.everyContact(except: nil)) ?? []
        let chats = (try? LocalRepositories.chats.chats()) ?? []
        let ownProfile = previousOwner.flatMap { try? LocalRepositories.ownProfile.profile(accountId: $0) }
        return !people.isEmpty || !chats.isEmpty || ownProfile != nil
    }

    /// Deletes every entity the previous identity could have left behind.
    ///
    /// Same list `deleteAccount()` uses — kept in one place on purpose, because the three wipe
    /// paths having three different lists is how `performLocalSignOut` ended up never clearing
    /// Core Data at all.
    private func wipeLocalStoreContents() {
        // The store goes whole, under its key, and an empty one replaces it — macOS, and iOS once
        // the install has moved to `construct.db`.
        if LocalRepositories.isOnStore {
            LocalRepositories.replaceAppStore()
            return
        }
        guard let context = PersistenceController.shared.safeViewContext else {
            Log.error("Local store wipe skipped — no persistent store", category: "Auth")
            return
        }
        for entityName in Self.userDataEntityNames {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            let batchDelete = NSBatchDeleteRequest(fetchRequest: request)
            batchDelete.resultType = .resultTypeObjectIDs
            do {
                let result = try context.execute(batchDelete) as? NSBatchDeleteResult
                if let objectIDs = result?.result as? [NSManagedObjectID], !objectIDs.isEmpty {
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                        into: [context]
                    )
                }
            } catch {
                Log.error("Failed to wipe \(entityName): \(error)", category: "Auth")
            }
        }
        // What macOS takes with the store lives outside Core Data here: the invite journal and
        // the fan-out queue in `UserDefaults`, partial messages in sealed files.
        Self.forgetServiceRows()
        Log.info("Local store wiped — previous identity's data removed", category: "Auth")
    }

    /// The previous identity's service rows on iOS: issued invites, owed fan-out copies, partial
    /// messages. Each through its own owner, so none keeps a copy of them in memory.
    static func forgetServiceRows() {
        do {
            let invites = LocalRepositories.issuedInvites
            try invites.delete(jtis: invites.all().map(\.jti))
        } catch {
            Log.error("Ownership gate: issued invites not removed: \(error)", category: "Auth")
        }
        InviteJournal.shared.reload()
        FanoutRetryQueue.shared.removeAll()
        PendingReassemblyStore.shared.removeAll()
    }

    /// Every entity that carries user data. One list, used by both the ownership gate and
    /// account deletion.
    static let userDataEntityNames = [
        "Message", "HealingMessage", "ProcessedMessage", "CallRecord", "Chat", "User",
        "Reaction", "PeerDevice", "ServerMessageId"
    ]
}
