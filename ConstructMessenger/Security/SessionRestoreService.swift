//
//  SessionRestoreService.swift
//  Construct Messenger
//
//  Extracted from CryptoManager (refactor)
//

import Foundation
import CoreData

final class SessionRestoreService {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func restoreRecentSessions(limit: Int, restoreSession: @escaping (String) -> Bool, retryCount: Int = 0) {
        let context = persistence.container.viewContext
        guard context.persistentStoreCoordinator != nil else {
            guard retryCount < 5 else {
                Log.error("⚠️ SessionRestoreService: CoreData store unavailable after \(retryCount) retries, giving up", category: "SessionRestore")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restoreRecentSessions(limit: limit, restoreSession: restoreSession, retryCount: retryCount + 1)
            }
            return
        }

        let recentContactIds = getRecentChatContactIds(limit: limit, context: context)
        for contactId in recentContactIds {
            _ = restoreSession(contactId)
        }
    }

    private func getRecentChatContactIds(limit: Int, context: NSManagedObjectContext) -> [String] {
        guard context.persistentStoreCoordinator != nil else {
            return []
        }

        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastMessageTime", ascending: false)]
        fetchRequest.fetchLimit = limit

        do {
            let chats = try context.fetch(fetchRequest)
            return chats.compactMap { $0.otherUser?.id }
        } catch {
            return []
        }
    }
}
