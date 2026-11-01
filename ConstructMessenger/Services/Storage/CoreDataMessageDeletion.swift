import CoreData

enum CoreDataMessageDeletion {
    /// Called on the context's queue. Core Data expands the cascade; snapshots must be taken
    /// before save invalidates deleted objects. A refused save must leave live rows readable.
    static func delete(_ objects: [NSManagedObject], in context: NSManagedObjectContext, category: String) throws {
        objects.forEach(context.delete)
        context.processPendingChanges()
        let messages = context.deletedObjects.compactMap { $0 as? Message }
        let ids = messages.map(\.id)
        let keyRefs = Set(messages.compactMap(\.contentKeyRef))

        try context.saveOrThrow(category: category)
        for id in ids { MessageDisplayCache.shared.evict(messageId: id) }
        try MessageKeyStore.shared.delete(messageIds: keyRefs)
    }
}
