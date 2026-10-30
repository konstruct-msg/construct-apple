//
//  HistoryTransferCoordinator.swift
//  Construct Messenger
//
//  Two nearby connections per run (K18): phase 1 transcript, then phase 2 media.
//  Each phase is its own stream (own snapshot_id on a live handshake). A drop
//  in phase 2 leaves phase-1 rows. Skip is type 0x03, not an inner CTH1 record.
//

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

/// How much of the media phase has moved. The total is the manifest's `mediaByteCount`, so both
/// devices know it before the first byte; the estimate is the rate so far.
struct HistoryTransferProgress: Equatable {
    var doneBytes: UInt64 = 0
    let totalBytes: UInt64
    let startedAt: Date

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }

    /// No estimate before this much time and share have passed: the first pieces include the
    /// connection settling and would promise too much or too little.
    static let estimateAfter: TimeInterval = 2
    static let estimateAfterFraction = 0.03

    /// Seconds left at the rate so far, or nil while too early to say.
    static func secondsLeft(done: UInt64, total: UInt64, elapsed: TimeInterval) -> TimeInterval? {
        guard total > 0, done > 0, done < total, elapsed >= estimateAfter,
              Double(done) / Double(total) >= estimateAfterFraction else { return nil }
        let rate = Double(done) / elapsed
        return Double(total - done) / rate
    }

    /// How the time left is said: seconds up to a minute, rounded up to five so the number does
    /// not flicker by one each tick; whole minutes, rounded up, after that.
    static func timeLeft(seconds: TimeInterval) -> (key: String, value: Int) {
        if seconds < 60 {
            return ("history_sync_eta_seconds", max(5, Int((seconds / 5).rounded(.up)) * 5))
        }
        return ("history_sync_eta_minutes", Int((seconds / 60).rounded(.up)))
    }

    func secondsLeft(now: Date) -> TimeInterval? {
        Self.secondsLeft(done: doneBytes, total: totalBytes, elapsed: now.timeIntervalSince(startedAt))
    }
}

@MainActor
@Observable
final class HistoryTransferCoordinator {
    private(set) var phase: HistoryTransferPhase = .idle
    /// The system refuses this app the local network (the Local Network permission is off), so
    /// the two devices cannot find each other. Set from the listener or browser while waiting.
    private(set) var localNetworkDenied = false
    /// The media phase's bytes, on both devices; nil outside it.
    private(set) var progress: HistoryTransferProgress?
    /// Bytes counted but not yet shown: the screen moves per whole percent, not per 64 KB piece.
    @ObservationIgnored private var unshownBytes: UInt64 = 0

    /// How long a finished transfer shows its result before its screen closes itself. The
    /// outcomes that leave something to do — a file to save, media to retry — stay open.
    static let resultHold: Duration = .milliseconds(1500)

    func sendTranscript(
        items: AsyncThrowingStream<HistoryOutbound, Error>,
        through sender: HistorySender,
        over transport: HistoryByteTransport
    ) async throws {
        phase = .transcript
        try await withBackgroundTask {
            try await HistoryCoreStream.send(items, through: sender, progress: reportProgress) { try await transport.send($0) }
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
                try await HistoryCoreStream.send(items, through: sender, progress: reportProgress) { try await transport.send($0) }
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
        resolve: @Sendable (_ deviceIdHex: String) async throws -> HistoryKnownKeys,
        reply: (@Sendable (Data) async throws -> Void)?
    ) async throws -> HistoryCoreStream.Outcome {
        let sink = HistoryImportSink(expectedUserId: expectedUserId)
        return try await HistoryCoreStream.receive(
            from: source,
            into: receiver,
            sink: sink,
            pin: pin,
            resolve: resolve,
            reply: reply,
            progress: reportProgress
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

    func markLocalNetwork(denied: Bool) {
        localNetworkDenied = denied
    }

    /// What the stream reports as it moves media, sending or receiving.
    func note(_ event: HistoryProgressEvent) {
        switch event {
        case .mediaTotal(let total):
            progress = HistoryTransferProgress(totalBytes: total, startedAt: Date())
            unshownBytes = 0
        case .mediaBytes(let count):
            guard var current = progress else { return }
            unshownBytes += UInt64(count)
            let step = max(current.totalBytes / 100, 1)
            let done = current.doneBytes + unshownBytes
            guard unshownBytes >= step || done >= current.totalBytes else { return }
            current.doneBytes = min(done, current.totalBytes)
            unshownBytes = 0
            progress = current
            if current.doneBytes == current.totalBytes {
                // The rate is what "too slow" gets measured against (2026-10-30: 49 files in 40 s,
                // and no byte count in the log to say whether that is slow).
                let seconds = Date().timeIntervalSince(current.startedAt)
                Log.info("history_media_moved bytes=\(current.totalBytes) seconds=\(String(format: "%.1f", seconds)) kbps=\(seconds > 0 ? Int(Double(current.totalBytes) / 1024 / seconds) : 0)", category: "HistorySync")
            }
        }
    }

    private var reportProgress: HistoryProgressReport {
        { event in await self.note(event) }
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
