import XCTest
@testable import Construct_Messenger

/// Э3: an incoming message is tried against every device session we hold with the sender.
///
/// A peer's account is a set of devices and each has its own ratchet. The receive path resolved
/// exactly one — `SessionAddressing.contactId(forPeer:)` — and handed it every message the account
/// sent, so a message from the second device failed AEAD on keys that were entirely valid. That is
/// indistinguishable from a broken session and was treated as one: heal, and a teardown of the
/// healthy session behind it.
///
/// The order is the core's decision (`plan_receiving_decrypt`, nine tests in Rust). What is pinned
/// here is the Swift half: which verdicts are worth another device, and that the core's plan keeps
/// the single-device case at exactly one attempt.
@MainActor
final class ReceivingDecryptWalkTests: XCTestCase {

    // MARK: - Which verdicts justify another attempt

    /// The two failure verdicts describe the **session**, so another device is worth trying.
    func testAFailedSessionIsWorthAnotherDevice() {
        XCTAssertTrue(MessageRouter.worthAnotherDevice([
            .sessionHealNeeded(contactId: "dev-a", role: "responder")
        ]))
        XCTAssertTrue(MessageRouter.worthAnotherDevice([
            .sendEndSession(contactId: "dev-a")
        ]))
    }

    /// **The property that keeps the walk safe.** Every verdict other than the two above is an
    /// answer about the *message*, not the session. Re-asking a different session would repeat it,
    /// or act on it twice — a second END_SESSION, a second queue entry, a duplicate row.
    func testAnAnswerAboutTheMessageEndsTheWalk() {
        XCTAssertFalse(MessageRouter.worthAnotherDevice([
            .messageDecrypted(contactId: "dev-a", messageId: "m1", plaintext: Data())
        ]))
        XCTAssertFalse(MessageRouter.worthAnotherDevice([
            .messageQueuedPendingInit(contactId: "dev-a", queuedCount: 1)
        ]))
        XCTAssertFalse(MessageRouter.worthAnotherDevice([
            .endSessionSuppressed(contactId: "dev-a", retryAfterMs: 1000)
        ]))
        XCTAssertFalse(MessageRouter.worthAnotherDevice([
            .healSuppressed(contactId: "dev-a", retryAfterMs: 1000)
        ]))
        XCTAssertFalse(MessageRouter.worthAnotherDevice([
            .fetchPublicKeyBundle(userId: "acct")
        ]))
    }

    /// An empty list is `.none`, and `.none` is not a session failure. Walking on it would turn a
    /// verdict the core encodes as emptiness — a duplicate — into an attempt against every other
    /// device of the account.
    func testNoVerdictDoesNotWalk() {
        XCTAssertFalse(MessageRouter.worthAnotherDevice([]))
    }

    /// The verdict is read by name, not by position: a chore in front of the decision must not
    /// change the answer. This is the defect class `OrchestratorActionPlan` exists to prevent, and
    /// the walk is a new reader of that same list.
    func testAChoreInFrontDoesNotHideTheVerdict() {
        XCTAssertTrue(MessageRouter.worthAnotherDevice([
            .scheduleTimer(timerId: "t", delayMs: 10),
            .sessionHealNeeded(contactId: "dev-a", role: "responder")
        ]))
    }

    // MARK: - The plan, as the app sees it

    /// The single-device case is one attempt, against exactly the session the code used before
    /// there was a walk. This change must cost the overwhelming majority of accounts nothing.
    func testOneDeviceIsOneAttempt() {
        XCTAssertEqual(planReceivingDecrypt(sessionDeviceIds: ["a"], preferredDeviceId: "a"), ["a"])
        XCTAssertEqual(planReceivingDecrypt(sessionDeviceIds: ["a"], preferredDeviceId: ""), ["a"])
    }

    /// **The defect, stated as a test.** Two devices: both are tried. The implementation this
    /// replaces produced one.
    func testTwoDevicesAreBothPlanned() {
        XCTAssertEqual(
            planReceivingDecrypt(sessionDeviceIds: ["a", "b"], preferredDeviceId: ""),
            ["a", "b"]
        )
    }

    /// The device that last decrypted leads. A conversation is with one device at a time far more
    /// often than not, so this is the difference between one attempt per message and N.
    func testThePreferredDeviceLeads() {
        XCTAssertEqual(
            planReceivingDecrypt(sessionDeviceIds: ["a", "b", "c"], preferredDeviceId: "c"),
            ["c", "a", "b"]
        )
    }

    /// A stale preference — the device was revoked, or the hint outlived the session — reorders
    /// nothing and removes nothing. A hint must never be able to shrink the search.
    func testAStalePreferenceNeitherLeadsNorFilters() {
        XCTAssertEqual(
            planReceivingDecrypt(sessionDeviceIds: ["a", "b"], preferredDeviceId: "gone"),
            ["a", "b"]
        )
    }
}
