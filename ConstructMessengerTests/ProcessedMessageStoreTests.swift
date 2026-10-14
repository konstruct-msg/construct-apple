//
//  ProcessedMessageStoreTests.swift
//  ConstructMessengerTests
//
//  What any `ProcessedMessageStore` must do, and that `PersistentACKStore` answers from it across a
//  restart. Core Data here; the `LocalStore` implementation runs the same tests by overriding
//  `makeStore()`. The crate states the same rules in `construct-core/store/tests/store_test.rs`
//  (`processed_messages`).
//

import XCTest
@testable import Construct_Messenger

class ProcessedMessageStoreTests: XCTestCase {

    func makeStore() -> any ProcessedMessageStore {
        CoreDataProcessedMessageStore(container: PersistenceController(inMemory: true).container)
    }

    override func tearDown() {
        LocalRepositories.useProcessedMessagesForTesting(nil)
        super.tearDown()
    }

    /// A second mark is not a second row and says it was not new.
    func testAMarkIsHeldOnceAndSaysWhetherItWasNew() throws {
        let store = makeStore()
        XCTAssertFalse(try store.isProcessed("envelope-1"))
        XCTAssertTrue(try store.markProcessed("envelope-1", senderId: "sender", at: Date()))
        XCTAssertFalse(try store.markProcessed("envelope-1", senderId: "sender", at: Date()))
        XCTAssertTrue(try store.isProcessed("envelope-1"))
    }

    /// Envelope ids are compared exactly, as received.
    func testIdsAreExact() throws {
        let store = makeStore()
        try store.markProcessed("Envelope-A", senderId: "sender", at: Date())
        XCTAssertTrue(try store.isProcessed("Envelope-A"))
        XCTAssertFalse(try store.isProcessed("envelope-a"))
    }

    func testOnlyMarksOlderThanTheCutoffAreForgotten() throws {
        let store = makeStore()
        try store.markProcessed("old", senderId: "s", at: Date(timeIntervalSince1970: 100))
        try store.markProcessed("new", senderId: "s", at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try store.forget(processedBefore: Date(timeIntervalSince1970: 150)), 1)
        XCTAssertFalse(try store.isProcessed("old"))
        XCTAssertTrue(try store.isProcessed("new"))
    }

    /// The next process is modelled by the store alone: a mark `PersistentACKStore` makes is in
    /// the store, and a mark the store holds — written by an earlier launch — is a duplicate to
    /// the durable question, without the in-memory cache having seen it.
    ///
    /// Mutation: write the mark only to the cache — the first half reddens.
    func testTheAckStoreWritesThroughAndReadsWhatAnEarlierProcessWrote() throws {
        let store = makeStore()
        LocalRepositories.useProcessedMessagesForTesting(store)
        let mine = "ack-\(UUID().uuidString)"
        let earlier = "ack-\(UUID().uuidString)"

        try PersistentACKStore.shared.markProcessedOrThrow(mine, senderId: "sender")
        XCTAssertTrue(try store.isProcessed(mine))

        try store.markProcessed(earlier, senderId: "sender", at: Date())
        XCTAssertTrue(PersistentACKStore.shared.isProcessedDurably(earlier))
        XCTAssertFalse(PersistentACKStore.shared.isProcessedDurably("ack-never-seen"))
    }
}

/// The same cases on the crate.
final class LocalStoreProcessedMessageStoreTests: ProcessedMessageStoreTests {
    override func makeStore() -> any ProcessedMessageStore {
        LocalStoreProcessedMessageStore(session: .inMemoryForTesting())
    }
}
