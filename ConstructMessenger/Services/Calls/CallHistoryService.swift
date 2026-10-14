//
//  CallHistoryService.swift
//  Construct Messenger
//
//  Writes a call to the log when it ends (`CallManager.endActiveCall`), through the call store
//  (`LocalRepositories.calls`).
//
//  macOS: calls not yet implemented.
//
#if os(iOS)

import Foundation

@MainActor
final class CallHistoryService {
    static let shared = CallHistoryService()

    private let store: () -> any CallStore

    private init() {
        self.store = { LocalRepositories.calls }
    }

    // MARK: - Save

    func record(
        session: CallSession,
        status: CallRecord.Status,
        startedAt: Date,
        durationSeconds: Int32
    ) {
        let call = CallRecord(
            id: session.id,
            peerUserId: session.peerUserId,
            peerName: session.peerName,
            direction: session.direction == .outgoing ? .outgoing : .incoming,
            status: status,
            startedAt: startedAt,
            endedAt: Date(),
            durationSeconds: durationSeconds
        )
        do {
            try store().upsert(call)
        } catch {
            Log.error("Failed to record call: \(error)", category: "CallHistory")
        }
    }

    // MARK: - Delete

    func delete(_ id: String) {
        do {
            try store().delete(id)
        } catch {
            Log.error("Failed to delete call record: \(error)", category: "CallHistory")
        }
    }

    /// The whole log, in one store write (`CallStore.deleteAll`).
    func deleteAll() {
        do {
            let removed = try store().deleteAll()
            Log.info("Deleted \(removed) call history records", category: "CallHistory")
        } catch {
            Log.error("Failed to delete call history: \(error)", category: "CallHistory")
        }
    }
}

#endif // os(iOS)
