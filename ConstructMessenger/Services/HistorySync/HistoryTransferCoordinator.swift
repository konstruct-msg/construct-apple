//
//  HistoryTransferCoordinator.swift
//  Construct Messenger
//
//  Two nearby connections per run (K18): phase 1 transcript, then phase 2 media.
//  Each phase is its own stream (own snapshot_id on a live handshake). A drop
//  in phase 2 leaves phase-1 rows. Skip is type 0x03, not an inner CTH1 record.
//

import CoreData
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
        items: AsyncThrowingStream<HistoryOutbound, Error>,
        through sender: HistorySender,
        over transport: HistoryByteTransport
    ) async throws {
        phase = .transcript
        try await withBackgroundTask {
            try await HistoryCoreStream.send(items, through: sender) { try await transport.send($0) }
        }
        phase = .chatsTransferred
    }

    func sendMedia(
        items: AsyncThrowingStream<HistoryOutbound, Error>,
        through sender: HistorySender,
        over transport: HistoryByteTransport
    ) async throws {
        phase = .media
        do {
            try await withBackgroundTask {
                try await HistoryCoreStream.send(items, through: sender) { try await transport.send($0) }
            }
            phase = .complete
        } catch {
            phase = .mediaIncomplete
            throw error
        }
    }

    /// Receive one stream into the store: records applied as their chunk opens, one save per
    /// `HistorySnapshotImporter.saveBatchSize`, media written to disk as it arrives.
    func receive(
        from source: HistoryByteSource,
        into receiver: HistoryReceiver,
        pin: HistoryQRPin,
        expectedUserId: String,
        context: NSManagedObjectContext,
        resolve: (_ deviceIdHex: String) async throws -> HistoryKnownKeys,
        reply: ((Data) async throws -> Void)?,
        onManifest: ((Construct_Client_History_V1_HistoryManifest) -> Void)? = nil
    ) async throws -> HistoryCoreStream.Outcome {
        let sink = HistoryImportSink(expectedUserId: expectedUserId, context: context)
        sink.onManifest = onManifest
        sink.onProgress = { [weak self] seen in self?.progress = Double(seen) }
        return try await HistoryCoreStream.receive(
            from: source,
            into: receiver,
            sink: sink,
            pin: pin,
            resolve: resolve,
            reply: reply
        )
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
