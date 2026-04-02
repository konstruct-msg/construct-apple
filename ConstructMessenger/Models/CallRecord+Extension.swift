//
//  CallRecord+Extension.swift
//  Construct Messenger
//
//  Typed accessors for the CallRecord Core Data entity.
//

import Foundation
import CoreData

extension CallRecord {

    enum Direction: Int16 {
        case outgoing = 0
        case incoming = 1
    }

    enum Status: Int16 {
        case completed = 0  // answered + ended normally
        case missed    = 1  // incoming, never answered
        case declined  = 2  // incoming, declined by local user
        case failed    = 3  // error or local cancel
    }

    var direction: Direction {
        get { Direction(rawValue: directionRaw) ?? .outgoing }
        set { directionRaw = newValue.rawValue }
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .completed }
        set { statusRaw = newValue.rawValue }
    }

    /// Human-readable duration string (e.g. "1:23").
    var formattedDuration: String? {
        guard durationSeconds > 0 else { return nil }
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Factory

    @discardableResult
    static func create(
        id: String,
        peerUserId: String,
        peerName: String,
        direction: Direction,
        status: Status,
        startedAt: Date,
        endedAt: Date?,
        durationSeconds: Int32,
        in context: NSManagedObjectContext
    ) -> CallRecord {
        let record = CallRecord(context: context)
        record.id = id
        record.peerUserId = peerUserId
        record.peerName = peerName
        record.direction = direction
        record.status = status
        record.startedAt = startedAt
        record.endedAt = endedAt
        record.durationSeconds = durationSeconds
        return record
    }

    // MARK: - Fetch

    static func fetchRecent(limit: Int = 200, in context: NSManagedObjectContext) throws -> [CallRecord] {
        let req = NSFetchRequest<CallRecord>(entityName: "CallRecord")
        req.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        req.fetchLimit = limit
        return try context.fetch(req)
    }
}
