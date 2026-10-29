//
//  IncomingCallAlertTests.swift
//  ConstructMessengerTests
//
//  The Mac's incoming-call notification: it rings for the call that is `.incoming`, and its
//  Answer and Decline act only on that call while it rings.
//

import UserNotifications
import XCTest
@testable import Construct_Messenger

final class IncomingCallAlertTests: XCTestCase {

    private func session(_ id: String) -> CallSession {
        CallSession(id: id, uuid: UUID(), peerUserId: "peer", peerName: "Peer", direction: .incoming)
    }

    func testOnlyAnIncomingCallRings() {
        let call = session("a")
        XCTAssertEqual(IncomingCallAlert.ringing(.incoming(call))?.id, "a")
        XCTAssertNil(IncomingCallAlert.ringing(.connecting(call)))
        XCTAssertNil(IncomingCallAlert.ringing(.active(call)))
        XCTAssertNil(IncomingCallAlert.ringing(.idle))
    }

    func testAnswerAndDeclineActOnTheCallThatRings() {
        XCTAssertEqual(IncomingCallAlert.response(action: IncomingCallAlert.answerAction,
                                                  notificationCallId: "a", ringingCallId: "a"), .answer)
        XCTAssertEqual(IncomingCallAlert.response(action: IncomingCallAlert.declineAction,
                                                  notificationCallId: "a", ringingCallId: "a"), .decline)
    }

    /// A banner left from an earlier call does not answer the one ringing now, nor anything once
    /// the call stopped ringing. Mutation: drop the call-id check — the stale banner answers "b";
    /// this reddens.
    func testABannerFromAnotherCallDoesNothing() {
        XCTAssertEqual(IncomingCallAlert.response(action: IncomingCallAlert.answerAction,
                                                  notificationCallId: "a", ringingCallId: "b"), .ignore)
        XCTAssertEqual(IncomingCallAlert.response(action: IncomingCallAlert.declineAction,
                                                  notificationCallId: "a", ringingCallId: nil), .ignore)
        XCTAssertEqual(IncomingCallAlert.response(action: IncomingCallAlert.answerAction,
                                                  notificationCallId: nil, ringingCallId: nil), .ignore)
    }

    func testAPlainClickBringsTheAppForward() {
        XCTAssertEqual(IncomingCallAlert.response(action: UNNotificationDefaultActionIdentifier,
                                                  notificationCallId: "a", ringingCallId: nil), .open)
    }
}
