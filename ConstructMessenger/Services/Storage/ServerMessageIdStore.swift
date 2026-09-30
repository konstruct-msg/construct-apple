//
//  ServerMessageIdStore.swift
//  Construct Messenger
//
//  The server's id of each sealed copy we sent → the message it carries. On the sealed path the
//  server assigns the id the recipient sees, so a delivery receipt or a DECRYPTION_ERROR names
//  that id, and we translate it back. Behind the storage seam from the start; `LocalStore` has the
//  same three operations (`record_server_message_id`, `local_message_id`,
//  `forget_server_message_ids_before`, construct-core `9b2971f`).
//

import CoreData
import Foundation

/// Ids are UUID text compared case-insensitively; implementations keep both sides lowercase.
///
/// No change events: nothing observes this table.
protocol ServerMessageIdStore: Sendable {
    /// A server id recorded again takes the new message — the server never reuses one, so that is
    /// a correction.
    func record(serverId: String, localId: String, at date: Date) throws
    func localId(forServerId serverId: String) throws -> String?
    /// Forget ids recorded before `date`; returns how many.
    @discardableResult
    func forget(recordedBefore date: Date) throws -> Int
}

/// `ServerMessageId` rows, each call on a fresh background context — the callers are the send
/// pipeline, receipt handling on the stream and the resend on the main actor
/// (`CoreDataPeerDeviceStore` says why a context is never borrowed).
final class CoreDataServerMessageIdStore: ServerMessageIdStore, @unchecked Sendable {

    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func record(serverId: String, localId: String, at date: Date) throws {
        let server = serverId.lowercased()
        try run { context in
            // A constraint clash with a concurrent write resolves to this one: a correction.
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            let row = try self.row(server, in: context) ?? ServerMessageId(context: context)
            row.serverId = server
            row.localId = localId.lowercased()
            row.recordedAt = date
            try context.saveOrThrow(category: "Storage")
        }
    }

    func localId(forServerId serverId: String) throws -> String? {
        try run { try self.row(serverId.lowercased(), in: $0)?.localId }
    }

    func forget(recordedBefore date: Date) throws -> Int {
        try run { context in
            let req = ServerMessageId.fetchRequest()
            req.predicate = NSPredicate(format: "recordedAt < %@", date as NSDate)
            let stale = try context.fetch(req)
            stale.forEach(context.delete)
            if context.hasChanges { try context.saveOrThrow(category: "Storage") }
            return stale.count
        }
    }

    private func row(_ serverId: String, in context: NSManagedObjectContext) throws -> ServerMessageId? {
        let req = ServerMessageId.fetchRequest()
        req.predicate = NSPredicate(format: "serverId == %@", serverId)
        req.fetchLimit = 1
        return try context.fetch(req).first
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}
