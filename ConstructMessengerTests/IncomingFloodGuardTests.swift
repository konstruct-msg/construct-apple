import XCTest
@testable import Construct_Messenger

/// The flood guard counts a burst by when the server queued each message, and a suppression lasts
/// while the flood does (2026-10-15). Before, a mailbox drained at launch — the Desktop back after
/// a day — read as ten messages a second from every busy chat, and each of those people was muted
/// on that device for good.
final class IncomingFloodGuardTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suite = "flood-guard-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Mutation: count by arrival (`now`) instead of the server's time — this reddens.
    func testABacklogDrainedAtLaunchIsNotAFlood() {
        let guardian = IncomingFloodGuard(defaults: defaults)
        let queued = now.addingTimeInterval(-2 * 3600)
        for i in 0..<40 {
            let result = guardian.check(senderId: "alice", queuedAt: queued.addingTimeInterval(Double(i)), now: now)
            guard case .normal = result else { return XCTFail("message \(i) of a backlog counted as a flood: \(result)") }
        }
        XCTAssertFalse(guardian.isSuppressed("alice", now: now))
    }

    /// Mutation: raise or drop the threshold check — this reddens.
    func testALiveBurstIsStillCaught() {
        let guardian = IncomingFloodGuard(defaults: defaults)
        for i in 0..<(guardian.burstThreshold - 1) {
            guard case .normal = guardian.check(senderId: "mallory", queuedAt: now, now: now.addingTimeInterval(Double(i) * 0.1)) else {
                return XCTFail("message \(i) is under the threshold")
            }
        }
        guard case .burstDetected = guardian.check(senderId: "mallory", queuedAt: now, now: now.addingTimeInterval(1)) else {
            return XCTFail("the threshold message is a burst")
        }
        guard case .alreadySuppressed = guardian.check(senderId: "mallory", queuedAt: now, now: now.addingTimeInterval(1.1)) else {
            return XCTFail("the next one is suppressed")
        }
    }

    /// Mutation: drop `lapse` — this reddens.
    func testASuppressionLapsesWhenTheFloodGoesQuiet() {
        let guardian = burst()
        XCTAssertTrue(guardian.isSuppressed("mallory", now: now.addingTimeInterval(guardian.quietPeriod - 1)))
        XCTAssertFalse(guardian.isSuppressed("mallory", now: now.addingTimeInterval(guardian.quietPeriod + 1)))
    }

    /// Mutation: stop extending on a live message — this reddens.
    func testAFloodThatGoesOnStaysSuppressed() {
        let guardian = burst()
        let later = now.addingTimeInterval(guardian.quietPeriod - 10)
        _ = guardian.check(senderId: "mallory", queuedAt: later, now: later)
        XCTAssertTrue(guardian.isSuppressed("mallory", now: now.addingTimeInterval(guardian.quietPeriod + 60)))
    }

    /// Suppressions persisted before 2026-10-15 were false alarms from launch backlogs as often as
    /// not, and nothing lifted them. Mutation: keep the stored set — this reddens.
    func testSuppressionsStoredBeforeAreCleared() {
        defaults.set(["alice", "bob"], forKey: IncomingFloodGuard.legacySuppressedKey)
        let guardian = IncomingFloodGuard(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: IncomingFloodGuard.legacySuppressedKey))
        XCTAssertFalse(guardian.isSuppressed("alice", now: now))
    }

    /// The time comes from the server's key, never from a local one (the sender's clock).
    /// Mutation: accept a three-part key — this reddens.
    func testOnlyAServerKeyNamesAServerTime() throws {
        let server = try XCTUnwrap(ServerMessageOrder.key(serverTimestampMilliseconds: 1_800_000_000_123, sequence: 4))
        XCTAssertEqual(try XCTUnwrap(ServerMessageOrder.serverDate(ofKey: server)).timeIntervalSince1970, 1_800_000_000.123, accuracy: 0.001)
        XCTAssertNil(ServerMessageOrder.serverDate(ofKey: ServerMessageOrder.local(timestamp: now, messageId: "m1")))
        XCTAssertNil(ServerMessageOrder.serverDate(ofKey: ServerMessageOrder.pending(localMessageId: "m2", composedAt: Date(timeIntervalSince1970: 0))))
    }

    private func burst() -> IncomingFloodGuard {
        let guardian = IncomingFloodGuard(defaults: defaults)
        for _ in 0..<guardian.burstThreshold { _ = guardian.check(senderId: "mallory", queuedAt: now, now: now) }
        XCTAssertTrue(guardian.isSuppressed("mallory", now: now))
        return guardian
    }
}
