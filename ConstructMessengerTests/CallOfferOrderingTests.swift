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
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class CallOfferOrderingTests: XCTestCase {

    // MARK: - The regression: an offer that arrives after the answer must finish the answer

    /// The defect. The user tapped Answer while the SDP was still in flight; the offer that finally
    /// lands must complete the answer, not be filed away.
    ///
    /// Mutation: return `.storeForAnswer` when `awaitingOfferAfterAnswer`.
    func testOfferArrivingAfterTheAnswerResumesIt() {
        XCTAssertEqual(
            callOfferDisposition(
                hasRecentlyEnded: false,
                matchesActiveIncomingCall: true,
                awaitingOfferAfterAnswer: true
            ),
            .resumeAnswer,
            "storing it is storing it for a consumer that has already returned — the caller then "
            + "waits in `dialing` for an answer nobody is building"
        )
    }

    /// The ordinary ordering, which always worked: offer first, tap second. `answer()` finds the
    /// SDP waiting and consumes it, so the arriving offer only needs to be stored.
    ///
    /// Mutation: return `.resumeAnswer` unconditionally — this is what stops the fix from firing
    /// a second, concurrent answer on the normal path.
    func testOfferArrivingBeforeTheAnswerIsJustStored() {
        XCTAssertEqual(
            callOfferDisposition(
                hasRecentlyEnded: false,
                matchesActiveIncomingCall: true,
                awaitingOfferAfterAnswer: false
            ),
            .storeForAnswer
        )
    }

    // MARK: - A dead call must stay dead

    /// The phantom. A call's signals outlive it — the offer rides the ordinary message stream and
    /// can be delivered long after both sides gave up. Ringing CallKit for it shows the user an
    /// incoming call from someone who is not calling them.
    ///
    /// Mutation: drop the `hasRecentlyEnded` guard.
    func testOfferForAnEndedCallIsIgnored() {
        XCTAssertEqual(
            callOfferDisposition(
                hasRecentlyEnded: true,
                matchesActiveIncomingCall: false,
                awaitingOfferAfterAnswer: false
            ),
            .ignoreCallEnded
        )
    }

    /// "Ended" outranks everything. A redelivered offer for a call that ended while still active
    /// must not resume an answer either — the state it would resume no longer exists.
    func testEndedOutranksAnActiveMatch() {
        XCTAssertEqual(
            callOfferDisposition(
                hasRecentlyEnded: true,
                matchesActiveIncomingCall: true,
                awaitingOfferAfterAnswer: true
            ),
            .ignoreCallEnded,
            "the end is the most recent fact about this call id"
        )
    }

    // MARK: - A genuinely new call must still ring

    /// The guard must not swallow real calls: no active call, never ended, so this is the first
    /// anyone has heard of it. This is also the path a call takes when the offer beats the push,
    /// or when there is no push at all.
    ///
    /// Mutation: return `.ignoreCallEnded` unconditionally — the one that would make the fix
    /// silently stop all incoming calls.
    func testUnknownCallIdRings() {
        XCTAssertEqual(
            callOfferDisposition(
                hasRecentlyEnded: false,
                matchesActiveIncomingCall: false,
                awaitingOfferAfterAnswer: false
            ),
            .reportNewCall
        )
    }

    /// `awaitingOfferAfterAnswer` is meaningless without a matching call and must not leak into
    /// this decision — a stale flag cannot turn a new call into a resume.
    func testAwaitingFlagWithoutAMatchStillRings() {
        XCTAssertEqual(
            callOfferDisposition(
                hasRecentlyEnded: false,
                matchesActiveIncomingCall: false,
                awaitingOfferAfterAnswer: true
            ),
            .reportNewCall
        )
    }

    // MARK: - All orderings are accounted for

    /// Every combination maps to exactly one disposition, and each disposition is reachable. The
    /// two that were missing are the two that cost a call.
    func testEveryOrderingHasADisposition() {
        var seen: Set<CallOfferDisposition> = []
        for ended in [true, false] {
            for match in [true, false] {
                for awaiting in [true, false] {
                    seen.insert(callOfferDisposition(
                        hasRecentlyEnded: ended,
                        matchesActiveIncomingCall: match,
                        awaitingOfferAfterAnswer: awaiting
                    ))
                }
            }
        }
        XCTAssertEqual(
            seen,
            [.ignoreCallEnded, .resumeAnswer, .storeForAnswer, .reportNewCall],
            "an unreachable disposition is a branch that cannot be exercised on a device either"
        )
    }

    // MARK: - Not covered here, on purpose
    //
    // The 45 s answer-without-offer timeout and the `applyOfferAndAnswer` sequence itself are not
    // covered: both live inside `CallManager`, a @MainActor singleton wired to CallKit, PushKit and
    // WebRTC, and a test that stands none of that up would assert nothing while looking like
    // coverage (decisions/ios-semantic-divergence-signals, amendment 2026-08-04). On device they
    // read as `answer_before_offer` labelled `wait` → `resumed`, or `wait` → `timeout`; a `wait`
    // with neither successor is the defect returning.

    // MARK: - An offer for a call already on screen (build 583, 2026-08-06)

    //  `callOfferDisposition` above was only reachable when no ActiveCall existed. When one did,
    //  `handleCallSignalProto` went to `handleRemoteOffer` — a third implementation of "apply the
    //  offer and answer" that negotiates, stamps `answeredAt` and sets the call `.active` with no
    //  consent, and without touching `pendingRemoteOfferSdp`. Which one ran was a race between the
    //  VoIP push (call id, fast) and the E2EE offer (SDP, slow), and the push usually wins:
    //
    //      13:52:06  Incoming VoIP push — CallKit notified
    //      13:52:06  Answer (proto) sent via E2EE          ← answered, unasked
    //      13:52:13  CallKit answer                        ← the user, seven seconds later
    //      13:52:13  "Answered before the offer arrived — waiting up to 45s for SDP"
    //      13:52:22  Call end                              ← never worked

    /// The regression, and the reason the call died: an unanswered incoming call must not
    /// negotiate. Consent starts the handshake.
    func testUnansweredIncomingCallHoldsTheOffer() {
        XCTAssertEqual(
            remoteOfferDisposition(isIncomingCall: true, hasAnswered: false),
            .holdUntilAnswered,
            "negotiating here answers the call on the user's behalf and consumes the SDP the real answer needs"
        )
    }

    /// Once answered, an offer is the peer renegotiating — an ICE restart. Holding it would strand
    /// a call the user is in the middle of, which is the failure mode in the other direction.
    func testAnsweredIncomingCallRenegotiates() {
        XCTAssertEqual(
            remoteOfferDisposition(isIncomingCall: true, hasAnswered: true),
            .renegotiate
        )
    }

    /// An offer on our own outgoing call is never a consent question — we placed the call.
    func testOutgoingCallAlwaysRenegotiates() {
        XCTAssertEqual(
            remoteOfferDisposition(isIncomingCall: false, hasAnswered: false),
            .renegotiate
        )
        XCTAssertEqual(
            remoteOfferDisposition(isIncomingCall: false, hasAnswered: true),
            .renegotiate
        )
    }

    /// Consent is the only thing that distinguishes the two, and it is read from `answeredAt` —
    /// the same field the duration and the completed/missed verdict come from. Pinned so a future
    /// change that re-stamps it on renegotiation shows up here as well as in the call history.
    func testOnlyConsentSeparatesTheTwoDispositions() {
        XCTAssertNotEqual(
            remoteOfferDisposition(isIncomingCall: true, hasAnswered: false),
            remoteOfferDisposition(isIncomingCall: true, hasAnswered: true)
        )
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

    /// No offer at all reads the same as an unusable one. Both sites ask this one question now, so
    /// the two states they must not confuse are the same state.
    func testAMissingOfferIsNotAnOfferWeAreHolding() {
        XCTAssertFalse(offerSdpIsUsable(nil))
    }

    /// The other direction, and the reason the predicate is not simply `false`: a real offer must
    /// still be negotiable. Refusing every offer would turn one dead call into all of them.
    ///
    /// Mutation: `return false` — every call stops connecting.
    func testARealOfferIsUsable() {
        XCTAssertTrue(
            offerSdpIsUsable("v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=-\r\n"),
            "the guard exists to refuse the empty offer, not to refuse offers"
        )
    }

    // MARK: - The push that arrives second (build 630, 2026-08-22)

    //  The other ordering, and the one the tests above never reached: the offer wins the race, and
    //  the push lands on a call that is already ringing with its SDP held and its ICE buffered.
    //  `handleIncomingPush` called `begin()` regardless, which replaces the ActiveCall and takes
    //  both with it:
    //
    //      11:37:56  Incoming offer SDP from ffeeddc6… sdp=1155b
    //      11:37:57  Buffered 32/32 E2EE ICE candidates (pending SDP)
    //      11:37:58  Incoming VoIP push — CallKit notified sync
    //      11:37:58  CallKit reportNewIncomingCall failed: Code=2   ← callUUIDAlreadyExists
    //      11:37:59  "Answered before the offer arrived — waiting up to 45s for SDP"
    //      11:38:14  Call end   state=connecting answered=false mediaConnected=false

    /// The regression. A push for the call we are already tracking adds nothing and must not be
    /// allowed to restart it.
    ///
    /// Mutation: return `.beginNewCall` when `matchesTrackedCallId` — restores the discard.
    func testPushForTheCallWeAlreadyTrackDoesNotRestartIt() {
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: false,
                matchesTrackedCallId: true
            ),
            .alreadyTracking,
            "begin() here replaces the ActiveCall, and the stored offer SDP and every buffered ICE "
            + "candidate go with it — the callee then answers into nothing"
        )
    }

    /// The state the old busy guard did not cover, and the whole reason this decision is separate
    /// from it: a call ringing from an offer nobody has answered sits in `.incoming`, which is not
    /// a busy state. Being busy and already tracking this call are different questions.
    ///
    /// Mutation: `guard isBusyState else { return .beginNewCall }` before the match check.
    func testTrackingOutranksNotBeingBusy() {
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: false,
                matchesTrackedCallId: true
            ),
            .alreadyTracking
        )
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: true,
                matchesTrackedCallId: true
            ),
            .alreadyTracking,
            "our own call reaching a busy state does not make its own push a second call"
        )
    }

    /// The guard that must survive: a *different* call arriving while one is up is still declined.
    /// Without this the fix would let a second caller close the call in progress.
    ///
    /// Mutation: return `.alreadyTracking` when `hasActiveCall`, ignoring the id.
    func testADifferentCallDuringOneInProgressIsStillDeclined() {
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: true,
                matchesTrackedCallId: false
            ),
            .declineBusy
        )
    }

    /// A stale ActiveCall left behind in a non-busy state must not block a genuinely new call —
    /// this is the path the foreground `IncomingCallNotification` fallback takes.
    func testADifferentCallWithNothingInProgressBegins() {
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: false,
                matchesTrackedCallId: false
            ),
            .beginNewCall
        )
    }

    /// The ordinary case, which must keep working: the push wins the race and is the first anyone
    /// has heard of this call.
    ///
    /// Mutation: return `.alreadyTracking` unconditionally — the one that would silently stop every
    /// push-first incoming call.
    func testAPushWithNoCallInFlightBegins() {
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: false,
                isBusyState: false,
                matchesTrackedCallId: false
            ),
            .beginNewCall
        )
    }

    /// With no ActiveCall there is nothing to match or be busy with, and neither flag may leak into
    /// the decision — a stale reading of either cannot swallow a real call.
    func testWithNoActiveCallTheOtherFlagsDoNotMatter() {
        for busy in [true, false] {
            for match in [true, false] {
                XCTAssertEqual(
                    incomingPushDisposition(
                        hasActiveCall: false,
                        isBusyState: busy,
                        matchesTrackedCallId: match
                    ),
                    .beginNewCall,
                    "busy=\(busy) match=\(match)"
                )
            }
        }
    }

    /// Every combination maps to one disposition and each is reachable — the one that was missing
    /// is the one that cost the call.
    func testEveryPushOrderingHasADisposition() {
        var seen: Set<IncomingPushDisposition> = []
        for hasActive in [true, false] {
            for busy in [true, false] {
                for match in [true, false] {
                    seen.insert(incomingPushDisposition(
                        hasActiveCall: hasActive,
                        isBusyState: busy,
                        matchesTrackedCallId: match
                    ))
                }
            }
        }
        XCTAssertEqual(seen, [.declineBusy, .alreadyTracking, .beginNewCall])
    }
}
