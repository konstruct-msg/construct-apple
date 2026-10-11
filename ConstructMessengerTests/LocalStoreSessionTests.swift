//
//  LocalStoreSessionTests.swift
//  ConstructMessengerTests
//
//  Opening the app's store: no failure creates one. `LocalStoreSession` says why.
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class LocalStoreSessionTests: XCTestCase {

    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("construct.db") }
    private let key = SymmetricKey(data: Data(repeating: 1, count: 32))

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func device(_ id: String) -> LocalPeerDevice {
        LocalPeerDevice(deviceId: id, accountId: "alice", identityKey: Data(id.utf8), firstSeenAt: 1)
    }

    /// Mutation: open with a fresh key when there is none — a store appears on disk.
    func testNoKeyOpensNothingAndCreatesNothing() {
        guard case .failure(.keyUnavailable) = LocalStoreSession.open(at: url, key: nil) else {
            return XCTFail("opened without a key")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Mutation: on `WrongKey`, delete the file and open again — the second half reddens.
    func testAnotherKeyIsWrongKeyAndTheStoreIsLeftAsItWas() throws {
        let first = try LocalStoreSession.open(at: url, key: key).get()
        _ = try first.store.recordPeerDevice(device: device("d1"))

        let other = SymmetricKey(data: Data(repeating: 2, count: 32))
        guard case .failure(.wrongKey) = LocalStoreSession.open(at: url, key: other) else {
            return XCTFail("another key opened the store")
        }

        let again = try LocalStoreSession.open(at: url, key: key).get()
        XCTAssertEqual(try again.store.peerDevice(deviceId: "d1")?.accountId, "alice")
    }

    func testTheCratesRefusalsMapToTheirReasons() {
        XCTAssertEqual(LocalStoreSession.failure(for: LocalStoreError.WrongKey(message: "")), .wrongKey)
        XCTAssertEqual(LocalStoreSession.failure(for: LocalStoreError.SchemaTooNew(message: "")), .schemaTooNew)
        guard case .storage = LocalStoreSession.failure(for: LocalStoreError.Storage(message: "disk")) else {
            return XCTFail("a storage error is not a key or schema refusal")
        }
    }

    /// TODO 137's check "nothing on disk is in the clear", through the repositories the app will
    /// use: the file and its WAL hold neither the message, its search text nor the peer's name.
    /// No Swift mutation reaches this — the encryption is the crate's; it fails if the app's link
    /// resolves the store's `sqlite3_*` to the system library (`LocalStoreBindingTests`), which
    /// ignores `PRAGMA key` and writes every row in the clear.
    func testNothingTheRepositoriesWriteIsOnDiskInTheClear() throws {
        let session = try LocalStoreSession.open(at: url, key: key).get()
        let contacts = LocalStoreContactStore(session: session)
        var peer = ContactRecord.new(id: "peer", isContact: true, addedAt: nil)
        peer.displayName = "Unmistakable-Peer-Name"
        try contacts.insert(peer)
        let chat = try LocalStoreChatStore(session: session).openChat(withPeer: "peer").chat
        let text = "Unmistakable-Message-Text"
        try LocalStoreMessageStore(session: session).insert(MessageRecord(
            id: "m1", chatId: chat.id, fromUserId: "peer", toUserId: "me", isSentByMe: false,
            timestamp: Date(), orderKey: "k1", body: Data(text.utf8), contentType: .regular,
            deliveryStatus: .delivered, retryCount: 0, suiteId: 4, isEdited: false, editedAt: nil,
            replyToMessageId: nil, replyQuote: nil, transcript: nil, transcriptLanguage: nil,
            transcriptGeneratedAt: nil
        ), searchText: text)

        var bytes = try Data(contentsOf: url)
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")) { bytes.append(wal) }
        XCTAssertFalse(bytes.isEmpty)
        for needle in ["Unmistakable-Message", "Unmistakable-Peer", "SQLite format 3"] {
            XCTAssertNil(bytes.range(of: Data(needle.utf8)), needle)
        }
    }

    func testWipeRemovesTheFilesAndClosesTheStore() throws {
        let session = try LocalStoreSession.open(at: url, key: key).get()
        _ = try session.store.recordPeerDevice(device: device("d1"))

        try session.wipe()

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, [], "every file of the store")
        XCTAssertThrowsError(try session.store.allPeerDevices()) { error in
            guard case LocalStoreError.Closed = error else { return XCTFail("\(error)") }
        }
    }
}
