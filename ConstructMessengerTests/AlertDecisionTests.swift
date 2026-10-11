//
//  AlertDecisionTests.swift
//  ConstructMessengerTests
//
//  The notification extension's one rule, as a table: an alert is dropped only when every
//  delivery the push could be about is a protocol frame, and every doubt shows it
//  (decisions/notification-extension-reads-only.md). `AlertDecision.swift` is compiled into the
//  app as well so it can be tested here.
//

import XCTest
@testable import Construct_Messenger

final class AlertDecisionTests: XCTestCase {

    private func decide(_ fetch: PendingFetchOutcome, _ verdicts: [PeekVerdict]) -> AlertDecision {
        AlertDecision.decide(fetch: fetch, verdicts: verdicts)
    }

    private let complete = PendingFetchOutcome.fetched(hasMore: false, unsealed: 0)

    /// Receipts alone — the case the extension exists for.
    func testOnlyProtocolFramesHideTheAlert() {
        XCTAssertEqual(decide(complete, [.control]), .hide(controlFrames: 1))
        XCTAssertEqual(decide(complete, [.control, .alreadyHandled, .control]), .hide(controlFrames: 2))
    }

    /// One message among the frames is enough to show it.
    func testAMessageShowsTheAlert() {
        XCTAssertEqual(decide(complete, [.control, .visible]), .show(reason: "a message"))
        XCTAssertEqual(decide(complete, [.visible, .control]), .show(reason: "a message"))
    }

    /// What the peek could not read may be a message.
    func testAnUnreadableDeliveryShowsTheAlert() {
        XCTAssertEqual(decide(complete, [.control, .unreadable]), .show(reason: "unreadable"))
    }

    /// Nothing new: the app took it first, or the push raced the fetch. The banner may be the
    /// only notice of a message — shown.
    func testNothingNewShowsTheAlert() {
        XCTAssertEqual(decide(complete, []), .show(reason: "nothing new"))
        XCTAssertEqual(decide(complete, [.alreadyHandled]), .show(reason: "nothing new"))
    }

    /// What the fetch could not see decides for it, whatever the peeks said of the rest.
    func testAnIncompleteFetchShowsTheAlert() {
        XCTAssertEqual(decide(.failed, []), .show(reason: "fetch failed"))
        XCTAssertEqual(decide(.fetched(hasMore: true, unsealed: 0), [.control]), .show(reason: "more waiting than one page"))
        XCTAssertEqual(decide(.fetched(hasMore: false, unsealed: 1), [.control]), .show(reason: "1 not sealed"))
    }

    // MARK: - ServerEndpoint

    func testTheEndpointRoundTrips() {
        let endpoint = ServerEndpoint(host: "ams.konstruct.cc", port: 443)
        XCTAssertEqual(ServerEndpoint(endpoint.stored), endpoint)
        XCTAssertEqual(ServerEndpoint("[::1]:8443"), ServerEndpoint(host: "[::1]", port: 8443))
    }

    /// Anything not `host:port` is no endpoint: the extension shows the alert rather than guess.
    func testAMalformedEndpointIsRejected() {
        for stored in ["ams.konstruct.cc", ":443", "ams.konstruct.cc:", "ams.konstruct.cc:0", "ams.konstruct.cc:70000", "host:port"] {
            XCTAssertNil(ServerEndpoint(stored), stored)
        }
    }
}
