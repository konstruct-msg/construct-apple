//
//  CallSetupHolesTests.swift
//  ConstructMessengerTests
//
//  Three holes from the 2026-08-22 two-device logs (build 631). Each decision is
//  extracted so a mutation reddens a named test. The stream and hangup rules are the core's
//  (the call machine's `streamClosed`, `call_hangup_route`, todo 295), pinned here as this app
//  calls them.
//  CallManager wiring is not stood up here (see CallOfferOrderingTests "Not covered here").
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

    /// The stream closing is the call machine's (`streamClosed`): reopened within its budget, then
    /// kept only while media or an offer wait bounds the call.
    ///
    /// 3C86C064, 2026-09-24: the callee answered, the VEIL listener refused the stream, and the
    /// receive loop ended the call while the 45s offer wait had just started.
    func testAnAnsweredCallWaitingForItsOfferOutlivesTheStream() {
        let machine = CallMachine()
        machine.push(callId: "c1", peerUserId: "peer", nowMs: 0)
        machine.accept(nowMs: 0)
        for _ in 0..<callTimings().maxStreamRetries {
            XCTAssertEqual(machine.streamClosed(nowMs: 0), .reconnect)
        }
        XCTAssertEqual(machine.streamClosed(nowMs: 0), .keepOnMessagePath)
    }

    /// The server's unanswered-call hangup rides the stream. With the stream gone, no media and no
    /// offer wait, nothing would end the call — the caller rings on after the server has hung up
    /// the callee.
    func testAnUnboundedCallEndsWithItsLastStream() {
        let machine = CallMachine()
        machine.dial(callId: "c1", peerUserId: "peer", nowMs: 0)
        for _ in 0..<callTimings().maxStreamRetries {
            XCTAssertEqual(machine.streamClosed(nowMs: 0), .reconnect)
        }
        guard case .end(let ended) = machine.streamClosed(nowMs: 0) else {
            return XCTFail("nothing else bounds the call")
        }
        XCTAssertEqual(ended.cause, .local)
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
    func testAReceivedHangupNotifiesTheServerNotThePeer() {
        XCTAssertEqual(CallRuleWire.hangupRoute(side: .remote, reason: .normal), CallHangupRoute(e2ee: false, stream: true))
    }

    /// A hangup we originate still goes both ways: the peer needs E2EE (media path),
    /// the server needs the stream (occupancy).
    func testALocalHangupGoesToThePeerAndTheServer() {
        XCTAssertEqual(CallRuleWire.hangupRoute(side: .local, reason: .normal), CallHangupRoute(e2ee: true, stream: true))
    }

    /// "Accepted elsewhere" never reaches the stream: the server ends the whole call on any hangup
    /// it sees, so there it would end the call for the device that took it. Ours (releasing a
    /// device) goes end to end only; one we received goes nowhere.
    ///
    /// Mutation: `CallRuleWire.hangupRoute` passes a fixed `.normal` to the rule.
    func testTakenElsewhereNeverReachesTheStream() {
        XCTAssertEqual(CallRuleWire.hangupRoute(side: .local, reason: .acceptedElsewhere),
                       CallHangupRoute(e2ee: true, stream: false))
        XCTAssertEqual(CallRuleWire.hangupRoute(side: .remote, reason: .acceptedElsewhere),
                       CallHangupRoute(e2ee: false, stream: false))
    }
}
