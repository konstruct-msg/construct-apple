//
//  TokenSpendUnitRetryTests.swift
//  ConstructMessengerTests
//
//  2026-09-11, two device logs: 71 sealed sends, 71 tokens, and the line that proves the unit
//  never engaged —
//
//      "Stealth: sealed send covered by unit … — no token spent"   → 0 occurrences
//
//  One message, `fbb24a8d`, cost six tokens: the original, two `MessageRetryManager` attempts of
//  the same body, and fan-out copies. `maxMessageRetryAttempts` is 3, so a message the network
//  dislikes costs four on the primary path alone — charged precisely while a bad connection is
//  also failing wallet replenishment.
//
//  The server has covered this since construct-server 2a64177: `pp:unit:{sha256(spend_id |
//  recipient)}` lives 2 h and every later envelope with that pair is `UnitCovered`. A retry nine
//  minutes later is just a later envelope. What was missing is a client that remembers the id
//  across the gap — and the two decisions worth pinning here are *how long* it may remember and
//  what a restored unit does, because both are silent when wrong: reusing a dead id costs a
//  rejected send under enforce, and restoring one unpaid costs the token it was meant to save.
//
import XCTest
@testable import Construct_Messenger

final class TokenSpendUnitRetentionTests: XCTestCase {

    private let window = TokenSpendUnitRetention.coverageWindow

    func testTheWindowStaysUnderTheServersTwoHours() {
        // The server sets EX 7200 when it opens the unit; we must stop reusing before that, not
        // after. Equal would already be wrong — the server's clock starts when it writes the key,
        // ours when we attached the token, and the gap is a network round trip we do not measure.
        XCTAssertLessThan(window, 2 * 60 * 60, "a window at or past the server's TTL reuses ids the server has dropped")
    }

    func testAUnitPaidMomentsAgoIsUsable() {
        XCTAssertTrue(TokenSpendUnitRetention.isUsable(paidAt: 1_000, now: 1_000))
        XCTAssertTrue(TokenSpendUnitRetention.isUsable(paidAt: 1_000, now: 1_000 + window - 1))
    }

    func testAUnitPastTheWindowIsNot() {
        XCTAssertFalse(TokenSpendUnitRetention.isUsable(paidAt: 1_000, now: 1_000 + window))
        XCTAssertFalse(TokenSpendUnitRetention.isUsable(paidAt: 1_000, now: 1_000 + window + 1))
    }

    func testAClockThatWentBackwardsIsNotTreatedAsFresh() {
        // `now < paidAt` means the elapsed time is unknown, not small. Reading the difference as a
        // small positive age is how a device whose clock resynced would reuse an id the server
        // expired an hour ago. Paying again is the only answer that cannot be wrong.
        XCTAssertFalse(TokenSpendUnitRetention.isUsable(paidAt: 5_000, now: 4_999))
        XCTAssertFalse(TokenSpendUnitRetention.isUsable(paidAt: 5_000, now: 0))
    }

    func testTheSweepDropsExpiredAndUndecodableButKeepsTheFresh() {
        let now: TimeInterval = 10_000
        let expired = TokenSpendUnitRetention.expiredKeys([
            (key: "fresh",       paidAt: now - 60),
            (key: "stale",       paidAt: now - window - 1),
            (key: "unreadable",  paidAt: nil),
        ], now: now)

        XCTAssertEqual(Set(expired), ["stale", "unreadable"])
        XCTAssertFalse(expired.contains("fresh"), "the sweep took a unit a retry could still have used")
    }

    func testAnEntryThatCannotBeDecodedIsAlwaysExpired() {
        // It has no readable `paidAt`, so it can never be used again. Keeping it would leave a
        // corrupt write in UserDefaults for the life of the install — the exact failure
        // `OutgoingWirePayloadStore.sweepExpired` was added to end for its own keyspace.
        XCTAssertEqual(
            TokenSpendUnitRetention.expiredKeys([(key: "k", paidAt: nil)], now: 0),
            ["k"]
        )
    }
}

@MainActor
final class TokenSpendUnitRestoreTests: XCTestCase {

    func testARestoredUnitKeepsTheIdAndDoesNotPayAgain() {
        let id = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let restored = TokenSpendUnit.restoredPaid(spendId: id)

        XCTAssertEqual(restored.spendId, id, "a retry that changes the id is not covered by anything")
        XCTAssertFalse(restored.shouldAttemptPayment, "the whole point is that the retry rides on the first send's redemption")
    }

    func testAThreeChunkRetryOnARestoredUnitSpendsNothing() {
        // The measured shape: a message re-sent chunk by chunk. Before this, each chunk of each
        // attempt built its own SealedInner and attached its own token.
        let unit = TokenSpendUnit.restoredPaid(spendId: Data(repeating: 7, count: 32))
        var spent = 0
        for _ in 0..<3 where TokenSpendUnit.shouldAttemptPayment(
            policyWantsToken: true, unitPaid: !unit.shouldAttemptPayment
        ) {
            spent += 1
            unit.markPaid()
        }
        XCTAssertEqual(spent, 0, "the retry bought tokens for a message that had already paid")
    }

    func testARejectedUnitPaysAgainRatherThanLooping() {
        // `StealthSendRecovery` calls `invalidatePayment()` when the server answers `privacy_pass:`
        // — its record of our spend is gone. The rebuilt envelope must buy a token; if the restored
        // unit stayed "paid" the rebuild would attach the same uncovered id and be rejected
        // identically, turning a one-shot recovery into a permanent failure.
        let unit = TokenSpendUnit.restoredPaid(spendId: Data(repeating: 3, count: 32))
        XCTAssertFalse(unit.shouldAttemptPayment)
        unit.invalidatePayment()
        XCTAssertTrue(unit.shouldAttemptPayment, "a rejected unit must be able to pay, or the recovery cannot recover")
    }

    func testForMessageAlwaysMintsAUnit() {
        // `forEnvelopeCount` returns nil below two envelopes, and that nil is why a two-device peer
        // paid twice and why a retry had no id to reuse: measured 2026-09-11, `covered by unit`
        // never appeared once in 71 spends. A one-envelope unit costs nothing — the server takes
        // the same `redeem_token` path for the first envelope whether or not a spend id is present.
        XCTAssertNil(TokenSpendUnit.forEnvelopeCount(1))
        let ids = (0..<64).map { _ in TokenSpendUnit.forMessage().spendId }
        for id in ids { XCTAssertEqual(id.count, 32) }
        XCTAssertEqual(Set(ids).count, ids.count, "spend ids collided — two messages would share one redemption")
    }
}
