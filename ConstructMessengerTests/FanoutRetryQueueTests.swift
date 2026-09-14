import XCTest
@testable import Construct_Messenger

/// §C: a fan-out that fails is recoverable, not merely silent.
///
/// Until 2026-08-31 every way out of the fan-out logged at `info` and returned. The measured shape
/// (2026-08-28): a second device linked at 11:14, the one bundle fetch after it timed out at
/// 11:18, and the copy was never sent — the sender's UI said "sent" because the primary send had
/// succeeded, and the only party who could notice was the device that heard nothing.
///
/// These cover the queue itself, which is where the decisions live: what an empty owed set means,
/// what a repeated failure does to an existing entry, and when the queue stops trying. The
/// send path around it needs a network and belongs to the two-simulator stand.
final class FanoutRetryQueueTests: XCTestCase {

    private var defaults: UserDefaults!
    private var queue: FanoutRetryQueue!
    private let suiteName = "construct.tests.fanoutRetryQueue"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        queue = FanoutRetryQueue(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        queue = nil
        defaults = nil
        super.tearDown()
    }

    private func enqueue(_ id: String = "msg-1", peer: String = "peer-1", owed: [String] = []) {
        queue.enqueue(baseMessageId: id, recipientUserId: peer, senderUserId: "me", owed: owed)
    }

    // MARK: - What gets stored

    /// The 2026-08-28 shape: the fetch failed, so nothing names the devices. An empty owed set is
    /// "re-plan from scratch", and it is correct precisely because nothing was sent.
    func testAFailedFetchQueuesAReplan() {
        enqueue(owed: [])
        let entry = queue.all().first
        XCTAssertEqual(entry?.baseMessageId, "msg-1")
        XCTAssertEqual(entry?.owedDeviceIds, [])
        XCTAssertEqual(entry?.attempts, 0)
    }

    /// A named set is the other situation entirely — the plan succeeded and some sends threw. The
    /// retry must touch only those: a device that already has its copy would take a second
    /// ciphertext of one message through one ratchet and render it twice.
    func testANamedSetIsKeptAsGiven() {
        enqueue(owed: ["dev-b", "dev-a"])
        XCTAssertEqual(queue.all().first?.owedDeviceIds, ["dev-a", "dev-b"])
    }

    /// An empty id names nobody. It is what an unresolved translation produces, and storing it
    /// would give the drain an entry it can never satisfy.
    func testEmptyIdentifiersAreNotQueued() {
        queue.enqueue(baseMessageId: "", recipientUserId: "peer-1", senderUserId: "me", owed: [])
        queue.enqueue(baseMessageId: "msg-1", recipientUserId: "", senderUserId: "me", owed: [])
        XCTAssertTrue(queue.all().isEmpty)
    }

    // MARK: - Repeated failures

    /// Two chunks of one message fail independently; the second enqueue must not erase what the
    /// first recorded.
    func testASecondFailureUnionsTheOwedSet() {
        enqueue(owed: ["dev-a"])
        enqueue(owed: ["dev-b"])
        XCTAssertEqual(queue.all().first?.owedDeviceIds, ["dev-a", "dev-b"])
        XCTAssertEqual(queue.all().count, 1, "one message to one peer is one entry")
    }

    /// **The asymmetry, stated.** A named set is more precise than a re-plan, so a later empty
    /// owed set must not widen it back — that would re-send to devices that already have the
    /// message. Asserted in the direction that can regress: the reverse (empty then named) is
    /// covered by the union above.
    func testAReplanDoesNotWidenANamedSet() {
        enqueue(owed: ["dev-a"])
        enqueue(owed: [])
        XCTAssertEqual(queue.all().first?.owedDeviceIds, ["dev-a"])
    }

    /// A message cannot extend its own TTL by failing again — otherwise an entry that fails on
    /// every reconnect would live forever, which is the shape the attempt cap exists to stop.
    func testRepeatedFailureDoesNotRefreshTheCreationTime() {
        enqueue(owed: ["dev-a"])
        let first = queue.all().first?.createdAt
        enqueue(owed: ["dev-b"])
        XCTAssertEqual(queue.all().first?.createdAt, first)
    }

    /// **The bug this test was written for.** A re-plan entry whose retry reaches one device and
    /// loses another must come out of the pass naming only the one it lost. `enqueue` unions, so
    /// using it here would leave the set empty — still a re-plan — and the next drain would send
    /// the device that already has the message a second ciphertext of it.
    func testARetryNarrowsAReplanToWhatItActuallyLost() {
        enqueue(owed: [])
        queue.replaceOwed(key: "msg-1|peer-1", owed: ["dev-b"])
        XCTAssertEqual(queue.all().first?.owedDeviceIds, ["dev-b"])
    }

    /// Narrowing shrinks a named set too — a two-device retry that recovers one of them leaves one
    /// owed, not two.
    func testNarrowingShrinksANamedSet() {
        enqueue(owed: ["dev-a", "dev-b"])
        queue.replaceOwed(key: "msg-1|peer-1", owed: ["dev-b"])
        XCTAssertEqual(queue.all().first?.owedDeviceIds, ["dev-b"])
    }

    /// Narrowing an entry that is gone creates nothing. The drain can be holding a key the TTL
    /// dropped underneath it, and resurrecting it would give the queue an entry with no attempts
    /// spent — immortal by construction.
    func testNarrowingAnAbsentEntryCreatesNothing() {
        queue.replaceOwed(key: "msg-1|peer-1", owed: ["dev-b"])
        XCTAssertTrue(queue.all().isEmpty)
    }

    // MARK: - Attempts and backoff

    /// The backoff grows, so a peer that is down does not get hammered on every reconnect.
    func testBackoffGrowsWithEachAttempt() {
        enqueue()
        let first = queue.recordAttempt(key: "msg-1|peer-1")
        let second = queue.recordAttempt(key: "msg-1|peer-1")
        XCTAssertEqual(first?.attempts, 1)
        XCTAssertEqual(second?.attempts, 2)
        XCTAssertGreaterThan(second!.nextAttemptAt, first!.nextAttemptAt)
    }

    /// Exhaustion returns `nil` **and** removes the entry, so the caller counts a give-up exactly
    /// once. If it only returned nil the entry would sit in the queue reporting itself as due on
    /// every drain, and the give-up counter would climb without bound.
    func testExhaustionRemovesTheEntryAndReportsItOnce() {
        enqueue()
        for _ in 0..<(queue.maxAttempts - 1) {
            XCTAssertNotNil(queue.recordAttempt(key: "msg-1|peer-1"))
        }
        XCTAssertNil(queue.recordAttempt(key: "msg-1|peer-1"), "the last attempt exhausts it")
        XCTAssertTrue(queue.all().isEmpty)
        XCTAssertNil(queue.recordAttempt(key: "msg-1|peer-1"), "and it is gone, not counted twice")
    }

    /// An unknown key is not an error and must not create an entry — the drain calls this with
    /// whatever it picked up, and a removed message would otherwise resurrect itself.
    func testAnUnknownKeyCreatesNothing() {
        XCTAssertNil(queue.recordAttempt(key: "nope|nobody"))
        XCTAssertTrue(queue.all().isEmpty)
    }

    // MARK: - Reading

    /// A fresh entry waits out its first backoff. Without this the drain that queued it would pick
    /// it straight back up in the same pass.
    func testAFreshEntryIsNotImmediatelyDue() {
        enqueue()
        XCTAssertTrue(queue.due().isEmpty)
        XCTAssertFalse(queue.due(now: Date().addingTimeInterval(120)).isEmpty)
    }

    /// Oldest first, so a backlog drains in the order the messages were sent rather than in
    /// whatever order the encoder happened to write them.
    func testDueEntriesComeOldestFirst() {
        enqueue("msg-1", peer: "peer-1")
        enqueue("msg-2", peer: "peer-2")
        let due = queue.due(now: Date().addingTimeInterval(120))
        XCTAssertEqual(due.map(\.baseMessageId), ["msg-1", "msg-2"])
    }

    /// The TTL is enforced on read, so a queue nobody drains cannot grow without bound. A copy
    /// owed for more than a day is not worth delivering: the device has healed by other means and
    /// the message would arrive out of order into an old transcript.
    func testExpiredEntriesAreDroppedOnRead() {
        enqueue()
        let wellPastTtl = Date().addingTimeInterval(25 * 60 * 60)
        XCTAssertTrue(queue.due(now: wellPastTtl).isEmpty)
        XCTAssertTrue(queue.all().isEmpty, "and dropped, not merely filtered out of this answer")
    }

    /// Delivery clears the entry. Without this the queue would keep re-sending a message that has
    /// already arrived — worse than the gap it was built to close.
    func testRemoveClearsTheEntry() {
        enqueue(owed: ["dev-a"])
        queue.remove(key: "msg-1|peer-1")
        XCTAssertTrue(queue.all().isEmpty)
    }

    /// Two messages to the same peer are two entries; one message to two peers likewise. The key
    /// is the pair, because a copy is owed by a message *to an account*.
    func testTheKeyIsTheMessageAndThePeerTogether() {
        enqueue("msg-1", peer: "peer-1")
        enqueue("msg-1", peer: "peer-2")
        enqueue("msg-2", peer: "peer-1")
        XCTAssertEqual(queue.all().count, 3)
    }

    /// Entries survive a new instance over the same store — the whole point is that a reconnect
    /// after a relaunch still owes the copy.
    func testEntriesSurviveARelaunch() {
        enqueue(owed: ["dev-a"])
        let reopened = FanoutRetryQueue(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reopened.all().first?.owedDeviceIds, ["dev-a"])
    }
}
