//
//  PreKeyTrackingStoreTests.swift
//  ConstructMessengerTests
//
//  An SPK belongs to a device. The store used to hold one per account, and the responder walk —
//  one call per candidate device of a multi-device peer — flipped that slot between siblings on
//  every pass, each flip reading as "reinstall detected" and archiving the pinned device's
//  session. These pin the shape that cannot do that.
//

import XCTest
@testable import Construct_Messenger

final class PreKeyTrackingStoreTests: XCTestCase {

    private final class Memory: PreKeyTrackingPersistence {
        var blob: Data?
        var saves = 0
        func loadTracked() -> Data? { blob }
        func saveTracked(_ data: Data) -> Bool { blob = data; saves += 1; return true }
    }

    private let deviceA = String(repeating: "a", count: 32)
    private let deviceB = String(repeating: "b", count: 32)
    private let account = "d184760b-548a-471c-931c-2fb18a0ebd72"

    private func store(_ memory: Memory = Memory()) -> (PreKeyTrackingStore, Memory) {
        (PreKeyTrackingStore(storageKey: "test-\(UUID().uuidString)", persistence: memory), memory)
    }

    /// The 2026-08-30 / 2026-09-21 walk: A's bundle, then B's, then A's again. Keyed by account
    /// the third call reported a change; keyed by device it is the same SPK it saw before.
    func testTwoDevicesOfOnePeerAreTrackedIndependently() {
        let (store, _) = store()
        XCTAssertEqual(store.track(preKeyId: "spk-A", forDevice: deviceA), .firstSeen)
        XCTAssertEqual(store.track(preKeyId: "spk-B", forDevice: deviceB), .firstSeen, "the sibling's SPK is not a change of A's")
        XCTAssertEqual(store.track(preKeyId: "spk-A", forDevice: deviceA), .unchanged)
        XCTAssertEqual(store.track(preKeyId: "spk-B", forDevice: deviceB), .unchanged)
        XCTAssertEqual(Set(store.trackedDeviceIds), [deviceA, deviceB])
    }

    func testAChangedSPKIsReportedForThatDeviceOnly() {
        let (store, _) = store()
        _ = store.track(preKeyId: "spk-A", forDevice: deviceA)
        _ = store.track(preKeyId: "spk-B", forDevice: deviceB)
        XCTAssertEqual(store.track(preKeyId: "spk-A2", forDevice: deviceA), .changed(previous: "spk-A"))
        XCTAssertEqual(store.track(preKeyId: "spk-B", forDevice: deviceB), .unchanged, "A rotating says nothing about B")
    }

    /// An account id is refused, not stored: storing it would be the old slot under a new name.
    func testAnAccountKeyedObservationIsRefused() {
        let (store, memory) = store()
        XCTAssertEqual(store.track(preKeyId: "spk", forDevice: account), .refused)
        XCTAssertEqual(store.track(preKeyId: "spk", forDevice: ""), .refused)
        XCTAssertTrue(store.trackedDeviceIds.isEmpty)
        XCTAssertEqual(memory.saves, 0)
    }

    /// The Keychain item written before the change holds account-keyed entries. They are
    /// dropped on load — the account slot held whichever device was seen last, which is neither
    /// device's history — and the device-keyed ones are kept.
    func testAccountKeyedEntriesFromTheOldStoreAreDroppedOnLoad() throws {
        let memory = Memory()
        memory.blob = try JSONEncoder().encode([account: "spk-old", deviceA: "spk-A"])
        let (store, _) = store(memory)
        XCTAssertEqual(store.trackedDeviceIds, [deviceA])
        XCTAssertEqual(memory.saves, 1, "the cleaned dictionary is written back once")
        XCTAssertEqual(store.track(preKeyId: "spk-A", forDevice: deviceA), .unchanged)
        let persisted = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(memory.blob))
        XCTAssertNil(persisted[account])
    }

    func testPersistsAcrossInstances() throws {
        let memory = Memory()
        let key = "test-\(UUID().uuidString)"
        _ = PreKeyTrackingStore(storageKey: key, persistence: memory).track(preKeyId: "spk-A", forDevice: deviceA)
        let again = PreKeyTrackingStore(storageKey: key, persistence: memory)
        XCTAssertEqual(again.track(preKeyId: "spk-A2", forDevice: deviceA), .changed(previous: "spk-A"))
    }
}
