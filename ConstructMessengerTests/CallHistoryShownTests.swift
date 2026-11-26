import CoreData
import XCTest
@testable import Construct_Messenger

/// A contact's card lists their calls only; the whole log is Desktop's Calls window.
final class CallHistoryShownTests: XCTestCase {
    private var store: CoreDataCallStore!

    override func setUp() {
        super.setUp()
        store = CoreDataCallStore(container: PersistenceController(inMemory: true).container)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func call(_ id: String, _ peer: String, at seconds: TimeInterval) -> CallRecord {
        CallRecord(id: id, peerUserId: peer, peerName: peer, direction: .incoming, status: .completed,
                   startedAt: Date(timeIntervalSince1970: seconds), endedAt: nil, durationSeconds: 1)
    }

    func testACardListsOnlyItsPersonsCallsNewestFirst() throws {
        try store.upsert(call("a1", "anna", at: 100))
        try store.upsert(call("m1", "mark", at: 200))
        try store.upsert(call("a2", "anna", at: 300))
        XCTAssertEqual(try CallHistoryView.shown(store, peer: "anna").map(\.id), ["a2", "a1"])
        XCTAssertEqual(try CallHistoryView.shown(store, peer: nil).map(\.id), ["a2", "m1", "a1"])
        XCTAssertEqual(try CallHistoryView.shown(store, peer: "kate"), [])
    }
}
