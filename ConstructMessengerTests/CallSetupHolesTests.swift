//
//  CallSetupHolesTests.swift
//  ConstructMessengerTests
//
//  Three holes from the 2026-08-22 two-device logs (build 631). Each decision is
//  extracted so a mutation in CallTypes reddens a named test; CallManager wiring
//  is not stood up here (see CallOfferOrderingTests "Not covered here").
//

import XCTest
@testable import Construct_Messenger

final class CallSetupHolesTests: XCTestCase {

    // MARK: - SDP behind a zombie stream (7CDE9769, 13:20)

    //  13:20:00  VoIP rings; offer already sent via E2EE
    //  13:20:02  Answered before the offer arrived
    //  13:20:15  QUIC timeout; silent push finally fetches; offer ignored (call ended)

    /// The skip that killed the call: MessageStream reported connected, so every silent
    /// push that could have pulled the offer was dropped. A call waiting on SDP must
    /// punch through that skip.
    ///
    /// Mutation: `return foregroundLiveStream` — restores the ignore.
    func testSilentPushIsNotIgnoredWhileACallWaitsForItsOffer() {
        XCTAssertFalse(
            shouldIgnoreSilentPush(foregroundLiveStream: true, callNeedsOffer: true),
            "the offer rides the message stream; a zombie 'connected' stream is why it was 15 s late"
        )
    }

    /// The skip must survive for ordinary chat. Without it every message's silent push
    /// reconnects the stream (the storm this guard was added for).
    ///
    /// Mutation: `return false` — every foreground push fetches again.
    func testSilentPushIsStillIgnoredWhenTheStreamIsLiveAndNoCallNeedsAnOffer() {
        XCTAssertTrue(shouldIgnoreSilentPush(foregroundLiveStream: true, callNeedsOffer: false))
    }

    /// A down stream never skips, with or without a call — that is the original wake path.
    func testADownStreamAlwaysFetches() {
        XCTAssertFalse(shouldIgnoreSilentPush(foregroundLiveStream: false, callNeedsOffer: false))
        XCTAssertFalse(shouldIgnoreSilentPush(foregroundLiveStream: false, callNeedsOffer: true))
    }

    /// VoIP/CallKit knows the call; the SDP has not arrived. Pull.
    ///
    /// Mutation: `return .skip` — VoIP rings into a 45 s wait for an offer already on the server.
    func testIncomingCallWithoutAnOfferPullsMissedMessages() {
        XCTAssertEqual(incomingCallFetchDisposition(hasUsableRemoteOffer: false), .pullMissed)
    }

    /// Offer already stored (the E2EE-first ordering). A fetch would only replay it.
    ///
    /// Mutation: `return .pullMissed` unconditionally — fetch storm on the path that already works.
    func testIncomingCallWithAnOfferDoesNotPull() {
        XCTAssertEqual(incomingCallFetchDisposition(hasUsableRemoteOffer: true), .skip)
    }

    // MARK: - Outgoing call with no Double Ratchet session (D858E6FE, 13:19)

    //  13:19:44  CallKit start
    //  13:19:45  SESSION_RESET_INIT archives the session
    //  13:19:52  Hangup → CALL_SIGNAL_ENCRYPT_FAILED: No session with contact

    /// No session means we cannot encrypt the offer. Wait; do not encrypt into a void.
    ///
    /// Mutation: `return .encryptNow` — sendOffer logs success while Rust returns notifyError.
    func testOutgoingCallWithoutASessionWaits() {
        XCTAssertEqual(outgoingCallSessionDisposition(hasSession: false), .waitThenInit)
    }

    /// A live session encrypts immediately. Waiting here would add seconds of dialing
    /// on the path that already works.
    func testOutgoingCallWithASessionEncryptsNow() {
        XCTAssertEqual(outgoingCallSessionDisposition(hasSession: true), .encryptNow)
    }

    /// `CALL_SIGNAL_ENCRYPT_FAILED` is the Rust code for "No session with contact".
    /// Dropping the signal is what left the callee ringing and the server marking us busy.
    ///
    /// Mutation: `return .drop` — hangup/offer vanish, occupancy stays.
    func testEncryptFailedBecauseThereIsNoSessionIsRetried() {
        XCTAssertEqual(
            callSignalEncryptDisposition(
                code: "CALL_SIGNAL_ENCRYPT_FAILED",
                message: "No session with contact: ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"
            ),
            .retryAfterSession
        )
    }

    /// Same Rust code also covers an oversized ICE batch. Retrying that loops the payload.
    ///
    /// Mutation: `return .retryAfterSession` on the code alone — ICE batches hammer the session.
    func testOversizedEncryptFailureIsNotAMissingSession() {
        XCTAssertEqual(
            callSignalEncryptDisposition(code: "CALL_SIGNAL_ENCRYPT_FAILED", message: "plaintext too large"),
            .drop
        )
    }

    /// Any other code is not this hole. Retrying those would loop a broken payload.
    func testOtherEncryptErrorsAreDropped() {
        XCTAssertEqual(callSignalEncryptDisposition(code: "CALL_SIGNAL_SEAL_FAILED", message: ""), .drop)
        XCTAssertEqual(callSignalEncryptDisposition(code: "", message: "No session with contact"), .drop)
    }

    // MARK: - Server occupancy after a received hangup (AC92380B, 11:38)

    //  11:38:14  callee Hangup sent (E2EE+stream)
    //  11:38:14  caller endActiveCall — no stream hangup
    //  11:38:18  callee InitiateCall → "Callee is busy"

    /// A hangup we receive over E2EE has not reached signaling-service. Write the stream
    /// so occupancy clears. Do not encrypt another E2EE hangup — the peer already sent it,
    /// and the session may be gone (D858E6FE).
    ///
    /// Mutation: `return [.e2ee, .signalingStream]` for remote — encrypt-fail on a dead session.
    func testAReceivedHangupNotifiesTheServerNotThePeer() {
        XCTAssertEqual(callHangupChannels(origin: .remote), [.signalingStream])
    }

    /// A hangup we originate still goes both ways: the peer needs E2EE (media path),
    /// the server needs the stream (occupancy).
    ///
    /// Mutation: `return [.signalingStream]` for local — peer stays in call until they hang up too.
    func testALocalHangupGoesToThePeerAndTheServer() {
        XCTAssertEqual(callHangupChannels(origin: .local), [.e2ee, .signalingStream])
    }

    /// The two origins must not collapse. Occupancy and "tell the peer" are different questions.
    func testLocalAndRemoteHangupChannelsDiffer() {
        XCTAssertNotEqual(
            callHangupChannels(origin: .local),
            callHangupChannels(origin: .remote)
        )
    }
}
