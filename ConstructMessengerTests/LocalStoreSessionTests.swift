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
