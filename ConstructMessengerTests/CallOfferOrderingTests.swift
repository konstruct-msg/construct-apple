//
//  CallOfferOrderingTests.swift
//  ConstructMessengerTests
//
//  "Есть входящий звонок" and "here is its SDP" travel on separate channels — the VoIP push (fast,
//  call id only) and the E2EE message stream (slow, carries the SDP) — and CallKit is driven by the
//  fast one. Every ordering of those two is reachable. On 2026-08-05 (build 577) two of them were
//  unhandled, and each cost a call:
//
//      Max   10:02:56  Offer (proto) sent via E2EE
//      Annie 10:02:56  Incoming VoIP push — CallKit notified sync (95A2335E)
//      Annie 10:02:58  CallKit answer                ← answered, 2 s after the push
//      Max   10:03:12  end: state=dialing  answered=false  setupAgeMs=17659
//      Annie 10:03:18  end: state=connecting answered=false setupAgeMs=22518
//      Annie 10:03:26  handleCallSignalProto type=offer … callId=95A2335E   ← +30 s
//      Annie 10:03:26  CallKit incoming call reported (again, same uuid)    ← for a dead call
//
//  `answer()` had already run and found nothing to apply, so the late offer was stored for a
//  consumer that had been and gone: nobody built the SDP answer, and both sides sat pretending
//  until a human hung up. Then the same offer, arriving after the end, rang CallKit for a call
//  nobody was making.
//
//  Since todo 295 step 5 these orders are decided by the core's call machine (construct-rules
//  `call_machine`, tested there over every state), which `CallManager` holds as `machine`. These
//  tests drive the same object through the orders that each cost a call here, so the incident
//  stays next to the order that reproduces it.
//

import XCTest
@testable import Construct_Messenger

final class CallOfferOrderingTests: XCTestCase {

    private let t0: Int64 = 1_800_000_000_000

    /// Their call, rung by its push (no SDP yet).
    private func pushed() -> CallMachine {
        let machine = CallMachine()
        XCTAssertEqual(machine.push(callId: "c1", peerUserId: "peer", nowMs: t0), .begin)
        return machine
    }

    /// Their call, rung by its offer from `d1`.
    private func rung() -> CallMachine {
        let machine = CallMachine()
        XCTAssertEqual(offer(machine), .ring)
        return machine
    }

    @discardableResult
    private func offer(_ machine: CallMachine, callId: String = "c1", from peer: String = "peer",
                       usable: Bool = true, me: String = "me", at: Int64? = nil) -> CallOfferStep {
        machine.offer(callId: callId, peerUserId: peer, device: "d1", usable: usable, myUserId: me, nowMs: at ?? t0)
    }

    // MARK: - The regression: an offer that arrives after the answer must finish the answer

    func testOfferArrivingAfterTheAnswerResumesIt() {
        let machine = pushed()
        XCTAssertEqual(machine.accept(nowMs: t0 + 2_000), .waitForOffer)
        XCTAssertEqual(
            offer(machine, at: t0 + 30_000), .resumeAnswer,
            "holding it is holding it for a consumer that has already returned — the caller then "
            + "waits in `dialing` for an answer nobody is building"
        )
    }

    /// The ordinary ordering: offer first, tap second. The answer finds the SDP waiting.
    func testOfferArrivingBeforeTheAnswerIsHeldForIt() {
        let machine = pushed()
        XCTAssertEqual(offer(machine), .hold)
        XCTAssertEqual(machine.accept(nowMs: t0 + 2_000), .applyOffer)
    }

    // MARK: - A dead call must stay dead

    /// The phantom. A call's signals outlive it; ringing CallKit for one shows an incoming call
    /// from someone who is not calling.
    func testOfferForAnEndedCallIsIgnored() {
        let machine = rung()
        XCTAssertNotNil(machine.hangUp(nowMs: t0 + 1_000))
        XCTAssertEqual(offer(machine, at: t0 + 9_000), .ignore)
        XCTAssertTrue(machine.recentlyEnded(callId: "c1", nowMs: t0 + 9_000))
        XCTAssertNil(machine.active())
    }

    /// No call, never ended: the first anyone has heard of it — also the path of a call whose offer
    /// beats the push, or that has no push at all.
    func testUnknownCallIdRings() {
        XCTAssertEqual(offer(CallMachine()), .ring)
    }

    // MARK: - An offer for a call already on screen (build 583, 2026-08-06)

    //  An offer for a known call went to a third implementation of "apply the offer and answer"
    //  that negotiated with no consent:
    //
    //      13:52:06  Incoming VoIP push — CallKit notified
    //      13:52:06  Answer (proto) sent via E2EE          ← answered, unasked
    //      13:52:13  CallKit answer                        ← the user, seven seconds later
    //      13:52:22  Call end                              ← never worked

    func testAnUnansweredCallHoldsTheOfferAndAnAnsweredOneRenegotiates() {
        let machine = pushed()
        XCTAssertEqual(offer(machine), .hold, "negotiating here answers the call on the user's behalf")
        machine.accept(nowMs: t0 + 1_000)
        machine.answered(nowMs: t0 + 2_000)
        XCTAssertEqual(offer(machine, at: t0 + 60_000), .renegotiate,
                       "holding an ICE-restart offer strands a call the user is in")
    }

    // MARK: - An offer with no SDP (build 613, 2026-08-17)

    /// The empty string is the exact value on which the old pair of checks split: the ICE paths
    /// asked `pendingRemoteOfferSdp != nil` and got "yes, we are holding an offer", while `answer()`
    /// asked `!isEmpty` and got "no, nothing to apply". So 24 candidates queued against an offer
    /// the answer had already given up on, and the call died in `connecting` with the callee waiting
    /// for an SDP that had arrived three seconds before it answered.
    ///
    /// Mutation: `return sdp != nil` — restores the ICE-side reading, and the disagreement with it.
    func testAnEmptyOfferIsNotAnOfferWeAreHolding() {
        XCTAssertFalse(
            offerSdpIsUsable(""),
            "an empty SDP read as a held offer is what buffered ICE candidates against a "
            + "negotiation that could never start"
        )
    }

    /// No offer at all reads the same as an unusable one.
    func testAMissingOfferIsNotAnOfferWeAreHolding() {
        XCTAssertFalse(offerSdpIsUsable(nil))
    }

    /// The other direction: a real offer must still be negotiable.
    ///
    /// Mutation: `return false` — every call stops connecting.
    func testARealOfferIsUsable() {
        XCTAssertTrue(
            offerSdpIsUsable("v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=-\r\n"),
            "the guard exists to refuse the empty offer, not to refuse offers"
        )
    }

    /// An unusable offer rings nothing for a new call and ends the call it belongs to.
    func testAnOfferWithoutSdpRingsNothingAndEndsItsCall() {
        let machine = CallMachine()
        XCTAssertEqual(offer(machine, usable: false), .ignore)
        XCTAssertNil(machine.active())

        let machine2 = pushed()
        guard case .fail(let failure) = offer(machine2, usable: false) else {
            return XCTFail("an unusable offer for the call in progress ends it")
        }
        XCTAssertEqual(failure.ended.cause, .local)
        XCTAssertNil(failure.hangup, "still ringing: the caller's other devices ring on")
    }

    // MARK: - The push that arrives second (build 630, 2026-08-22)

    //  The offer wins the race, and the push lands on a call already ringing with its SDP held and
    //  its ICE buffered. `handleIncomingPush` called `begin()` regardless, which replaced the
    //  ActiveCall and took both with it:
    //
    //      11:37:56  Incoming offer SDP from ffeeddc6… sdp=1155b
    //      11:37:57  Buffered 32/32 E2EE ICE candidates (pending SDP)
    //      11:37:58  Incoming VoIP push — CallKit notified sync
    //      11:38:14  Call end   state=connecting answered=false mediaConnected=false

    func testPushForTheCallWeAlreadyTrackDoesNotRestartIt() {
        let machine = rung()
        XCTAssertEqual(machine.push(callId: "c1", peerUserId: "peer", nowMs: t0 + 2_000), .alreadyTracking)
        XCTAssertEqual(machine.active()?.holdsOffer, true)
    }

    // MARK: - A second call never ends the call in progress (2026-10-01)
    //
    //  Here only the push asked; the offer for the same second call found no match, rang as a new
    //  call, and `begin()` began with `active?.close()` — the call in progress was hung up by
    //  someone else dialling in.

    func testASecondCallerIsBusyByPushOrByOffer() {
        let machine = rung()
        XCTAssertEqual(machine.push(callId: "c2", peerUserId: "other", nowMs: t0), .declineBusy)
        XCTAssertEqual(offer(machine, callId: "c3", from: "third"), .busy)
        XCTAssertEqual(machine.active()?.callId, "c1")
        // The push declined c2 first and remembered it; its offer, later, is dropped quietly.
        XCTAssertEqual(offer(machine, callId: "c2", from: "other", at: t0 + 1), .ignore)
    }

    /// Glare is not a second caller: our call to them is up and they dialled us. The push must not
    /// refuse it or remember it — the offer decides which call survives.
    func testAPushInGlareDefersToTheOffer() {
        let machine = CallMachine()
        XCTAssertEqual(machine.dial(callId: "mine", peerUserId: "b", nowMs: t0), .start)
        XCTAssertEqual(machine.push(callId: "theirs", peerUserId: "b", nowMs: t0), .deferToGlare)
        XCTAssertFalse(machine.recentlyEnded(callId: "theirs", nowMs: t0))
        XCTAssertEqual(offer(machine, callId: "theirs", from: "b", me: "a"), .replaceOutgoing(replaced: "mine"))
    }
}
