//
//  CallStoreTests.swift
//  ConstructMessengerTests
//
//  What any `CallStore` must do — Core Data here; the `LocalStore` implementation runs the same
//  tests by overriding `makeStore()` (the crate's `calls`, whose own tests pin the same rules) —
//  and that the call log's writers and the history import go through it.
//

import CoreData
import XCTest
@testable import Construct_Messenger

class CallStoreTests: XCTestCase {

    private var container: NSPersistentContainer!

    func makeStore() -> any CallStore {
        CoreDataCallStore(container: container)
    }

    override func setUp() {
        super.setUp()
        container = PersistenceController(inMemory: true).container
    }

    override func tearDown() {
        LocalRepositories.useCallsForTesting(nil)
        container = nil
        super.tearDown()
    }

    private func call(_ id: String, at seconds: TimeInterval?, _ status: CallRecord.Status = .completed) -> CallRecord {
        CallRecord(
            id: id, peerUserId: "peer", peerName: "Bob", direction: .incoming, status: status,
            startedAt: seconds.map(Date.init(timeIntervalSince1970:)),
            endedAt: seconds.map { Date(timeIntervalSince1970: $0 + 60) }, durationSeconds: 60
        )
    }

    /// An incoming call logged as missed and then answered is one entry, answered.
    ///
    /// Mutation: always insert — the count reddens.
    func testACallRecordedAgainIsOneEntryInItsLastState() throws {
        let store = makeStore()
        try store.upsert(call("c1", at: 100, .missed))
        try store.upsert(call("c1", at: 100, .completed))
        XCTAssertEqual(try store.calls(limit: 10), [call("c1", at: 100, .completed)])
    }

    /// Newest first, a call with no start time last, no more than asked for — the crate's order.
    func testTheLogIsNewestFirstWithAnUndatedCallLast() throws {
        let store = makeStore()
        try store.upsert(call("old", at: 100))
        try store.upsert(call("undated", at: nil, .failed))
        try store.upsert(call("new", at: 300))
        XCTAssertEqual(try store.calls(limit: 10).map(\.id), ["new", "old", "undated"])
        XCTAssertEqual(try store.calls(limit: 2).map(\.id), ["new", "old"])
    }

    func testACallIsDeletedByIdAndSaysWhetherItWasThere() throws {
        let store = makeStore()
        try store.upsert(call("keep", at: 100))
        try store.upsert(call("drop", at: 200))
        XCTAssertTrue(try store.delete("drop"))
        XCTAssertFalse(try store.delete("drop"))
        XCTAssertEqual(try store.calls(limit: 10).map(\.id), ["keep"])
    }

    /// The recents screen reads again on a change; a write and a delete each name their row.
    func testAWriteAndADeleteAreToldByTheirIds() async throws {
        let store = makeStore()
        var changes = store.changes().makeAsyncIterator()
        try store.upsert(call("c1", at: 100))
        let written = await changes.next()
        XCTAssertEqual(written, ["c1"])
        try store.delete("c1")
        let deleted = await changes.next()
        XCTAssertEqual(deleted, ["c1"])
    }

    /// "Clear history": every entry in one write, told once with every id — and an empty log
    /// clears to nothing and tells nothing (the next change heard is the next write).
    ///
    /// Mutations: delete one row per save — the change splits and this reddens; return 0 — the
    /// count reddens; save an empty log anyway — harmless, `RowChangeFeed` sends no empty set.
    func testTheLogIsClearedInOneWriteAndToldOnce() async throws {
        let store = makeStore()
        try store.upsert(call("a", at: 100))
        try store.upsert(call("b", at: nil))
        var changes = store.changes().makeAsyncIterator()

        XCTAssertEqual(try store.deleteAll(), 2)
        XCTAssertEqual(try store.calls(limit: 10), [])
        let cleared = await changes.next()
        XCTAssertEqual(cleared, ["a", "b"])

        XCTAssertEqual(try store.deleteAll(), 0, "nothing left to clear")
        try store.upsert(call("c", at: 300))
        let next = await changes.next()
        XCTAssertEqual(next, ["c"], "clearing an empty log is not a change")
    }

    /// The log a call writes when it ends is the seam's store — the path the macOS switch takes.
    ///
    /// Mutation: the service writes somewhere else — this reddens.
    @MainActor
    func testTheEndOfACallIsLoggedInTheSeam() throws {
        LocalRepositories.useCallsForTesting(makeStore())
        let session = CallSession(id: "call-x", uuid: UUID(), peerUserId: "peer", peerName: "Bob", direction: .outgoing)
        CallHistoryService.shared.record(
            session: session, status: .completed, startedAt: Date(timeIntervalSince1970: 100), durationSeconds: 42
        )
        let logged = try XCTUnwrap(makeStore().calls(limit: 10).first)
        XCTAssertEqual(logged.id, "call-x")
        XCTAssertEqual(logged.direction, .outgoing)
        XCTAssertEqual(logged.durationSeconds, 42)

        CallHistoryService.shared.deleteAll()
        XCTAssertEqual(try makeStore().calls(limit: 10), [])
    }

    /// A call already in the log stays as it is when a history transfer brings it again.
    ///
    /// Mutation: skip the "already logged" check — the status is overwritten and this reddens.
    func testAnImportedCallAlreadyLoggedKeepsTheEntryHere() throws {
        let store = makeStore()
        try store.upsert(call("c1", at: 100, .completed))
        let proto = historyExportCall(call: LocalCall(
            id: "c1", peerUserId: "11111111-2222-4333-8444-555555555555", peerName: "",
            direction: 1, status: CallRecord.Status.missed.rawValue,
            startedAt: 100_000, endedAt: nil, durationSeconds: 0
        ))
        let importer = HistorySnapshotImporter(
            expectedUserId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", calls: store
        )
        let summary = try importer.importRecords([.transcript(type: HistoryRecordType.call, proto: proto)])

        XCTAssertEqual(summary.conflictKeepExisting, 1)
        XCTAssertEqual(try store.calls(limit: 10).map(\.status), [.completed])
    }
}

/// The same cases on the crate. One store per test: `makeStore()` is asked more than once.
final class LocalStoreCallStoreTests: CallStoreTests {
    private var session: LocalStoreSession!

    override func setUp() {
        super.setUp()
        session = .inMemoryForTesting()
    }

    override func tearDown() {
        session = nil
        super.tearDown()
    }

    override func makeStore() -> any CallStore {
        LocalStoreCallStore(session: session)
    }
}
