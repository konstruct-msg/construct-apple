//
//  ServerMessageIdStoreTests.swift
//  ConstructMessengerTests
//
//  What any `ServerMessageIdStore` must do, and that `ServerMessageIdMap` answers across a
//  restart. The crate states the same rules in `construct-core/store/tests/store_test.rs`.
//

import CoreData
import XCTest
@testable import Construct_Messenger

final class ServerMessageIdStoreTests: XCTestCase {

    private var container: NSPersistentContainer!

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
        LocalRepositories.useServerMessageIdsForTesting(nil)
        container = nil
        super.tearDown()
    }

    func testAServerIdMapsBackInAnyCaseAndARecordAgainIsACorrection() throws {
        let store = CoreDataServerMessageIdStore(container: container)
        try store.record(serverId: "E474825E-AAAA", localId: "8B403CE9-BBBB", at: Date())
        XCTAssertEqual(try store.localId(forServerId: "e474825e-aaaa"), "8b403ce9-bbbb")

        try store.record(serverId: "e474825e-aaaa", localId: "other", at: Date())
        XCTAssertEqual(try store.localId(forServerId: "E474825E-AAAA"), "other")
        XCTAssertNil(try store.localId(forServerId: "unknown"))
    }

    func testOnlyIdsOlderThanTheCutoffAreForgotten() throws {
        let store = CoreDataServerMessageIdStore(container: container)
        try store.record(serverId: "old", localId: "a", at: Date(timeIntervalSince1970: 100))
        try store.record(serverId: "new", localId: "b", at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try store.forget(recordedBefore: Date(timeIntervalSince1970: 150)), 1)
        XCTAssertNil(try store.localId(forServerId: "old"))
        XCTAssertEqual(try store.localId(forServerId: "new"), "b")
    }

    /// The defect: the map was a dictionary, and a peer's DECRYPTION_ERROR arrives when the peer
    /// is next online — usually after we restarted. `ServerMessageIdMap.shared` lives as long as
    /// this test process, so the next process is modelled by the store alone: what the map writes
    /// must be in the store, and what the store holds must be what the map answers.
    ///
    /// Mutation: keep the map in memory again — both halves redden.
    func testTheMapWritesThroughAndReadsWhatAnEarlierProcessWrote() throws {
        LocalRepositories.useServerMessageIdsForTesting(CoreDataServerMessageIdStore(container: container))

        ServerMessageIdMap.shared.record(serverId: "SEALED-COPY-1", localId: "our-message-1")
        let nextProcess = CoreDataServerMessageIdStore(container: container)
        XCTAssertEqual(try nextProcess.localId(forServerId: "sealed-copy-1"), "our-message-1")

        try nextProcess.record(serverId: "written-before-launch", localId: "our-message-0", at: Date())
        XCTAssertEqual(ServerMessageIdMap.shared.localId(for: "WRITTEN-BEFORE-LAUNCH"), "our-message-0")
        XCTAssertEqual(ServerMessageIdMap.shared.localId(for: "never-sent"), "never-sent", "identity when unknown")
    }
}
