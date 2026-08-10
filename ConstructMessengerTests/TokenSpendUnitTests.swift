//
//  TokenSpendUnitTests.swift
//  ConstructMessengerTests
//
//  2026-08-04, device log: sending a three-photo album emptied the Privacy Pass wallet.
//
//      Stealth: sealed send WITH token (wallet=1 left)
//      Stealth: sealed send WITHOUT token — wallet empty (anti-abuse degraded, anonymity intact)
//      BlindToken: issuer back-off active — skipping
//
//  The album was ~30 wire envelopes and each one attached its own token, so one tap spent the
//  entire hourly allowance a young account is given (30/hr) and the rest of the album went out
//  unpaid. Under enforce those are rejected sends. The anti-abuse budget was being charged per
//  packet for something the user did once.
//
//  Fixed on the server first (construct-server 2a64177): the first envelope carrying a token and
//  a `token_spend_id` redeems for the whole set, later envelopes with the same id are accepted as
//  `unit_covered`. This is the client half — and the part of it worth testing is not the id, it
//  is *who pays*, because the obvious answer (chunk 0) is wrong.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class TokenSpendUnitTests: XCTestCase {

    /// Replays what the send loop does per envelope, through the same decision production uses.
    /// Returns how many tokens were spent across the whole message.
    private func tokensSpent(
        envelopes: Int,
        unit: TokenSpendUnit?,
        policyWantsToken: Bool = true,
        attachSucceeds: (Int) -> Bool = { _ in true }
    ) -> Int {
        var spent = 0
        for index in 0..<envelopes {
            let unitPaid = unit.map { !$0.shouldAttemptPayment } ?? false
            guard TokenSpendUnit.shouldAttemptPayment(policyWantsToken: policyWantsToken, unitPaid: unitPaid)
            else { continue }
            if attachSucceeds(index) {
                spent += 1
                unit?.markPaid()
            }
        }
        return spent
    }

    // MARK: - The incident

    func testAThirtyEnvelopeAlbumSpendsOneToken() {
        let unit = TokenSpendUnit.forEnvelopeCount(30)
        XCTAssertNotNil(unit)
        XCTAssertEqual(tokensSpent(envelopes: 30, unit: unit), 1, "the album cost 30 tokens — a young account's whole hour")
    }

    func testAFailedFirstAttachDoesNotCondemnTheWholeAlbum() {
        // An empty wallet or an uncached server key on chunk 0 has nothing to do with the other
        // 29. If the payer role belonged to whoever was *first* rather than whoever *succeeds*,
        // one unlucky moment would leave all 30 envelopes uncovered and the album rejected.
        let unit = TokenSpendUnit.forEnvelopeCount(30)
        let spent = tokensSpent(envelopes: 30, unit: unit, attachSucceeds: { $0 > 0 })
        XCTAssertEqual(spent, 1, "the unit must still get paid for, just by a later envelope")
        XCTAssertEqual(unit?.isPaid, true)
    }

    func testAWalletEmptyForEveryEnvelopeIsNoWorseThanBefore() {
        // Degrading to the old per-envelope behaviour is acceptable; going silent is not. Every
        // envelope must keep trying, or a wallet that refills mid-album never gets used.
        let unit = TokenSpendUnit.forEnvelopeCount(30)
        let attempts = tokensSpent(envelopes: 30, unit: unit, attachSucceeds: { _ in false })
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(unit?.isPaid, false, "nothing was attached, so nothing may be marked paid")
    }

    func testEveryEnvelopeOfAMessageCarriesTheSameSpendId() {
        let unit = TokenSpendUnit()
        let ids = (0..<30).map { _ in unit.spendId }
        XCTAssertEqual(Set(ids).count, 1, "a differing id per envelope is 30 separate units again")
    }

    func testSpendIdsAreThirtyTwoBytesAndDistinctPerMessage() {
        // The proto contract is 32 bytes; the server keys Redis on sha256(id), so a repeat across
        // two messages would let the second ride on the first message's redemption for free.
        let ids = (0..<64).map { _ in TokenSpendUnit().spendId }
        for id in ids { XCTAssertEqual(id.count, 32) }
        XCTAssertEqual(Set(ids).count, ids.count, "spend ids collided")
    }

    // MARK: - What must NOT happen

    func testASingleEnvelopeMessageGetsNoUnitAtAll() {
        // Every ordinary text goes through this path. An empty spend id is what tells the server
        // to redeem per envelope exactly as it always has — the legacy behaviour must survive the
        // optimisation aimed at albums.
        XCTAssertNil(TokenSpendUnit.forEnvelopeCount(1))
        XCTAssertNil(TokenSpendUnit.forEnvelopeCount(0))
        XCTAssertEqual(tokensSpent(envelopes: 1, unit: nil), 1, "an un-chunked send still pays for itself")
    }

    func testStealthDisabledStillSpendsNothing() {
        // The unit must not become a reason to spend a token where policy said not to.
        let unit = TokenSpendUnit.forEnvelopeCount(30)
        XCTAssertEqual(tokensSpent(envelopes: 30, unit: unit, policyWantsToken: false), 0)
    }

    func testAPrivacyPassRejectionMakesTheRebuildPayAgain() {
        // StealthSendRecovery's one-shot: the server rejected the envelope we thought had paid,
        // so its redemption record does not exist. Re-attaching the same unpaid spend id would be
        // rejected identically and turn a recoverable rejection into a permanent one.
        let unit = TokenSpendUnit()
        unit.markPaid()
        XCTAssertFalse(unit.shouldAttemptPayment)

        unit.invalidatePayment()

        XCTAssertTrue(unit.shouldAttemptPayment, "the rebuild would have ridden on a spend that never happened")
        XCTAssertEqual(unit.spendId.count, 32, "and it must be the same unit, not a new one")
    }

    func testRecoveryKeepsTheSameSpendIdSoAlreadySentEnvelopesStayCovered() {
        // Chunks 0…k may already be on the server carrying this id. A rebuild that minted a fresh
        // id would strand them: they would be covered by a unit nobody ever pays for.
        let unit = TokenSpendUnit()
        let idBefore = unit.spendId
        unit.markPaid()
        unit.invalidatePayment()
        XCTAssertEqual(unit.spendId, idBefore)
    }

    // MARK: - The pure decision

    func testShouldAttemptPaymentTruthTable() {
        XCTAssertTrue(TokenSpendUnit.shouldAttemptPayment(policyWantsToken: true, unitPaid: false))
        XCTAssertFalse(TokenSpendUnit.shouldAttemptPayment(policyWantsToken: true, unitPaid: true))
        XCTAssertFalse(TokenSpendUnit.shouldAttemptPayment(policyWantsToken: false, unitPaid: false))
        XCTAssertFalse(TokenSpendUnit.shouldAttemptPayment(policyWantsToken: false, unitPaid: true))
    }
}
