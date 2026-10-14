//
//  ProcessedMessageStore.swift
//  Construct Messenger
//
//  The durable half of "this envelope was already processed": what survives a restart, so a
//  redelivery after it is a duplicate rather than a second message. The hot half is the
//  orchestrator's in-memory ACK cache; `PersistentACKStore` keeps the two in step
//  (decisions/one-ack-cache-one-durable-store.md). Behind the storage seam with the operations
//  `LocalStore` has — `mark_processed`, `is_processed`, `forget_processed_before` (construct-core
//  0.40.0, `processed_messages`).
//

import CoreData
import Foundation

/// Ids are exact: an envelope id is compared as received, never case-folded.
///
/// No change events: nothing observes this table.
protocol ProcessedMessageStore: Sendable {
    /// Records `messageId` as processed. A second mark keeps the first row. Returns whether it was
    /// new.
    @discardableResult
    func markProcessed(_ messageId: String, senderId: String, at date: Date) throws -> Bool
    func isProcessed(_ messageId: String) throws -> Bool
    /// Forget marks made before `date`; returns how many.
    @discardableResult
    func forget(processedBefore date: Date) throws -> Int
}

/// `ProcessedMessage` rows, each call on a fresh background context (`CoreDataPeerDeviceStore`
/// says why a context is never borrowed). Until 2026-10-11 every caller passed its own context —
/// usually the view context — and the mark was written there.
final class CoreDataProcessedMessageStore: ProcessedMessageStore, @unchecked Sendable {

    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func markProcessed(_ messageId: String, senderId: String, at date: Date) throws -> Bool {
        try run { context in
            if try self.row(messageId, in: context) != nil { return false }
            let row = ProcessedMessage(context: context)
            row.messageId = messageId
            row.senderId = senderId
            row.processedAt = date
            try context.saveOrThrow(category: "PersistentACK")
            return true
        }
    }

    func isProcessed(_ messageId: String) throws -> Bool {
        try run { try self.row(messageId, in: $0) != nil }
    }

    /// Every mark — for the one-time import into `construct.db` (`LocalStoreImport`), the only
    /// reader; the protocol has no listing because nothing else needs one.
    func everyMark() throws -> [(messageId: String, senderId: String, at: Date)] {
        try run { context in
            try context.fetch(ProcessedMessage.fetchRequest()).map { ($0.messageId, $0.senderId, $0.processedAt) }
        }
    }

    func forget(processedBefore date: Date) throws -> Int {
        try run { context in
            let req = ProcessedMessage.fetchRequest()
            req.predicate = NSPredicate(format: "processedAt < %@", date as NSDate)
            let stale = try context.fetch(req)
            stale.forEach(context.delete)
            if context.hasChanges { try context.saveOrThrow(category: "PersistentACK") }
            return stale.count
        }
    }

    private func row(_ messageId: String, in context: NSManagedObjectContext) throws -> ProcessedMessage? {
        let req = ProcessedMessage.fetchRequest()
        req.predicate = NSPredicate(format: "messageId == %@", messageId)
        req.fetchLimit = 1
        return try context.fetch(req).first
    }

    private func run<T>(_ body: (NSManagedObjectContext) throws -> T) throws -> T {
        let context = container.newBackgroundContext()
        return try context.performAndWait { try body(context) }
    }
}

/// Processed-envelope marks on the crate (`processed_messages`).
final class LocalStoreProcessedMessageStore: ProcessedMessageStore, @unchecked Sendable {

    private let session: LocalStoreSession

    init(session: LocalStoreSession) {
        self.session = session
    }

    func markProcessed(_ messageId: String, senderId: String, at date: Date) throws -> Bool {
        try session.store.markProcessed(messageId: messageId, senderId: senderId, processedAt: date.unixMs)
    }

    func isProcessed(_ messageId: String) throws -> Bool {
        try session.store.isProcessed(messageId: messageId)
    }

    func forget(processedBefore date: Date) throws -> Int {
        Int(clamping: try session.store.forgetProcessedBefore(cutoff: date.unixMs))
    }
}
