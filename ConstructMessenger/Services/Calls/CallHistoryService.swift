//
//  CallHistoryService.swift
//  Construct Messenger
//
//  Persists call records to Core Data when calls end.
//  Called from CallManager.endActiveCall.
//

import Foundation
import CoreData

@MainActor
final class CallHistoryService {
    static let shared = CallHistoryService()
    private init() {}

    private var context: NSManagedObjectContext? {
        PersistenceController.shared.container.viewContext
    }

    // MARK: - Save

    func record(
        session: CallManager.CallSession,
        status: CallRecord.Status,
        startedAt: Date,
        durationSeconds: Int32
    ) {
        guard let ctx = context else { return }
        let direction: CallRecord.Direction = session.direction == .outgoing ? .outgoing : .incoming

        ctx.perform {
            CallRecord.create(
                id: session.id,
                peerUserId: session.peerUserId,
                peerName: session.peerName,
                direction: direction,
                status: status,
                startedAt: startedAt,
                endedAt: Date(),
                durationSeconds: durationSeconds,
                in: ctx
            )
            try? ctx.save()
        }
    }

    // MARK: - Delete

    func deleteAll() {
        guard let ctx = context else { return }
        ctx.perform {
            // NSBatchDeleteRequest writes directly to the SQLite store and bypasses
            // the in-memory context, so @FetchRequest observers would never see the
            // change. Fetch result type .resultTypeObjectIDs + mergeChanges fixes this.
            let req = NSFetchRequest<NSFetchRequestResult>(entityName: "CallRecord")
            let batch = NSBatchDeleteRequest(fetchRequest: req)
            batch.resultType = .resultTypeObjectIDs
            guard let result = try? ctx.execute(batch) as? NSBatchDeleteResult,
                  let ids = result.result as? [NSManagedObjectID] else {
                return
            }
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: ids],
                into: [ctx]
            )
        }
    }
}
