//
//  PeerDeviceStoreTests.swift
//  ConstructMessengerTests
//
//  What any `PeerDeviceStore` must do. Written against the protocol, run against Core Data today;
//  the `LocalStore` implementation (LOCAL_STORE_MIGRATION_PLAN step 3) runs the same cases, which
//  is how the two are held to one behaviour rather than to two descriptions of it. The crate's own
//  statement of the same rules is `construct-core/store/tests/store_test.rs`.
//

import XCTest
@testable import Construct_Messenger

final class PeerDeviceStoreTests: XCTestCase {

    private func makeStore() -> any PeerDeviceStore {
        CoreDataPeerDeviceStore(container: PersistenceController(inMemory: true).container)
    }

    private func device(_ id: String, _ account: String, at seconds: TimeInterval = 1) -> PeerDeviceRecord {
        PeerDeviceRecord(
            deviceId: id, accountId: account,
            identityKey: Data(id.utf8), firstSeenAt: Date(timeIntervalSince1970: seconds)
        )
    }

    /// Mutation: drop the `deviceId` sort descriptor — the tie comes back in store order.
    func testAnAccountsDevicesComeOldestFirstAndTiesBreakById() throws {
        let store = makeStore()
        _ = try store.record([device("c", "alice", at: 5), device("zz-first", "alice", at: 1)])
        _ = try store.record([device("b", "alice", at: 5), device("a", "bob", at: 9)])

        XCTAssertEqual(try store.devices(ofAccount: "alice").map(\.deviceId), ["zz-first", "b", "c"])
        XCTAssertEqual(try store.allDevices().map(\.deviceId), ["zz-first", "b", "c", "a"])
        XCTAssertEqual(try store.devices(ofAccount: "nobody"), [])
    }

    /// A server naming a second account for a recorded device is not believed.
    func testARecordedDeviceKeepsItsFirstAccount() throws {
        let store = makeStore()
        XCTAssertEqual(try store.record([device("d1", "alice")]), ["d1"])
        XCTAssertEqual(try store.record([device("d1", "mallory"), device("d2", "alice")]), ["d2"])

        XCTAssertEqual(try store.device("d1")?.accountId, "alice")
        XCTAssertEqual(try store.devices(ofAccount: "mallory"), [])
        XCTAssertNil(try store.device("none"))
    }

    func testRecordingTheSameIdTwiceInOneCallAddsItOnce() throws {
        let store = makeStore()
        XCTAssertEqual(try store.record([device("d1", "alice"), device("d1", "alice")]), ["d1"])
        XCTAssertEqual(try store.allDevices().count, 1)
    }

    /// Mutation: remove the empty-set guard — an old server's missing list forgets every device.
    func testRetainForgetsOnlyOutsideTheListAndAnEmptyListForgetsNothing() throws {
        let store = makeStore()
        _ = try store.record([device("d1", "alice"), device("d2", "alice"), device("x", "bob")])

        XCTAssertEqual(try store.retain(ofAccount: "alice", keeping: []), [])
        XCTAssertEqual(try store.devices(ofAccount: "alice").count, 2)

        XCTAssertEqual(try store.retain(ofAccount: "alice", keeping: ["d2"]), ["d1"])
        XCTAssertEqual(try store.devices(ofAccount: "alice").map(\.deviceId), ["d2"])
        XCTAssertEqual(try store.devices(ofAccount: "bob").map(\.deviceId), ["x"], "another account is untouched")
    }

    /// The reason the store owns its context: `viewContext` read off the main thread returned
    /// nothing, which reads as "no devices".
    func testAnswersOffTheMainThread() async throws {
        let store = makeStore()
        _ = try store.record([device("d1", "alice")])
        let off = try await Task.detached { try store.devices(ofAccount: "alice").map(\.deviceId) }.value
        XCTAssertEqual(off, ["d1"])
    }
}
