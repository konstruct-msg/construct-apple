//
//  HistoryTransferCoordinator.swift
//  Construct Messenger
//
//  Two nearby connections per run (K18): phase 1 transcript, then phase 2 media.
//  Each phase is its own stream (own snapshot_id on a live handshake). A drop
//  in phase 2 leaves phase-1 rows. Skip is type 0x03, not an inner CTH1 record.
//

import CoreData
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum HistoryTransferPhase: Equatable {
    case idle
    case transcript
    case chatsTransferred
    case media
    case complete
    case mediaIncomplete
    case skipped
    case saveFileInstead
}

@MainActor
@Observable
final class HistoryTransferCoordinator {
    private(set) var phase: HistoryTransferPhase = .idle
    var progress: Double = 0

    func sendTranscript(
        records: AsyncThrowingStream<HistoryRecord, Error>,
        over transport: HistoryByteTransport,
        session: HistoryStreamSession
    ) async throws {
        phase = .transcript
        try await withBackgroundTask {
            try await HistoryNearbyStream.send(records, over: transport, session: session)
        }
        phase = .chatsTransferred
    }

    func sendMedia(
        records: AsyncThrowingStream<HistoryRecord, Error>,
        over transport: HistoryByteTransport,
        session: HistoryStreamSession
    ) async throws {
        phase = .media
        do {
            try await withBackgroundTask {
                try await HistoryNearbyStream.send(records, over: transport, session: session)
            }
            phase = .complete
        } catch {
            phase = .mediaIncomplete
            throw error
        }
    }

    /// Apply records as they arrive. One save per `HistorySnapshotImporter.saveBatchSize`.
    func importStream(
        over transport: HistoryByteTransport,
        session: HistoryStreamSession,
        expectedUserId: String,
        in context: NSManagedObjectContext
    ) async throws -> HistoryImportSummary {
        let importer = HistorySnapshotImporter()
        var summary = HistoryImportSummary()
        var sinceSave = 0
        for try await record in HistoryNearbyStream.receive(over: transport, session: session) {
            let result = try importer.apply(record, expectedUserId: expectedUserId, in: context)
            summary.add(result)
            sinceSave += 1
            if sinceSave >= HistorySnapshotImporter.saveBatchSize {
                try context.saveOrThrow(category: "HistorySync")
                sinceSave = 0
            }
        }
        if sinceSave > 0 {
            try context.saveOrThrow(category: "HistorySync")
        }
        return summary
    }

    func markSkipped() {
        phase = .skipped
    }

    func markSaveFileInstead() {
        phase = .saveFileInstead
    }

    private func withBackgroundTask(_ body: () async throws -> Void) async throws {
        #if os(iOS)
        var expired = false
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask {
            expired = true
            self.phase = .saveFileInstead
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        defer {
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
            }
        }
        try await body()
        if expired { throw NearbyTransferError.transferCancelled }
        #else
        try await body()
        #endif
    }
}
