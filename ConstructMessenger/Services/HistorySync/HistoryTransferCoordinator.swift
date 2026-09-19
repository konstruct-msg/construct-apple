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
    ///
    /// Records are pulled here (main actor) and applied in batches inside `context.perform`,
    /// so a background context is touched only on its own queue — one hop per batch, not
    /// per record.
    func importStream(
        over transport: HistoryByteTransport,
        session: HistoryStreamSession,
        expectedUserId: String,
        in context: NSManagedObjectContext,
        onManifest: ((Construct_Client_History_V1_HistoryManifest) -> Void)? = nil
    ) async throws -> HistoryImportSummary {
        let importer = HistorySnapshotImporter()
        var summary = HistoryImportSummary()
        var batch: [HistoryRecord] = []
        var seen = 0

        func flush() async throws {
            guard !batch.isEmpty else { return }
            let records = batch
            batch.removeAll(keepingCapacity: true)
            let partial = try await context.perform {
                var local = HistoryImportSummary()
                for record in records {
                    local.add(try importer.apply(record, expectedUserId: expectedUserId, in: context))
                }
                try context.saveOrThrow(category: "HistorySync")
                return local
            }
            summary.applied += partial.applied
            summary.conflictKeepExisting += partial.conflictKeepExisting
            for (reason, count) in partial.skipped {
                summary.skipped[reason, default: 0] += count
            }
        }

        for try await record in HistoryNearbyStream.receive(over: transport, session: session) {
            if case .manifest(let m) = record { onManifest?(m) }
            batch.append(record)
            seen += 1
            if batch.count >= HistorySnapshotImporter.saveBatchSize {
                try await flush()
            }
            progress = Double(seen)
        }
        try await flush()
        return summary
    }

    func markSkipped() {
        phase = .skipped
    }

    func markComplete() {
        phase = .complete
    }

    /// Receiver-side phase bookkeeping: the importer does not know which phase it applied
    /// until the manifest arrives, and the second connection is the caller's to open.
    func markChatsTransferred() {
        phase = .chatsTransferred
    }

    func markMedia() {
        phase = .media
    }

    func markMediaIncomplete() {
        phase = .mediaIncomplete
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
