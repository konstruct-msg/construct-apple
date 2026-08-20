//
//  InviteRevocationTests.swift
//  ConstructMessengerTests
//
//  Created 2026-08-16.
//

import XCTest
@testable import Construct_Messenger

/// Revoking an invite, and the one thing that must never happen.
///
/// `RevokeInvite` answers three ways: it burned the `jti`, it refused because the `jti` was
/// already burned, or it did not answer at all. The first two mean the capability cannot be
/// redeemed. The third means nothing is known — and telling the user it was revoked is worse
/// than showing them an error, because an error makes them look again while a false
/// "revoked" makes them stop.
final class InviteRevocationTests: XCTestCase {

    private let ttl = InviteConfig.ttlSeconds

    private func act(_ kind: InviteIssuance.Kind, jtis: [String], age: TimeInterval = 60) -> InviteIssuance {
        let at = Date().addingTimeInterval(-age)
        return InviteIssuance(kind: kind, mints: jtis.map { InviteIssuance.Mint(jti: $0, at: at) })
    }

    // MARK: - What may be revoked

    func testACopiedLinkCanBeRevoked() {
        XCTAssertTrue(InviteRevocationDecision.canRevoke(kind: .link))
    }

    /// Not a capability question — a QR sitting is as revocable as a link, one `jti` at a
    /// time. It is a cost question: at the current TTL a sitting holds up to
    /// `ttlSeconds / qrRotateIntervalSeconds` codes, so the button would mean that many
    /// requests. Spec §4 (a short TTL for QR) is what unblocks it.
    func testAQRSittingOffersNoRevokeUntilItsTTLShrinks() {
        XCTAssertFalse(InviteRevocationDecision.canRevoke(kind: .qrSession))

        let codesInAFullSitting = InviteConfig.ttlSeconds / InviteConfig.qrRotateIntervalSeconds
        XCTAssertGreaterThan(
            codesInAFullSitting, 100,
            "if this drops to a handful the button becomes reasonable — revisit canRevoke"
        )
    }

    // MARK: - What leaves the list

    func testAConfirmedBurnDropsTheRow() {
        XCTAssertTrue(InviteRevocationDecision.removesFromJournal(.revoked))
    }

    /// "Already used" is an answer, not a failure: someone redeemed the link, so it is not
    /// outstanding and has no business staying in a list of what is.
    func testAnAlreadyRedeemedInviteAlsoDropsTheRow() {
        XCTAssertTrue(InviteRevocationDecision.removesFromJournal(.alreadyUsed))
    }

    /// The regression this file exists for. Dropping the row here states, in the only place
    /// the user can check, that a capability which may still work is gone.
    func testAnUnconfirmedAttemptMustLeaveTheRowAlone() {
        XCTAssertFalse(InviteRevocationDecision.removesFromJournal(.unconfirmed))
    }

    // MARK: - Combining an act's capabilities

    func testAllBurnedIsRevoked() {
        XCTAssertEqual(InviteRevocationDecision.combine([.revoked, .revoked]), .revoked)
    }

    func testAllAlreadyUsedStaysAlreadyUsed() {
        XCTAssertEqual(InviteRevocationDecision.combine([.alreadyUsed, .alreadyUsed]), .alreadyUsed)
    }

    /// A mixture of "burned now" and "was already burned" is still an act nobody can
    /// redeem, so it counts as revoked.
    func testAMixOfBurnedAndSpentIsStillDead() {
        XCTAssertEqual(InviteRevocationDecision.combine([.revoked, .alreadyUsed]), .revoked)
    }

    /// One unanswered burn poisons the verdict. An act is dead only when every one of its
    /// codes is known dead — the same rule as the single case, at act scale.
    func testOneUnconfirmedBurnPoisonsTheWholeAct() {
        XCTAssertEqual(
            InviteRevocationDecision.combine([.revoked, .revoked, .unconfirmed]), .unconfirmed
        )
        XCTAssertEqual(
            InviteRevocationDecision.combine([.alreadyUsed, .unconfirmed]), .unconfirmed
        )
    }

    /// Asking nothing confirms nothing. An empty act reaching this point is a bug upstream,
    /// and answering `.revoked` would drop a row on the strength of no evidence at all —
    /// the zero-out-of-zero reading this codebase keeps paying for.
    func testNoCapabilitiesAskedIsNotSuccess() {
        XCTAssertEqual(InviteRevocationDecision.combine([]), .unconfirmed)
        XCTAssertFalse(
            InviteRevocationDecision.removesFromJournal(InviteRevocationDecision.combine([]))
        )
    }

    // MARK: - What the act hands the revoker

    /// Expired capabilities are not sent to the server: burning them changes nothing, and a
    /// long act would spend most of its requests on codes that died hours ago.
    func testOnlyLiveCapabilitiesAreWorthBurning() {
        let now = Date()
        let mixed = InviteIssuance(kind: .qrSession, mints: [
            InviteIssuance.Mint(jti: "dead", at: now.addingTimeInterval(-ttl - 60)),
            InviteIssuance.Mint(jti: "live", at: now.addingTimeInterval(-60)),
        ])
        XCTAssertEqual(mixed.liveMints(at: now).map(\.jti), ["live"])
    }

    /// A copied link is one capability by construction, so its revoke button is one request.
    /// If this ever fails, the loop in `InviteRevocation.revoke` is doing more than the UI
    /// promises.
    @MainActor
    func testACopiedLinkIsAlwaysASingleCapability() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let journal = InviteJournal(defaults: defaults)

        journal.recordCopiedLink(jti: "one")
        journal.recordCopiedLink(jti: "two")

        XCTAssertEqual(journal.live().map { $0.mints.count }, [1, 1])
    }

    // MARK: - Journal wiring

    @MainActor
    func testForgettingAnActRemovesItAndSurvivesReload() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let journal = InviteJournal(defaults: defaults)
        journal.recordCopiedLink(jti: "revoked-one")
        journal.recordCopiedLink(jti: "kept")
        guard let target = journal.live().first(where: { $0.mints.first?.jti == "revoked-one" }) else {
            return XCTFail("journal did not record the link")
        }

        journal.forget(actID: target.id)

        XCTAssertEqual(journal.live().map { $0.mints.first?.jti }, ["kept"])
        XCTAssertEqual(
            InviteJournal(defaults: defaults).live().map { $0.mints.first?.jti }, ["kept"],
            "a forgotten act must not come back on the next launch"
        )
    }

    /// Forgetting the sitting currently on screen must end it: the next rotation starts a
    /// new act instead of joining something that is no longer in the list.
    ///
    /// A link is recorded first on purpose. Without it the journal is empty after the
    /// forget, every possible lookup returns nil, and the test passes no matter what the
    /// code does — the first version of this test was exactly that, and a mutation proved
    /// it could not fail.
    @MainActor
    func testForgettingTheOpenSittingEndsIt() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let journal = InviteJournal(defaults: defaults)
        journal.recordCopiedLink(jti: "unrelated-link")
        journal.recordQRCode(jti: "a1")
        guard let sitting = journal.live().first(where: { $0.kind == .qrSession }) else {
            return XCTFail("no sitting recorded")
        }

        journal.forget(actID: sitting.id)
        journal.recordQRCode(jti: "a2")

        let live = journal.live()
        XCTAssertEqual(live.count, 2, "the link, plus a fresh sitting for a2")
        XCTAssertEqual(
            live.first(where: { $0.kind == .link })?.mints.map(\.jti), ["unrelated-link"],
            "a2 must not have been folded into an unrelated act"
        )
        XCTAssertEqual(live.first(where: { $0.kind == .qrSession })?.mints.map(\.jti), ["a2"])
    }
}
