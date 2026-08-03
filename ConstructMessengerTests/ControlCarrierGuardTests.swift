//
//  ControlCarrierGuardTests.swift
//  ConstructMessengerTests
//
//  `isControl` on `CfeIncomingEvent.messageReceived` is hardcoded `false` in both builders, and it
//  is correct there — but only because END_SESSION and SESSION_RESET_INIT early-exit before those
//  builders are reached. That precondition was assumed, never checked.
//
//  It is worth checking because the flag does not mean what its name suggests. In the core
//  `is_control` means *archive the session now*: it skips ACK dedup and wire-payload unpacking and
//  calls `archive_session`. Deriving it from the content type — which was the obvious-looking fix
//  — would set it for SENDER_SYNC and SRI too and tear down healthy sessions on every sync. So the
//  right move was a guard on the precondition, not a smarter derivation, and these tests pin the
//  guard's boundary: exactly the two types that must never arrive here, and nothing else.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ControlCarrierGuardTests: XCTestCase {

    private func message(contentType: UInt8) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString, from: "peer", to: "me",
            ephemeralPublicKey: Data(), messageNumber: 1, content: Data(),
            suiteId: 1, timestamp: 1_000_000, contentType: contentType
        )
    }

    /// A fresh router each time — the guard reads nothing but its argument, and a shared instance
    /// is how a suite starts passing for reasons unrelated to what it asserts.
    private func guardFires(contentType: UInt8) -> Bool {
        let before = PerformanceMetrics.shared.count(event: .controlCarrierReachedWirePath)
        MessageRouter().assertNotControlCarrier(message(contentType: contentType), path: "test")
        return PerformanceMetrics.shared.count(event: .controlCarrierReachedWirePath) > before
    }

    /// The two carriers that must never reach the wire path. END_SESSION has no wire payload at
    /// all, and an SRI that is decrypted instead of archived leaves the old session alive.
    func testGuardFiresForEndSessionAndResetInit() {
        XCTAssertTrue(guardFires(contentType: 21), "END_SESSION must be reported if it gets here")
        XCTAssertTrue(guardFires(contentType: 24), "SESSION_RESET_INIT must be reported if it gets here")
    }

    /// Everything else is an ordinary carrier and must pass silently — including the control
    /// *kinds* that legitimately travel as wire payloads. A guard that fired on these would be the
    /// content-type derivation this design deliberately rejected, arriving through the back door.
    func testGuardStaysSilentForOrdinaryCarriers() {
        for contentType: UInt8 in [0, 1, 12, 13, 14, 23, 25, 26] {
            XCTAssertFalse(guardFires(contentType: contentType),
                           "ct=\(contentType) is a normal carrier here and must not be reported")
        }
    }

    /// SENDER_SYNC is called out on its own because it is the one that would have been broken by
    /// the rejected fix: it is a control kind, it does travel as a wire payload, and archiving the
    /// session on it would destroy a healthy session on every multi-device sync.
    func testSenderSyncIsNotTreatedAsControl() {
        XCTAssertFalse(guardFires(contentType: 23))
        XCTAssertTrue(message(contentType: 23).isSenderSync,
                      "…and it really is the sender-sync type, so the exemption is deliberate")
    }
}
