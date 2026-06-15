//
//  CallHistoryService.swift
//  Construct Messenger
//
//  Persists call records to Core Data when calls end.
//  Called from CallManager.endActiveCall.
//
//  macOS: calls not yet implemented, stub out to avoid linking CoreData call types.
//
#if os(iOS)

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
        session: CallSession,
        status: CTCallRecord.Status,
        startedAt: Date,
        durationSeconds: Int32
    ) {
        guard let ctx = context else { return }
        let direction: CTCallRecord.Direction = session.direction == .outgoing ? .outgoing : .incoming

        ctx.perform {
            CTCallRecord.create(
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
        do {
            let records = try CTCallRecord.fetchRecent(limit: 10_000, in: ctx)
            guard !records.isEmpty else { return }
            records.forEach(ctx.delete)
            try ctx.save()
            Log.info("Deleted \(records.count) call history records", category: "CallHistory")
        } catch {
            Log.error("Failed to delete call history: \(error)", category: "CallHistory")
        }
    }
}

#endif // os(iOS)
