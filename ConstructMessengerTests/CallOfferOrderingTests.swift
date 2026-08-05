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
}
