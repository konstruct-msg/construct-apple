//
//  KeyValueStoreTests.swift
//  ConstructMessengerTests
//
//  What any `KeyValueStore` must do — `UserDefaults` here; the `LocalStore` implementation runs the
//  same tests by overriding `makeStore()` (the crate's `kv`) — and that the fan-out retry queue
//  keeps its state there, which is the path the macOS switch takes.
//

import XCTest
@testable import Construct_Messenger

class KeyValueStoreTests: XCTestCase {

    private var suites: [String] = []

    func makeStore() -> any KeyValueStore {
        let name = "kv-\(UUID().uuidString)"
        suites.append(name)
        return DefaultsKeyValueStore(defaults: UserDefaults(suiteName: name)!)
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suites = []
        LocalRepositories.useKeyValueForTesting(nil)
        super.tearDown()
    }

    func testAValueIsPutReadAndRemoved() throws {
        let store = makeStore()
        XCTAssertNil(try store.get("k"))
        try store.put("k", Data([1, 2]))
        XCTAssertEqual(try store.get("k"), Data([1, 2]))
        try store.put("k", Data([3]))
        XCTAssertEqual(try store.get("k"), Data([3]), "a second put replaces")
        try store.remove("k")
        XCTAssertNil(try store.get("k"))
    }

    func testAPrefixListsOnlyItsOwnKeysInOrder() throws {
        let store = makeStore()
        try store.put("family.b", Data([2]))
        try store.put("family.a", Data([1]))
        try store.put("other", Data([9]))
        let listed = try store.entries(withPrefix: "family.")
        XCTAssertEqual(listed.map(\.key), ["family.a", "family.b"])
        XCTAssertEqual(listed.map(\.value), [Data([1]), Data([2])])
    }

    /// The app's queue keeps its state in the seam's store, not in `UserDefaults` directly — so the
    /// macOS switch moves it into the encrypted store with everything else.
    ///
    /// Mutation: keep the shared queue on `UserDefaults.standard` — this reddens.
    func testTheFanoutQueueKeepsItsStateInTheSeam() throws {
        let store = makeStore()
        LocalRepositories.useKeyValueForTesting(store)

        let queue = FanoutRetryQueue()
        queue.enqueue(baseMessageId: "message-1", recipientUserId: "account-1", senderUserId: "me", owed: ["device-1"])

        XCTAssertNotNil(try store.get("construct.fanoutRetryQueue.v1"))
        XCTAssertEqual(queue.all().map(\.owedDeviceIds), [["device-1"]])
        queue.remove(key: "message-1|account-1")
        XCTAssertNil(try store.get("construct.fanoutRetryQueue.v1"), "an emptied queue leaves nothing behind")
    }
}

/// The same cases on the crate's table.
final class LocalStoreKeyValueStoreTests: KeyValueStoreTests {
    override func makeStore() -> any KeyValueStore {
        LocalStoreKeyValueStore(session: .inMemoryForTesting())
    }
}
