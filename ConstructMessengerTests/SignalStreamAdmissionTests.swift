//
//  SignalStreamAdmissionTests.swift
//  ConstructMessengerTests
//
//  What the signaling stream is allowed to deliver.
//
//  gRPC/TLS ends at the signaling server, so everything arriving on that stream is a value the
//  server chose to send. Until 2026-08-21 `handleSignalResponse` accepted `.offer` and `.answer`
//  from it and handed the SDP to WebRTC, and `decryptSdp` passed an unprefixed value through
//  unchanged — so the SDP was applied as plaintext, carrying the DTLS fingerprint and the whole
//  media path, with no end-to-end check on where it came from.
//
//  No peer could reach those handlers. signaling-service forwards no SDP in either direction: the
//  Offer arm of `service.rs` sends `IncomingCall` without the SDP and stores no pending offer, and
//  the Answer arm updates call state only. Both arms had been marked deprecated and left in place,
//  on both sides. `AGENTS.md` states the rule — "a handler no producer reaches is either wired up
//  or deleted" — and deprecating it is neither.
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class SignalStreamAdmissionTests: XCTestCase {

    private typealias Signal = Shared_Proto_Signaling_V1_WebRTCSignal.OneOf_Signal

    // MARK: - What must be refused

    /// The defect, stated directly. An SDP offer on this stream is not a peer's offer — it is the
    /// server's, and applying it substitutes the media path.
    ///
    /// Mutation: return `.accept` for `.offer`.
    func testAnOfferOnTheSignalingStreamIsRefused() {
        XCTAssertEqual(
            signalStreamAdmission(for: .offer(Shared_Proto_Signaling_V1_CallOffer())),
            .refuseSdp,
            "an offer here has no peer behind it — the server does not forward SDP"
        )
    }

    /// Mutation: return `.accept` for `.answer`.
    func testAnAnswerOnTheSignalingStreamIsRefused() {
        XCTAssertEqual(
            signalStreamAdmission(for: .answer(Shared_Proto_Signaling_V1_CallAnswer())),
            .refuseSdp,
            "an answer here would set the remote description from a value the server picked"
        )
    }

    /// An empty offer is refused for the same reason a populated one is. The decision is about the
    /// channel the signal arrived on, not about whether this particular SDP looks usable —
    /// `offerSdpIsUsable` answers that separate question, one layer in.
    ///
    /// Mutation: gate the refusal on `!offer.sdp.isEmpty`.
    func testRefusalDoesNotDependOnWhatTheSdpContains() {
        var populated = Shared_Proto_Signaling_V1_CallOffer()
        populated.sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"
        XCTAssertEqual(signalStreamAdmission(for: .offer(populated)), .refuseSdp)
        XCTAssertEqual(signalStreamAdmission(for: .offer(Shared_Proto_Signaling_V1_CallOffer())), .refuseSdp)
    }

    // MARK: - What must still get through

    /// The stream's actual job. Refusing these would take down calls entirely: presence is the only
    /// thing this client sends here (ringing, connected, hangup, ping), and `.connected` is what
    /// moves a call off the server's aggressive ringing reaper.
    ///
    /// Mutation: `return .refuseSdp` unconditionally. This is the test that stops the fix from
    /// being "close the stream".
    func testPresenceAndCandidatesAreStillAccepted() {
        let allowed: [Signal] = [
            .ringing(Shared_Proto_Signaling_V1_CallRinging()),
            .busy(Shared_Proto_Signaling_V1_CallBusy()),
            .hangup(Shared_Proto_Signaling_V1_CallHangup()),
            .iceCandidate(Shared_Proto_Signaling_V1_IceCandidate()),
            .iceCandidates(Shared_Proto_Signaling_V1_IceCandidateBatch()),
            .mediaUpdate(Shared_Proto_Signaling_V1_MediaUpdate())
        ]
        for signal in allowed {
            XCTAssertEqual(signalStreamAdmission(for: signal), .accept, "\(signal) is what the stream is for")
        }
    }

    /// ICE candidates travel this stream and are accepted here — the check that protects them is a
    /// different one, and it is worth naming so the two are not confused. `IceCandidate.candidate`
    /// is `bytes` as of 2026-08-21 and `CallSignalFrame.decode` refuses anything that is not our
    /// frame, so a server-authored candidate fails to parse rather than being admitted by this
    /// decision. That is why `.iceCandidate` can be `.accept` while `.offer` cannot: the candidate
    /// carries its own proof and the SDP field carries none.
    ///
    /// Mutation: return `.refuseSdp` for `.iceCandidate`.
    func testCandidatesAreAcceptedBecauseTheFrameIsWhatRefusesThem() {
        XCTAssertEqual(signalStreamAdmission(for: .iceCandidate(Shared_Proto_Signaling_V1_IceCandidate())), .accept)
        XCTAssertThrowsError(
            try CallSignalFrame.decode(Data("candidate:1 1 UDP 2130706431 192.168.1.5 54321 typ host".utf8)),
            "a plaintext candidate is not a frame and must not decode"
        )
    }

    /// An absent oneof is not an SDP, and refusing it would log a security warning for an empty
    /// keepalive. The inner switch handles `nil` by doing nothing.
    func testAnEmptySignalIsNotTreatedAsSdp() {
        XCTAssertEqual(signalStreamAdmission(for: nil), .accept)
    }
}
