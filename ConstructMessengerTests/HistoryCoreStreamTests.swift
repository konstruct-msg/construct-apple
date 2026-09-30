//
//  HistoryCoreStreamTests.swift
//  ConstructMessengerTests
//
//  The platform half of a history transfer, between two real cores: records into Core Data,
//  media onto disk in pieces, and what is left behind when a stream is cut. The protocol itself —
//  framing, order, chunks, frames, checks — is tested in construct-core against the cross-client
//  vectors; this file does not repeat it.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class HistoryCoreStreamTests: XCTestCase {

    private nonisolated static let userId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private var userId: String { Self.userId }
    private nonisolated var userRaw: Data { HistoryAccountID.raw(Self.userId)! }

    /// A device of the account as the directory lists it, and its core.
    private struct Device {
        let core: OrchestratorCore
        let deviceId: String
        let keys: HistoryPeerKeys
        var known: HistoryKnownKeys { HistoryKnownKeys(identityPublic: keys.identityPublic, hybridPublic: keys.hybridPublic) }
    }

    private func device() throws -> Device {
        let (core, deviceId) = try makeTestDevice()
        if try core.currentKyberSpkUpload() == nil {
            _ = try core.beginKyberSpkRotation()
            XCTAssertTrue(core.commitKyberSpkRotation())
        }
        let spk = try XCTUnwrap(try core.currentKyberSpkUpload())
        return Device(
            core: core,
            deviceId: deviceId,
            keys: HistoryPeerKeys(
                identityPublic: try core.getRegistrationBundleFields().identityPublic,
                hybridPublic: try XCTUnwrap(core.hybridSignaturePublicKey()),
                kyberPrekeyPublic: spk.publicKey,
                kyberPrekeyId: spk.keyId
            )
        )
    }

    private nonisolated func manifest(snapshotId: Data, phase: UInt32) -> HistoryRecord {
        var m = Construct_Client_History_V1_HistoryManifest()
        m.formatVersion = 1
        m.phase = phase
        m.userID = userRaw
        m.snapshotID = snapshotId
        return .manifest(m)
    }

    private nonisolated func contacts(_ n: Int) -> [HistoryOutbound] {
        (0..<n).map { i in
            var c = Construct_Client_History_V1_HistoryContact()
            c.userID = Data(repeating: UInt8(i + 1), count: 16)
            c.displayName = "c\(i)"
            return .record(.contact(c))
        }
    }

    /// A media file on this device's disk, as the encoder would find it.
    private func mediaFile(bytes: Int) throws -> (id: String, data: Data) {
        let id = "history-test-\(UUID().uuidString.lowercased())"
        let data = Data((0..<bytes).map { UInt8(($0 * 31 + 7) % 256) })
        try FileManager.default.createDirectory(
            at: MediaManager.onDiskURL(for: id).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: MediaManager.onDiskURL(for: id))
        addTeardownBlock { try? FileManager.default.removeItem(at: MediaManager.onDiskURL(for: id)) }
        return (id, data)
    }

    private func partFiles() throws -> [String] {
        let dir = MediaManager.onDiskURL(for: "x").deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".history-part") } ?? []
    }

    /// Write a phase-3 file from `old` for `new` carrying `contactCount` contacts and one media file.
    private func writeFile(from old: Device, to new: Device, contactCount: Int, media: (id: String, data: Data)) async throws -> URL {
        let sender = try old.core.historyOfferFile(userId: userRaw, peer: new.keys)
        let items: [HistoryOutbound] = [.record(manifest(snapshotId: sender.snapshotId(), phase: 3))]
            + contacts(contactCount)
            + [.media(id: media.id, mime: "image/jpeg")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).cthf")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: sender.firstFrame())
        try await HistoryCoreStream.send(items, through: sender) { try handle.write(contentsOf: $0) }
        try handle.close()
        return url
    }

    private func importFile(_ url: URL, into new: Device, from old: Device, context: NSManagedObjectContext) async throws -> HistoryCoreStream.Outcome {
        let sink = HistoryImportSink(expectedUserId: userId, context: context)
        return try await HistoryCoreStream.receive(
            from: try HistoryFileSource(url: url),
            into: new.core.historyReceive(userId: userRaw, fromFile: true),
            sink: sink,
            pin: .bundleOnly,
            resolve: { hex in
                XCTAssertEqual(hex, old.deviceId, "the receiver asks the directory for the device the header named")
                return old.known
            },
            reply: nil
        )
    }

    /// A file crosses whole: its records are in the store, and the media file is on disk
    /// byte-exact — assembled from pieces, never held — with no partial file left behind.
    func testAFileImportsRecordsAndWritesMediaWhole() async throws {
        let old = try device()
        let new = try device()
        let media = try mediaFile(bytes: 150_000)
        let url = try await writeFile(from: old, to: new, contactCount: 3, media: media)
        // The new device does not have it yet.
        try FileManager.default.removeItem(at: MediaManager.onDiskURL(for: media.id))

        let context = PersistenceController(inMemory: true).container.viewContext
        let outcome = try await importFile(url, into: new, from: old, context: context)

        guard case .imported(let summary, let phase) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(phase, 3)
        XCTAssertEqual(try context.count(for: User.fetchRequest()), 3)
        XCTAssertEqual(summary.applied, 4, "three contacts and one media file")
        // Written sealed at rest, never in the clear (`AtRestFiles`); read back whole.
        XCTAssertTrue(SealedFile.isSealed(fileAt: MediaManager.onDiskURL(for: media.id)))
        XCTAssertEqual(MediaManager.loadOnDisk(mediaId: media.id), media.data)
        XCTAssertEqual(try partFiles(), [])
    }

    /// A media file the new device already has is kept, and the incoming copy is dropped.
    func testAMediaFileAlreadyPresentIsKept() async throws {
        let old = try device()
        let new = try device()
        let media = try mediaFile(bytes: 10_000)
        let url = try await writeFile(from: old, to: new, contactCount: 1, media: media)
        try Data("kept".utf8).write(to: MediaManager.onDiskURL(for: media.id))

        let context = PersistenceController(inMemory: true).container.viewContext
        guard case .imported(let summary, _) = try await importFile(url, into: new, from: old, context: context) else {
            return XCTFail("expected an import")
        }
        XCTAssertEqual(summary.skipped[.mediaAlreadyPresent], 1)
        XCTAssertEqual(try Data(contentsOf: MediaManager.onDiskURL(for: media.id)), Data("kept".utf8))
    }

    /// A file cut in the middle of a media blob is refused as truncated, and leaves no media file
    /// and no partial one: a chat must not open half an image.
    func testAStreamCutMidMediaLeavesNoFile() async throws {
        let old = try device()
        let new = try device()
        let media = try mediaFile(bytes: 200_000)
        let url = try await writeFile(from: old, to: new, contactCount: 1, media: media)
        try FileManager.default.removeItem(at: MediaManager.onDiskURL(for: media.id))
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 30_000).write(to: url)

        let context = PersistenceController(inMemory: true).container.viewContext
        do {
            _ = try await importFile(url, into: new, from: old, context: context)
            XCTFail("a cut file must not import")
        } catch {
            guard case .Truncated = error as? HistoryError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaManager.onDiskURL(for: media.id).path))
        XCTAssertEqual(try partFiles(), [])
    }

    /// The offering side of one nearby phase over a duplex: opening, reply, stream.
    private func offer(
        from old: Device,
        to new: Device,
        items: @escaping (Data) -> [HistoryOutbound],
        over transport: HistoryByteTransport,
        coordinator: HistoryTransferCoordinator,
        media: Bool
    ) async throws {
        let sender = try old.core.historyOfferNearby(userId: userRaw, peer: new.keys, skip: false, pinnedReceiverIdentity: nil)
        try await transport.send(sender.firstFrame())
        try sender.acceptReply(reply: try await transport.receiveExact(Int(historyReplyLen())))
        let list = items(sender.snapshotId())
        let stream = AsyncThrowingStream<HistoryOutbound, Error> { cont in
            list.forEach { cont.yield($0) }
            cont.finish()
        }
        if media {
            try await coordinator.sendMedia(items: stream, through: sender, over: transport)
        } else {
            try await coordinator.sendTranscript(items: stream, through: sender, over: transport)
        }
    }

    private func receive(
        into new: Device,
        from old: Device,
        over transport: HistoryByteTransport,
        coordinator: HistoryTransferCoordinator,
        context: NSManagedObjectContext
    ) async throws -> HistoryCoreStream.Outcome {
        try await coordinator.receive(
            from: HistoryTransportSource(transport),
            into: new.core.historyReceive(userId: userRaw, fromFile: false),
            pin: .bundleOnly,
            expectedUserId: userId,
            context: context,
            resolve: { _ in old.known },
            reply: { try await transport.send($0) }
        )
    }

    /// K18: the transcript is committed before the first media byte, so a drop in phase 2 loses
    /// nothing phase 1 brought.
    func testAPhase2DropKeepsPhase1Rows() async throws {
        let old = try device()
        let new = try device()
        let context = PersistenceController(inMemory: true).container.viewContext
        let sending = HistoryTransferCoordinator()
        let receiving = HistoryTransferCoordinator()

        let phase1 = HistoryMemoryDuplex()
        async let sent: Void = offer(
            from: old, to: new,
            items: { [self] snapshot in [.record(manifest(snapshotId: snapshot, phase: 1))] + contacts(40) },
            over: phase1.left, coordinator: sending, media: false
        )
        let first = try await receive(into: new, from: old, over: phase1.right, coordinator: receiving, context: context)
        try await sent
        guard case .imported(_, 1) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(sending.phase, .chatsTransferred)
        XCTAssertEqual(try context.count(for: User.fetchRequest()), 40)

        let media = try mediaFile(bytes: 200_000)
        let phase2 = HistoryMemoryDuplex()
        // The opening, then two writes of the stream, then the pipe fails.
        phase2.dropOutbound(afterSends: 3)
        let sendTask = Task { @MainActor in
            try await self.offer(
                from: old, to: new,
                items: { [self] snapshot in [.record(manifest(snapshotId: snapshot, phase: 2)), .media(id: media.id, mime: "")] },
                over: phase2.left, coordinator: sending, media: true
            )
        }
        let receiveTask = Task { @MainActor in
            try await self.receive(into: new, from: old, over: phase2.right, coordinator: receiving, context: context)
        }
        _ = await sendTask.result
        phase2.right.close()
        _ = await receiveTask.result

        XCTAssertEqual(sending.phase, .mediaIncomplete)
        XCTAssertEqual(try context.count(for: User.fetchRequest()), 40, "phase-1 rows survive a phase-2 drop")
        XCTAssertEqual(try partFiles(), [])
    }
}
