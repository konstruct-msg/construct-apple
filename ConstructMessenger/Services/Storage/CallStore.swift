//
//  CallStore.swift
//  Construct Messenger
//
//  The call log, behind the storage seam with the operations `LocalStore` has — `upsert_call`,
//  `calls`, `delete_call` (construct-core 0.46.0, `calls`). Until 2026-10-12 the call manager, the
//  recents screen and the history transfer each reached `CTCallRecord` through a context of their
//  own.
//

import CoreData
import Foundation

struct CallRecord: Equatable, Identifiable, Sendable {

    enum Direction: Int16, Sendable {
        case outgoing = 0
        case incoming = 1
    }

    /// The raw values are the wire's (`history_snapshot.proto`, `CallRecord.status`) and the
    /// crate's column.
    enum Status: Int16, Sendable {
        case completed = 0  // answered + ended normally
        case missed    = 1  // incoming, never answered
        case declined  = 2  // incoming, declined by local user
        case failed    = 3  // error or local cancel
    }

    let id: String
    let peerUserId: String
    let peerName: String
    let direction: Direction
    let status: Status
    let startedAt: Date?
    let endedAt: Date?
    let durationSeconds: Int32

    /// Human-readable duration string (e.g. "1:23").
    var formattedDuration: String? {
        guard durationSeconds > 0 else { return nil }
        return String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
    }
}

protocol CallStore: Sendable {
    /// Insert, or replace every field of the row `call.id`.
    func upsert(_ call: CallRecord) throws
    /// Newest first, a call with no start time last; at most `limit`.
    func calls(limit: Int) throws -> [CallRecord]
    /// False: no such row.
    @discardableResult func delete(_ id: String) throws -> Bool
    /// The whole log ("clear history"), in one write; how many entries it held.
    @discardableResult func deleteAll() throws -> Int
    /// The ids of rows written or deleted, once per save. Subscribe before the first read, or a
    /// write between the two is missed.
    func changes() -> AsyncStream<Set<String>>
}

/// `CallRecord` rows, each call on a fresh background context (`CoreDataPeerDeviceStore` says why a
/// context is never borrowed).
final class CoreDataCallStore: CallStore, @unchecked Sendable {

    private let container: NSPersistentContainer
    private let feed: RowChangeFeed

    init(container: NSPersistentContainer) {
        self.container = container
        self.feed = RowChangeFeed(coordinator: container.persistentStoreCoordinator) { object in
            (object as? CTCallRecord).map(\.id)
        }
    }

    func changes() -> AsyncStream<Set<String>> { feed.stream() }

    func upsert(_ call: CallRecord) throws {
        try run { context in
            let row = try self.row(call.id, in: context) ?? CTCallRecord(context: context)
            row.id = call.id
            row.peerUserId = call.peerUserId
            row.peerName = call.peerName
            row.directionRaw = call.direction.rawValue
            row.statusRaw = call.status.rawValue
            row.startedAt = call.startedAt
            row.endedAt = call.endedAt
            row.durationSeconds = call.durationSeconds
            try context.saveOrThrow(category: "CallHistory")
        }
    }

    func calls(limit: Int) throws -> [CallRecord] {
        try run { context in
            let req = CTCallRecord.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
            req.fetchLimit = limit
            // SQLite orders NULL below every date, so descending puts an undated call last — the
            // crate's order, which `testTheLogIsNewestFirstWithAnUndatedCallLast` pins.
            return try context.fetch(req).map(CallRecord.init)
        }
    }

    func delete(_ id: String) throws -> Bool {
        try run { context in
            guard let row = try self.row(id, in: context) else { return false }
            context.delete(row)
            try context.saveOrThrow(category: "CallHistory")
            return true
        }
    }

    func deleteAll() throws -> Int {
        // Fetched and deleted in the context rather than by a batch delete, which bypasses the
        // context and so `changes()` would not hear of it.
        try run { context in
            let rows = try context.fetch(CTCallRecord.fetchRequest())
            guard !rows.isEmpty else { return 0 }
            rows.forEach(context.delete)
            try context.saveOrThrow(category: "CallHistory")
            return rows.count
        }
    }

    private func row(_ id: String, in context: NSManagedObjectContext) throws -> CTCallRecord? {
        let req = CTCallRecord.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        return try context.fetch(req).first
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}

/// The call log on the crate (`calls`).
final class LocalStoreCallStore: CallStore, @unchecked Sendable {

    private let session: LocalStoreSession

    init(session: LocalStoreSession) {
        self.session = session
    }

    func changes() -> AsyncStream<Set<String>> { session.changes(of: .calls) }

    func upsert(_ call: CallRecord) throws {
        try session.store.upsertCall(call: call.local)
    }

    func calls(limit: Int) throws -> [CallRecord] {
        try session.store.calls(limit: UInt32(clamping: limit)).map { CallRecord($0) }
    }

    func delete(_ id: String) throws -> Bool {
        try session.store.deleteCall(id: id)
    }

    func deleteAll() throws -> Int {
        Int(try session.store.deleteAllCalls())
    }
}

private extension CallRecord {
    init(_ row: CTCallRecord) {
        self.init(
            id: row.id,
            peerUserId: row.peerUserId,
            peerName: row.peerName,
            direction: Direction(rawValue: row.directionRaw) ?? .outgoing,
            status: Status(rawValue: row.statusRaw) ?? .completed,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            durationSeconds: row.durationSeconds
        )
    }
}
