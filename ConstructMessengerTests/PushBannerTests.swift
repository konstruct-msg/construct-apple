//
//  PushBannerTests.swift
//  ConstructMessengerTests
//
//  The message push is an alert since 2026-10-05: the server names keys from this app's strings,
//  and a wake the system grants leaves that banner standing and posts none of our own. Each test names the mutation
//  that reddens it.
//

import XCTest
@testable import Construct_Messenger

final class PushBannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func delivered(
        _ id: String,
        secondsAgo: TimeInterval = 5,
        fromPush: Bool = true,
        activity: String? = "new_message"
    ) -> PushBannerReplacement.Delivered {
        .init(identifier: id, date: now.addingTimeInterval(-secondsAgo), fromPush: fromPush, activity: activity)
    }

    /// Mutation: return [] — every woken message shows the push banner and ours after it.
    func testThisWakesPushBannerIsRecognised() {
        let covering = PushBannerReplacement.coveringPushBanners(
            among: [delivered("push-1")], activity: "new_message", now: now
        )
        XCTAssertEqual(covering, ["push-1"])
    }

    /// Mutation: drop the `fromPush` term — our own banner for another chat counts as the push's, and the new message gets no banner.
    func testOurOwnBannersNeverCount() {
        let covering = PushBannerReplacement.coveringPushBanners(
            among: [delivered("msg-chat-A", fromPush: false)], activity: "new_message", now: now
        )
        XCTAssertTrue(covering.isEmpty)
    }

    /// Mutation: drop the window — an unread banner from an hour ago swallows the new message's
    /// banner, which then never appears.
    func testAnOlderPushBannerDoesNotCoverANewMessage() {
        let covering = PushBannerReplacement.coveringPushBanners(
            among: [delivered("push-old", secondsAgo: 3600)], activity: "new_message", now: now
        )
        XCTAssertTrue(covering.isEmpty)
    }

    /// A contact-request banner does not cover a message push, nor the reverse.
    func testOnlyTheSameKindCovers() {
        let covering = PushBannerReplacement.coveringPushBanners(
            among: [delivered("push-msg"), delivered("push-cr", activity: "contact_request_received")],
            activity: "contact_request_received",
            now: now
        )
        XCTAssertEqual(covering, ["push-cr"])
    }

    // MARK: - Taking a banner back (TODO 123)

    /// A push for a delivery receipt woke a fetch that found nothing new: its banner goes.
    /// Mutation: return [] — "New message" stays, and opening it shows nothing (2026-10-06).
    func testABannerWithNothingNewIsWithdrawn() {
        let ids = PushBannerReplacement.bannersToWithdraw(
            among: [delivered("push-receipt"), delivered("push-older", secondsAgo: 3600)],
            somethingNew: false, deliveredBefore: now
        )
        XCTAssertEqual(ids, ["push-receipt", "push-older"])
    }

    /// Something new keeps every banner: a blind banner names no chat, and it may be that
    /// message's only sign. Mutation: drop the `somethingNew` guard.
    func testSomethingNewKeepsTheBanners() {
        XCTAssertTrue(PushBannerReplacement.bannersToWithdraw(
            among: [delivered("push-msg")], somethingNew: true, deliveredBefore: now
        ).isEmpty)
    }

    /// A banner that landed after the fetch began may be for a message that fetch did not see.
    /// Mutation: drop the date term.
    func testABannerFromAfterTheFetchBeganStays() {
        let ids = PushBannerReplacement.bannersToWithdraw(
            among: [delivered("push-before", secondsAgo: 10), delivered("push-after", secondsAgo: 1)],
            somethingNew: false, deliveredBefore: now.addingTimeInterval(-5)
        )
        XCTAssertEqual(ids, ["push-before"])
    }

    /// Only push banners for messages: our own banners and other kinds stay.
    /// Mutation: drop the `fromPush` or the activity term.
    func testOnlyMessagePushBannersAreWithdrawn() {
        let ids = PushBannerReplacement.bannersToWithdraw(
            among: [
                delivered("msg-chat-A", fromPush: false),
                delivered("push-cr", activity: "contact_request_received"),
                delivered("push-msg")
            ],
            somethingNew: false, deliveredBefore: now
        )
        XCTAssertEqual(ids, ["push-msg"])
    }

    // MARK: - What is new (TODO 123, 2026-10-17)

    /// The usual state — one chat left unread days ago — is not new. Until 2026-10-17 any unread
    /// chat kept every banner, so a receipt's banner was almost never taken back.
    /// Mutation: compare against 0 instead of the seen count.
    func testUnreadThePersonAlreadySawIsNotNew() {
        XCTAssertFalse(UnreadSeen.somethingNew(seen: ["A": 3], now: ["A": 3, "B": 0]))
    }

    /// Mutation: `>=` for `>` reddens the test above and the one below.
    func testUnreadThatGrewIsNew() {
        XCTAssertTrue(UnreadSeen.somethingNew(seen: ["A": 3], now: ["A": 4]))
        XCTAssertTrue(UnreadSeen.somethingNew(seen: ["A": 3], now: ["A": 3, "B": 1]), "a chat with no record")
    }

    /// No record yet (first launch): every unread is new, which keeps every banner.
    func testWithoutARecordAnyUnreadIsNew() {
        XCTAssertTrue(UnreadSeen.somethingNew(seen: nil, now: ["A": 1]))
        XCTAssertFalse(UnreadSeen.somethingNew(seen: nil, now: ["A": 0]))
    }

    func testTheRecordRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UnreadSeenTests"))
        defer { defaults.removePersistentDomain(forName: "UnreadSeenTests") }
        UnreadSeen.record(["A": 2, "B": 0], in: defaults)
        XCTAssertEqual(UnreadSeen.load(from: defaults), ["A": 2])
    }

    /// The server (`messaging-service` `blind_alert`) puts these keys in the alert, and iOS looks
    /// them up in this app's `Localizable.strings`. A key renamed or missing in one locale shows
    /// its raw name on that locale's lock screen, and nothing else would notice.
    ///
    /// Mutation: rename `construct_new_message` in any one locale.
    func testTheKeysTheServerNamesExistInEveryLocale() throws {
        let keys = ["construct_app_name", "construct_new_message", "contact_request_received_body"]
        let app = Bundle(for: AuthViewModel.self)
        for locale in ["en", "ru", "ja", "fr", "hy-AM"] {
            let path = try XCTUnwrap(app.path(forResource: locale, ofType: "lproj"), locale)
            let bundle = try XCTUnwrap(Bundle(path: path), locale)
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{0}missing", table: nil)
                XCTAssertNotEqual(value, "\u{0}missing", "\(locale): \(key)")
                XCTAssertFalse(value.isEmpty, "\(locale): \(key)")
            }
        }
    }
}
