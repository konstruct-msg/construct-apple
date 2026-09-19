//
//  HistoryNearbyStreamTests.swift
//  ConstructMessengerTests
//
//  Incremental CTH1 reader, chunked nearby stream, two-phase drop.
//

import CoreData
import CryptoKit
import XCTest
@testable import Construct_Messenger

@MainActor
final class HistoryNearbyStreamTests: XCTestCase {

    func testIncrementalReaderSurvivesByteCuts() throws {
        let data = try fixtureStream()
        let expected = try HistorySnapshotCodec.decode(data)
        let step = max(1, data.count / 1000)
        var cuts = 0
        var cut = 0
        while cut <= data.count {
            var reader = HistorySnapshotCodec.IncrementalReader()
            let first = try reader.push(data.prefix(cut))
            if cut < data.count {
                XCTAssertThrowsError(try {
                    var r = reader
                    _ = try r.finish()
                }(), "cut \(cut) must be truncated")
            }
            let second = try reader.push(Data(data.dropFirst(cut)))
            let recs = first + second + (try reader.finish())
            XCTAssertEqual(recs, expected, "cut \(cut)")
            cuts += 1
            if cut == data.count { break }
            cut = min(data.count, cut + step)
        }
        XCTAssertGreaterThanOrEqual(cuts, 2)
    }

    func testInProcessPipeTransfersFixture() async throws {
        let recs = try fixtureRecords()
        let duplex = HistoryMemoryDuplex()
        let session = HistoryStreamSession(
            key: SymmetricKey(size: .bits256),
            snapshotId: Data(repeating: 0xAA, count: 16),
            userId: Data(repeating: 0x01, count: 16)
        )
        let stream = AsyncThrowingStream<HistoryRecord, Error> { cont in
            recs.forEach { cont.yield($0) }
            cont.finish()
        }
        async let send: Void = HistoryNearbyStream.send(stream, over: duplex.left, session: session)
        var got: [HistoryRecord] = []
        for try await rec in HistoryNearbyStream.receive(over: duplex.right, session: session) {
            got.append(rec)
        }
        try await send
        XCTAssertEqual(got, recs)
    }

    func testPhase2DropLeavesPhase1Rows() async throws {
        let local = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let storeB = PersistenceController(inMemory: true).container
        let ctxB = storeB.viewContext
        let session = HistoryStreamSession(
            key: SymmetricKey(size: .bits256),
            snapshotId: Data(repeating: 0xAA, count: 16),
            userId: try XCTUnwrap(HistoryAccountID.raw(local))
        )
        let coord = HistoryTransferCoordinator()

        let duplex1 = HistoryMemoryDuplex()
        let phase1 = try fixtureRecords(userId: try XCTUnwrap(HistoryAccountID.raw(local)))
        async let send1: Void = coord.sendTranscript(
            records: Self.stream(phase1),
            over: duplex1.left,
            session: session
        )
        _ = try await coord.importStream(
            over: duplex1.right,
            session: session,
            expectedUserId: local,
            in: ctxB
        )
        try await send1
        XCTAssertEqual(coord.phase, .chatsTransferred)
        let usersAfterPhase1 = try ctxB.count(for: User.fetchRequest())
        XCTAssertGreaterThan(usersAfterPhase1, 0)

        var blob = Construct_Client_History_V1_HistoryMediaBlob()
        blob.mediaID = "drop-blob"
        blob.blob = Data(repeating: 0x33, count: 70_000)
        var manifest = Construct_Client_History_V1_HistoryManifest()
        manifest.formatVersion = 1
        manifest.phase = 2
        manifest.userID = try XCTUnwrap(HistoryAccountID.raw(local))
        manifest.snapshotID = session.snapshotId
        let phase2: [HistoryRecord] = [.manifest(manifest), .mediaBlob(blob), .end]

        let duplex2 = HistoryMemoryDuplex()
        duplex2.dropOutbound(afterSends: 1)
        let sendTask = Task {
            try await coord.sendMedia(
                records: Self.stream(phase2),
                over: duplex2.left,
                session: session
            )
        }
        let recvTask = Task {
            try await coord.importStream(
                over: duplex2.right,
                session: session,
                expectedUserId: local,
                in: ctxB
            )
        }
        _ = await sendTask.result
        _ = await recvTask.result
        XCTAssertEqual(coord.phase, .mediaIncomplete)
        XCTAssertEqual(
            try ctxB.count(for: User.fetchRequest()),
            usersAfterPhase1,
            "phase-1 rows must survive a phase-2 drop"
        )
    }

    func testWrongChunkIndexDoesNotOpenOnTheStream() async throws {
        let recs = try fixtureRecords()
        let duplex = HistoryMemoryDuplex()
        let key = SymmetricKey(size: .bits256)
        let snap = Data(repeating: 0xAA, count: 16)
        let user = Data(repeating: 0x01, count: 16)
        let sendSession = HistoryStreamSession(key: key, snapshotId: snap, userId: user)
        let recvSession = HistoryStreamSession(key: key, snapshotId: snap, userId: Data(repeating: 0x02, count: 16))
        let stream = AsyncThrowingStream<HistoryRecord, Error> { cont in
            recs.forEach { cont.yield($0) }
            cont.finish()
        }
        async let send: Void = HistoryNearbyStream.send(stream, over: duplex.left, session: sendSession)
        do {
            for try await _ in HistoryNearbyStream.receive(over: duplex.right, session: recvSession) {}
            XCTFail("AAD user_id mismatch must not open")
        } catch {
            // expected
        }
        try? await send
    }

    // MARK: - Fixtures

    private func fixtureRecords(userId: Data = Data(repeating: 0x01, count: 16)) throws -> [HistoryRecord] {
        var m = Construct_Client_History_V1_HistoryManifest()
        m.formatVersion = 1
        m.phase = 1
        m.userID = userId
        m.snapshotID = Data(repeating: 0xAA, count: 16)
        var recs: [HistoryRecord] = [.manifest(m)]
        for i in 0..<40 {
            var c = Construct_Client_History_V1_HistoryContact()
            c.userID = Data(repeating: UInt8(i & 0xFF), count: 16)
            c.displayName = "c\(i)"
            recs.append(.contact(c))
        }
        recs.append(.end)
        return recs
    }

    private func fixtureStream() throws -> Data {
        try HistorySnapshotCodec.encode(fixtureRecords())
    }

    private static func stream(_ recs: [HistoryRecord]) -> AsyncThrowingStream<HistoryRecord, Error> {
        AsyncThrowingStream { cont in
            recs.forEach { cont.yield($0) }
            cont.finish()
        }
    }
}
