//
//  PendingChunkStoreTests.swift
//  ConstructMessengerTests
//
//  What any `PendingChunkStore` must do. The file layout here; the `LocalStore` implementation runs
//  the same tests by overriding `makeStore()`. The crate states the same rules in
//  `construct-core/store/tests/store_test.rs` (`pending_chunks`).
//

import XCTest
@testable import Construct_Messenger

class PendingChunkStoreTests: XCTestCase {

    private var roots: [URL] = []

    func makeStore() -> any PendingChunkStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return FilePendingChunkStore(root: root)
    }

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    private func chunk(
        _ index: UInt16, of total: UInt16 = 3, message: String, sender: String = "alice",
        payload: UInt8? = nil, at seconds: TimeInterval = 1_000
    ) -> PendingChunkRecord {
        PendingChunkRecord(
            senderId: sender, messageId: message, chunkIndex: index, totalChunks: total,
            plaintextLength: Int(total) * 4, contentType: 1,
            payload: Data(repeating: payload ?? UInt8(index + 1), count: 4),
            receivedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private let m1 = UUID().uuidString.lowercased()
    private let m2 = UUID().uuidString.lowercased()

    /// A redelivered chunk keeps the copy held: the first bytes decrypted are the ones kept.
    func testARedeliveredChunkKeepsTheFirstCopy() throws {
        let store = makeStore()
        XCTAssertTrue(try store.add(chunk(0, message: m1)))
        XCTAssertFalse(try store.add(chunk(0, message: m1, payload: 0xEE)))
        XCTAssertEqual(try store.chunks(senderId: "alice", messageId: m1).first?.payload, Data(repeating: 1, count: 4))
    }

    /// By index, whatever the arrival order, and the count says how many are held.
    func testChunksComeBackInIndexOrderAndAreCounted() throws {
        let store = makeStore()
        try store.add(chunk(2, message: m1))
        try store.add(chunk(0, message: m1))
        XCTAssertEqual(try store.count(senderId: "alice", messageId: m1), 2)
        XCTAssertEqual(try store.chunks(senderId: "alice", messageId: m1).map(\.chunkIndex), [0, 2])
        XCTAssertEqual(try store.count(senderId: "alice", messageId: m2), 0)
    }

    /// A message is one sender's: another sender's chunks under the same id are not its chunks.
    ///
    /// Mutation: read every chunk as one fixed sender's — the second read reddens.
    func testOneSendersMessageIsNotAnothers() throws {
        let store = makeStore()
        try store.add(chunk(0, message: m1, sender: "alice"))
        try store.add(chunk(1, message: m1, sender: "mallory"))
        XCTAssertEqual(try store.chunks(senderId: "alice", messageId: m1).map(\.chunkIndex), [0])
        // Whether the other sender's own chunk is held differs: the files refuse it (one directory
        // per message id), the crate keeps it apart. Either way it never reads this sender's.
        XCTAssertFalse(
            try store.chunks(senderId: "mallory", messageId: m1).map(\.chunkIndex).contains(0),
            "and the other way round"
        )
        XCTAssertEqual(try store.count(senderId: "alice", messageId: m1), 1)
        try store.delete(senderId: "mallory", messageId: m1)
        XCTAssertEqual(try store.count(senderId: "alice", messageId: m1), 1, "deleting another sender's leaves this one")
    }

    /// Every message held, by its first chunk's arrival; deleting one removes all of its chunks.
    func testMessagesAreListedByFirstArrivalAndDeletedWhole() throws {
        let store = makeStore()
        try store.add(chunk(0, message: m2, at: 2_000))
        try store.add(chunk(0, message: m1, at: 1_000))
        try store.add(chunk(1, message: m1, at: 3_000))
        XCTAssertEqual(try store.messages().map(\.messageId), [m1, m2])

        try store.delete(senderId: "alice", messageId: m1)
        XCTAssertEqual(try store.messages().map(\.messageId), [m2])
        XCTAssertEqual(try store.count(senderId: "alice", messageId: m1), 0)
    }
}

/// The same cases on the crate's table.
final class LocalStorePendingChunkStoreTests: PendingChunkStoreTests {
    override func makeStore() -> any PendingChunkStore {
        LocalStorePendingChunkStore(session: .inMemoryForTesting())
    }
}
