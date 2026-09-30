//
//  HistoryCoreStream.swift
//  Construct Messenger
//
//  The platform half of a history transfer: bytes between a channel (socket or file) and the
//  core's `HistorySender` / `HistoryReceiver`, records between the core and Core Data.
//
//  The protocol is the core's since 2026-09-29 (`construct-core/src/history/`,
//  decisions/history-transfer-protocol-in-the-core.md): CTH1 framing, record order, the chunk
//  cipher, CTT1 v2 and CTHF, and every check on them. This file frames nothing, seals nothing and
//  verifies nothing. A transcript record crosses as its protobuf bytes and is decoded once, here,
//  on its way into the store; a media file crosses in 64 KiB pieces and is never held whole.
//

import CoreData
import Foundation
import SwiftProtobuf

// MARK: - Records

/// Record type bytes of CTH1 v1. The core judges them; the platform needs them to say which proto
/// a record's bytes are.
enum HistoryRecordType {
    static let manifest: UInt8 = 0x01
    static let contact: UInt8 = 0x02
    static let chat: UInt8 = 0x03
    static let message: UInt8 = 0x04
    static let reaction: UInt8 = 0x05
    static let peer: UInt8 = 0x06
    static let call: UInt8 = 0x07
}

/// A transcript record, decoded. Media is not a record here: it streams (`HistoryOutbound.media`
/// on the way out, `HistoryMediaSink` on the way in).
enum HistoryRecord: Equatable {
    case manifest(Construct_Client_History_V1_HistoryManifest)
    case contact(Construct_Client_History_V1_HistoryContact)
    case chat(Construct_Client_History_V1_HistoryChat)
    case message(Construct_Client_History_V1_HistoryMessage)
    case reaction(Construct_Client_History_V1_HistoryReaction)
    case peerDevice(Construct_Client_History_V1_HistoryPeerDevice)
    case call(Construct_Client_History_V1_HistoryCall)
    /// A record the core passed over — an unknown type, or a message with a body from a later
    /// version. Counted, never applied.
    case skipped(type: UInt8)

    /// The record as the core takes it.
    func wire() throws -> HistoryRecordOut {
        let (type, proto): (UInt8, Data)
        switch self {
        case .manifest(let m): (type, proto) = (HistoryRecordType.manifest, try m.serializedData())
        case .contact(let c): (type, proto) = (HistoryRecordType.contact, try c.serializedData())
        case .chat(let c): (type, proto) = (HistoryRecordType.chat, try c.serializedData())
        case .message(let m): (type, proto) = (HistoryRecordType.message, try m.serializedData())
        case .reaction(let r): (type, proto) = (HistoryRecordType.reaction, try r.serializedData())
        case .peerDevice(let p): (type, proto) = (HistoryRecordType.peer, try p.serializedData())
        case .call(let c): (type, proto) = (HistoryRecordType.call, try c.serializedData())
        case .skipped: throw HistoryError.Malformed(message: "a skipped record is not sent")
        }
        return HistoryRecordOut(recordType: type, proto: proto)
    }

    /// A record the core released. It has already checked the protocol rules; a proto that does
    /// not decode here is still malformed.
    static func decode(type: UInt8, proto: Data) throws -> HistoryRecord {
        do {
            switch type {
            case HistoryRecordType.manifest:
                return .manifest(try .init(serializedBytes: proto))
            case HistoryRecordType.contact:
                return .contact(try .init(serializedBytes: proto))
            case HistoryRecordType.chat:
                return .chat(try .init(serializedBytes: proto))
            case HistoryRecordType.message:
                return .message(try .init(serializedBytes: proto))
            case HistoryRecordType.reaction:
                return .reaction(try .init(serializedBytes: proto))
            case HistoryRecordType.peer:
                return .peerDevice(try .init(serializedBytes: proto))
            case HistoryRecordType.call:
                return .call(try .init(serializedBytes: proto))
            default:
                return .skipped(type: type)
            }
        } catch {
            throw HistoryError.Malformed(message: "malformed")
        }
    }
}

/// What the encoder hands the sender: transcript records, then media by reference — the file is
/// read in pieces as it is sent, never loaded.
enum HistoryOutbound {
    case record(HistoryRecord)
    case media(id: String, mime: String)
}

// MARK: - Byte channels

/// Where received bytes come from. `nil` is the end of the input: the socket closed or the file
/// ended.
protocol HistoryByteSource: AnyObject {
    func read(exactly count: Int) async throws -> Data?
}

/// A socket, over the nearby transport.
final class HistoryTransportSource: HistoryByteSource {
    private let transport: HistoryByteTransport

    init(_ transport: HistoryByteTransport) {
        self.transport = transport
    }

    func read(exactly count: Int) async throws -> Data? {
        do {
            return try await transport.receiveExact(count)
        } catch is HistoryByteTransportError {
            return nil
        } catch NearbyTransferError.connectionClosed {
            return nil
        }
    }
}

/// A `.cthf` file.
final class HistoryFileSource: HistoryByteSource {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func read(exactly count: Int) async throws -> Data? {
        guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }
}

// MARK: - The stream

enum HistoryCoreStream {
    /// A media file is read and handed to the core in pieces of this size.
    static let mediaPieceSize = 64 * 1024
    /// Transcript records are handed over in batches of about this many bytes: one FFI call per
    /// chunk's worth, not one per record.
    static let recordBatchBytes = 64 * 1024

    /// Push what the encoder yields through `sender`, writing every sealed chunk as it is made,
    /// then the end. The opening or header (`sender.firstFrame()`) is the caller's to write first.
    static func send<Items: AsyncSequence>(
        _ items: Items,
        through sender: HistorySender,
        write: (Data) async throws -> Void
    ) async throws where Items.Element == HistoryOutbound {
        var batch: [HistoryRecordOut] = []
        var batchBytes = 0

        func flush() async throws {
            guard !batch.isEmpty else { return }
            let out = try sender.pushRecords(records: batch)
            batch.removeAll(keepingCapacity: true)
            batchBytes = 0
            if !out.isEmpty { try await write(out) }
        }

        for try await item in items {
            switch item {
            case .record(let record):
                let wire = try record.wire()
                batch.append(wire)
                batchBytes += wire.proto.count
                if batchBytes >= recordBatchBytes { try await flush() }
            case .media(let id, let mime):
                try await flush()
                try await sendMedia(id: id, mime: mime, through: sender, write: write)
            }
        }
        try await flush()
        try await write(try sender.finish())
    }

    /// The same, for records already collected on a context's queue (the file writer).
    static func send(
        _ items: [HistoryOutbound],
        through sender: HistorySender,
        write: (Data) async throws -> Void
    ) async throws {
        let stream = AsyncStream<HistoryOutbound> { continuation in
            for item in items { continuation.yield(item) }
            continuation.finish()
        }
        try await send(stream, through: sender, write: write)
    }

    /// One media file, streamed from disk. The length announced is the file's size when it is
    /// opened; a file that vanished since the plan is left out rather than failing the stream.
    private static func sendMedia(
        id: String,
        mime: String,
        through sender: HistorySender,
        write: (Data) async throws -> Void
    ) async throws {
        let url = MediaManager.onDiskURL(for: id)
        // Clear size and clear chunks: the file is sealed at rest (`AtRestFiles`), the core
        // seals it again for the other device.
        guard let size = AtRestFiles.clearSize(of: url),
              let chunks = try? AtRestFiles.chunks(of: url, context: MediaManager.sealContext(for: id)) else { return }
        try await write(try sender.beginMedia(mediaId: id, mimeType: mime, byteLen: size))
        var remaining = size
        while remaining > 0 {
            guard let chunk = chunks.next(), !chunk.isEmpty else {
                // Shorter than announced: the core refuses to end a blob early, so this stream
                // cannot be completed. Fail it rather than send a lie.
                throw HistoryError.Truncated(message: "truncated")
            }
            var offset = chunk.startIndex
            while offset < chunk.endIndex, remaining > 0 {
                let end = chunk.index(offset, offsetBy: min(mediaPieceSize, Int(remaining)), limitedBy: chunk.endIndex) ?? chunk.endIndex
                let piece = chunk[offset..<end]
                remaining -= UInt64(piece.count)
                try await write(try sender.pushMedia(piece: Data(piece)))
                offset = end
            }
        }
    }

    enum Outcome: Equatable {
        case imported(HistoryImportSummary, manifestPhase: UInt32)
        case skipped
    }

    /// Read what `receiver` asks for, hand every event to `sink`, and stop once for the other
    /// device's keys: `resolve` fetches them from our own account's directory entry by the device
    /// id the frame names. A nearby receiver's reply goes back through `reply`.
    static func receive(
        from source: HistoryByteSource,
        into receiver: HistoryReceiver,
        sink: HistoryImportSink,
        pin: HistoryQRPin,
        resolve: (_ deviceIdHex: String) async throws -> HistoryKnownKeys,
        reply: ((Data) async throws -> Void)?
    ) async throws -> Outcome {
        do {
            return try await receiveLoop(from: source, into: receiver, sink: sink, pin: pin, resolve: resolve, reply: reply)
        } catch {
            sink.abandonMedia()
            throw error
        }
    }

    private static func receiveLoop(
        from source: HistoryByteSource,
        into receiver: HistoryReceiver,
        sink: HistoryImportSink,
        pin: HistoryQRPin,
        resolve: (_ deviceIdHex: String) async throws -> HistoryKnownKeys,
        reply: ((Data) async throws -> Void)?
    ) async throws -> Outcome {
        while true {
            // Nothing to read means the receiver has stopped — for keys, a skip or the end — and
            // an empty feed asks it which.
            let need = Int(receiver.need())
            var data = Data()
            if need > 0 {
                guard let read = try await source.read(exactly: need) else {
                    try receiver.endOfInput()
                    return try await sink.finish()
                }
                data = read
            }
            let step = try receiver.feed(data: data)
            try await sink.consume(step.events)
            switch step.status {
            case .needMore:
                continue
            case .awaitKeys(let senderDeviceId):
                let known = try await resolve(senderDeviceId)
                if case .bundleOnly = pin {
                    Log.info("history_trust root=bundle_only (Flow B residual)", category: "HistorySync")
                }
                if let answer = try receiver.accept(known: known, pin: pin.core) {
                    try await reply?(answer)
                }
            case .skipped:
                return .skipped
            case .done:
                try receiver.endOfInput()
                return try await sink.finish()
            }
        }
    }
}

extension HistoryQRPin {
    var core: HistoryPin {
        switch self {
        case .pinned(let fp): return .fingerprint(fingerprint: fp)
        case .bundleOnly: return .bundleOnly
        case .absent: return .absent
        }
    }
}

// MARK: - Import

/// Where received events go: transcript records into Core Data through the importer, media into
/// files. Records are applied on `context`'s queue, one hop per chunk of events.
final class HistoryImportSink {
    private let importer = HistorySnapshotImporter()
    private let context: NSManagedObjectContext
    private let expectedUserId: String
    private let media = HistoryMediaSink()
    private var summary = HistoryImportSummary()
    private var sinceSave = 0
    private(set) var manifestPhase: UInt32 = 0
    var onManifest: ((Construct_Client_History_V1_HistoryManifest) -> Void)?
    /// Records applied so far, after each chunk's worth.
    var onProgress: ((Int) -> Void)?
    /// Records applied so far, for progress.
    private(set) var seen = 0

    init(expectedUserId: String, context: NSManagedObjectContext) {
        self.expectedUserId = expectedUserId
        self.context = context
    }

    func consume(_ events: [HistoryEvent]) async throws {
        var records: [HistoryRecord] = []
        for event in events {
            switch event {
            case .record(let type, let proto):
                let record = try HistoryRecord.decode(type: type, proto: proto)
                if case .manifest(let m) = record {
                    manifestPhase = m.phase
                    Log.info("history_manifest phase=\(m.phase) snapshot=\(HistorySnapshotIdentity.tag(m.snapshotID))", category: "HistorySync")
                    onManifest?(m)
                }
                records.append(record)
            case .skipped(let type):
                records.append(.skipped(type: type))
            case .mediaStart(let id, _, _):
                summary.add(try media.start(mediaId: id))
            case .mediaBytes(let data):
                try media.append(data)
            case .mediaEnd:
                summary.add(try media.end())
            case .end:
                break
            }
        }
        guard !records.isEmpty else { return }
        let importer = importer
        let expectedUserId = expectedUserId
        let context = context
        let saveEvery = HistorySnapshotImporter.saveBatchSize
        let unsavedBefore = sinceSave
        let (partial, unsaved) = try await context.perform {
            var local = HistoryImportSummary()
            var unsaved = unsavedBefore
            for record in records {
                local.add(try importer.apply(record, expectedUserId: expectedUserId, in: context))
                unsaved += 1
                if unsaved >= saveEvery {
                    try context.saveOrThrow(category: "HistorySync")
                    unsaved = 0
                }
            }
            return (local, unsaved)
        }
        sinceSave = unsaved
        summary.merge(partial)
        seen += records.count
        onProgress?(seen)
    }

    /// A transfer that failed: drop the blob in progress. Records already saved stay — the import
    /// is additive and a retry is idempotent.
    func abandonMedia() {
        media.abandon()
    }

    func finish() async throws -> HistoryCoreStream.Outcome {
        media.abandon()
        if sinceSave > 0 {
            let context = context
            try await context.perform { try context.saveOrThrow(category: "HistorySync") }
            sinceSave = 0
        }
        return .imported(summary, manifestPhase: manifestPhase)
    }
}

/// Writes a received blob to its media file as it arrives. The file appears under its name only
/// once complete, so a transfer cut mid-blob leaves nothing a chat would open as a broken image.
final class HistoryMediaSink {
    private var handle: FileHandle?
    private var partURL: URL?
    private var finalURL: URL?
    /// Seals what arrives: the file is written sealed at rest (`AtRestFiles`), never in the clear.
    private var sealer: SealedFile.Writer?

    /// A blob begins. One already on disk is kept, and this copy's bytes are dropped.
    func start(mediaId: String) throws -> HistoryApplyResult {
        abandon()
        guard !mediaId.isEmpty, !mediaId.contains("/") else { return .ignored }
        let url = MediaManager.onDiskURL(for: mediaId)
        if FileManager.default.fileExists(atPath: url.path) {
            return .skipped(.mediaAlreadyPresent)
        }
        let part = url.deletingLastPathComponent().appendingPathComponent(".\(mediaId).history-part")
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard let key = LocalStoreKey.current() else { return .ignored }
        guard FileManager.default.createFile(atPath: part.path, contents: nil, attributes: attributes) else {
            return .ignored
        }
        let sealer = try SealedFile.Writer(key: key, context: MediaManager.sealContext(for: mediaId))
        handle = try FileHandle(forWritingTo: part)
        try handle?.write(contentsOf: sealer.header)
        self.sealer = sealer
        partURL = part
        finalURL = url
        return .ignored
    }

    func append(_ data: Data) throws {
        guard let sealer else { return }
        try handle?.write(contentsOf: try sealer.append(data))
    }

    func end() throws -> HistoryApplyResult {
        guard let handle, let partURL, let finalURL, let sealer else { return .ignored }
        try handle.write(contentsOf: try sealer.finish())
        self.sealer = nil
        try handle.close()
        self.handle = nil
        self.partURL = nil
        self.finalURL = nil
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        return .applied
    }

    /// Drop a blob that did not finish.
    func abandon() {
        try? handle?.close()
        handle = nil
        sealer = nil
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        partURL = nil
        finalURL = nil
    }
}
