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
            let req = NSFetchRequest<NSFetchRequestResult>(entityName: "CallRecord")
            let batch = NSBatchDeleteRequest(fetchRequest: req)
            _ = try? ctx.execute(batch)
            try? ctx.save()
        }
    }
}
