//
//  InviteJournalTests.swift
//  ConstructMessengerTests
//
//  Created 2026-08-15.
//

import XCTest
@testable import Construct_Messenger

/// The journal of invites this device issued.
///
/// Named after what it is built against: `ListInvites` answered OK with an empty list
/// forever, because the server never sees an invite before redeem or revoke. The record
/// has to live on the issuing device, and once it does, the danger moves — a QR sheet left
/// open mints 120 capabilities an hour, and a journal keyed on capabilities buries the two
/// links a person actually sent under a hundred codes nobody chose.
final class InviteJournalTests: XCTestCase {

    private let ttl = InviteConfig.ttlSeconds

    private func mint(_ jti: String, at: Date) -> InviteIssuance.Mint {
        InviteIssuance.Mint(jti: jti, at: at)
    }

    // MARK: - Placement: what belongs to which act

    /// Two taps of copy are two links for two people. Folding them into one act would
    /// restore exactly the ambiguity the copy button was changed to remove.
    func testEachCopiedLinkIsItsOwnAct() {
        XCTAssertEqual(
            InviteJournalDecision.placement(kind: .link, hasOpenQRSession: false),
            .startNewAct
        )
        XCTAssertEqual(
            InviteJournalDecision.placement(kind: .link, hasOpenQRSession: true),
            .startNewAct,
            "a link copied while the QR sheet is open is still its own act"
        )
    }

    /// The reason this type exists. Without it a 30-minute sitting with the QR on screen
    /// writes 60 rows.
    func testQRRotationsJoinTheOpenSittingInsteadOfMakingRows() {
        XCTAssertEqual(
            InviteJournalDecision.placement(kind: .qrSession, hasOpenQRSession: true),
            .appendToOpenSession
        )
    }

    /// A rotation arriving with no sheet open starts a fresh act rather than reviving a
    /// finished one — otherwise a code minted days later lands under a timestamp the user
    /// no longer recognises.
    func testAQRCodeWithNoOpenSittingStartsANewAct() {
        XCTAssertEqual(
            InviteJournalDecision.placement(kind: .qrSession, hasOpenQRSession: false),
            .startNewAct
        )
    }

    // MARK: - Liveness

    func testAnActIsLiveWhileAnyOfItsCodesIs() {
        let now = Date()
        let act = InviteIssuance(kind: .qrSession, mints: [
            mint("expired", at: now.addingTimeInterval(-ttl - 60)),
            mint("live",    at: now.addingTimeInterval(-60)),
        ])
        XCTAssertTrue(act.isLive(at: now))
        XCTAssertEqual(act.liveMints(at: now).map(\.jti), ["live"])
    }

    func testAnActWhoseLastCodeOutlivedTheTTLIsGone() {
        let now = Date()
        let act = InviteIssuance(kind: .link, mints: [mint("old", at: now.addingTimeInterval(-ttl - 1))])
        XCTAssertFalse(act.isLive(at: now))
        XCTAssertNil(act.pruned(at: now))
    }

    /// Pruning happens at mint granularity, not act granularity. That is what bounds a long
    /// sitting: expired codes leave while the act stays, instead of the array growing for
    /// as long as the sheet is open.
    func testPruningDropsDeadCodesAndKeepsTheAct() {
        let now = Date()
        let act = InviteIssuance(kind: .qrSession, mints: [
            mint("a", at: now.addingTimeInterval(-ttl - 10)),
            mint("b", at: now.addingTimeInterval(-ttl - 5)),
            mint("c", at: now.addingTimeInterval(-30)),
        ])
        let pruned = act.pruned(at: now)
        XCTAssertEqual(pruned?.mints.map(\.jti), ["c"])
        XCTAssertEqual(pruned?.id, act.id, "pruning must not re-identify the act")
    }

    /// The act expires with its newest code, not its oldest — a sitting is still usable
    /// while the code currently on screen is.
    func testExpiryFollowsTheNewestCode() {
        let start = Date()
        let act = InviteIssuance(kind: .qrSession, mints: [
            mint("first", at: start),
            mint("last",  at: start.addingTimeInterval(600)),
        ])
        XCTAssertEqual(
            act.expiresAt().timeIntervalSince1970,
            start.addingTimeInterval(600 + ttl).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// But the act is *timestamped* by the code that opened it, because that is the moment
    /// the user remembers — the sheet they held up, not its last rotation.
    func testTheActIsStampedByItsFirstCode() {
        let start = Date()
        let act = InviteIssuance(kind: .qrSession, mints: [
            mint("first", at: start),
            mint("last",  at: start.addingTimeInterval(600)),
        ])
        XCTAssertEqual(act.startedAt, start)
    }

    // MARK: - Listing

    func testLiveListDropsExpiredActsAndOrdersNewestFirst() {
        let now = Date()
        let old     = InviteIssuance(kind: .link, mints: [mint("old",     at: now.addingTimeInterval(-7200))])
        let recent  = InviteIssuance(kind: .link, mints: [mint("recent",  at: now.addingTimeInterval(-60))])
        let expired = InviteIssuance(kind: .link, mints: [mint("expired", at: now.addingTimeInterval(-ttl - 1))])

        let live = InviteJournalDecision.live([old, expired, recent], at: now)

        XCTAssertEqual(live.map(\.id), [recent.id, old.id])
    }

    /// A sitting sorts by when it started, not by its last rotation. Sorting by the latter
    /// would float a QR sheet opened an hour ago above a link copied since, which is not
    /// the order the person performed them in.
    func testASittingSortsByWhenItOpened() {
        let now = Date()
        let sitting = InviteIssuance(kind: .qrSession, mints: [
            mint("qr-first", at: now.addingTimeInterval(-3600)),
            mint("qr-last",  at: now.addingTimeInterval(-30)),
        ])
        let link = InviteIssuance(kind: .link, mints: [mint("link", at: now.addingTimeInterval(-1800))])

        let live = InviteJournalDecision.live([sitting, link], at: now)

        XCTAssertEqual(live.map(\.id), [link.id, sitting.id])
    }

    func testAnEmptyJournalListsNothing() {
        XCTAssertTrue(InviteJournalDecision.live([], at: Date()).isEmpty)
    }

    // MARK: - Store wiring
    //
    // The decisions above are reachable without the store; these run through it, because a
    // pure function nothing calls is the failure this repo keeps rediscovering.

    @MainActor
    private func makeJournal(_ name: String = UUID().uuidString) -> (InviteJournal, UserDefaults) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (InviteJournal(defaults: defaults), defaults)
    }

    @MainActor
    func testTwoCopiedLinksBecomeTwoRows() {
        let (journal, _) = makeJournal()
        journal.recordCopiedLink(jti: "one")
        journal.recordCopiedLink(jti: "two")
        XCTAssertEqual(journal.live().count, 2)
    }

    @MainActor
    func testAWholeQRSittingIsOneRow() {
        let (journal, _) = makeJournal()
        for i in 0..<40 { journal.recordQRCode(jti: "rotation-\(i)") }

        let live = journal.live()
        XCTAssertEqual(live.count, 1, "40 rotations of one sheet are one act")
        XCTAssertEqual(live.first?.mints.count, 40, "but all 40 capabilities are kept, to revoke")
    }

    /// Closing the sheet ends the sitting. The next code opens a new one.
    @MainActor
    func testANewSheetIsANewSitting() {
        let (journal, _) = makeJournal()
        journal.recordQRCode(jti: "a1")
        journal.recordQRCode(jti: "a2")
        journal.closeQRSession()
        journal.recordQRCode(jti: "b1")

        XCTAssertEqual(journal.live().count, 2)
    }

    @MainActor
    func testJournalSurvivesReload() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let first = InviteJournal(defaults: defaults)
        first.recordCopiedLink(jti: "persisted")

        let reopened = InviteJournal(defaults: defaults)
        XCTAssertEqual(reopened.live().first?.mints.first?.jti, "persisted")
    }

    /// The window closes on its own. A journal that kept everything would be a history of
    /// who you invited and when, which is more than the feature needs to do its job.
    @MainActor
    func testEntriesOlderThanTheTTLDoNotComeBackOnReload() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let stale = InviteIssuance(
            kind: .link,
            mints: [InviteIssuance.Mint(jti: "stale", at: Date().addingTimeInterval(-ttl - 60))]
        )
        defaults.set(try! JSONEncoder().encode([stale]), forKey: "invite_journal_v1")

        XCTAssertTrue(InviteJournal(defaults: defaults).live().isEmpty)
    }
}
