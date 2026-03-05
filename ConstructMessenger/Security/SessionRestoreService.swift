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

    func restoreRecentSessions(limit: Int, restoreSession: @escaping (String) -> Bool) {
        let context = persistence.container.viewContext
        guard context.persistentStoreCoordinator != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restoreRecentSessions(limit: limit, restoreSession: restoreSession)
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
