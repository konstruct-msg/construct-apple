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

    // What an offer means is the core's rule (`call_on_offer`, construct-rules `calls`, todo 295),
    // tested there over every state. What these tests hold is this app's half: the state it reads
    // into the rule (`CallRuleWire.held`) and the orders that each cost a call here.

    private func incoming(_ id: String = "c1", from peer: String = "peer") -> CallSession {
        CallSession(id: id, uuid: UUID(), peerUserId: peer, peerName: "P", direction: .incoming)
    }

    private func outgoing(_ id: String = "c0", to peer: String = "peer") -> CallSession {
        CallSession(id: id, uuid: UUID(), peerUserId: peer, peerName: "P", direction: .outgoing)
    }

    /// An offer for `callId` from `offerer`, with `session` the call this app tracks.
    private func action(
        callId: String = "c1", from offerer: String = "peer", me: String = "me",
        ended: Bool = false, session: CallSession?, busy: Bool = true,
        answered: Bool = false, awaiting: Bool = false
    ) -> CallOfferAction {
        callOnOffer(
            recentlyEnded: ended,
            held: CallRuleWire.held(callId: callId, offerer: offerer, session: session, isBusy: busy,
                                    answered: answered, awaitingOfferAfterAnswer: awaiting),
            myUserId: me, offererUserId: offerer
        )
    }

    // MARK: - The regression: an offer that arrives after the answer must finish the answer

    /// The defect. The user tapped Answer while the SDP was still in flight; the offer that finally
    /// lands must complete the answer, not be filed away. This app leaves `answeredAt` unset while
    /// it waits, so the wait is read from `awaitingOfferAfterAnswer`.
    ///
    /// Mutation: `CallRuleWire.held` passes `awaitingOfferAfterAnswer: false`.
    func testOfferArrivingAfterTheAnswerResumesIt() {
        XCTAssertEqual(
            action(session: incoming(), awaiting: true),
            .resumeAnswer,
            "holding it is holding it for a consumer that has already returned — the caller then "
            + "waits in `dialing` for an answer nobody is building"
        )
    }

    /// The ordinary ordering, which always worked: offer first, tap second. `answer()` finds the
    /// SDP waiting and consumes it, so the arriving offer only needs to be held.
    func testOfferArrivingBeforeTheAnswerIsJustHeld() {
        XCTAssertEqual(action(session: incoming()), .holdUntilAnswered)
    }

    // MARK: - A dead call must stay dead

    /// The phantom. A call's signals outlive it — the offer rides the ordinary message stream and
    /// can be delivered long after both sides gave up. Ringing CallKit for it shows the user an
    /// incoming call from someone who is not calling them.
    func testOfferForAnEndedCallIsIgnored() {
        XCTAssertEqual(action(ended: true, session: nil), .ignoreEnded)
    }

    /// "Ended" outranks everything, a call still held under that id included.
    func testEndedOutranksAnActiveMatch() {
        XCTAssertEqual(action(ended: true, session: incoming(), awaiting: true), .ignoreEnded)
    }

    // MARK: - A genuinely new call must still ring

    /// No call at all, never ended: the first anyone has heard of it. This is also the path a
    /// call takes when the offer beats the push, or when there is no push at all.
    func testUnknownCallIdRings() {
        XCTAssertEqual(action(session: nil), .ring)
    }

    /// A different call that no longer occupies the phone (idle, ended) holds nothing: a stale
    /// call must neither refuse a real one nor lend it its flags.
    ///
    /// Mutation: `CallRuleWire.held` ignores `isBusy`.
    func testAStaleOtherCallDoesNotStandInTheWay() {
        XCTAssertEqual(action(session: incoming("c0"), busy: false, awaiting: true), .ring)
    }

    /// The offer's own call is held whatever its state: its offer is that call's SDP.
    ///
    /// Mutation: `CallRuleWire.held` holds nothing when `isBusy` is false.
    func testTheOffersOwnCallIsHeldInAnyState() {
        XCTAssertEqual(action(session: incoming(), busy: false), .holdUntilAnswered)
    }

    // MARK: - An offer for a call already on screen (build 583, 2026-08-06)

    //  An offer for a known call used to go to `handleRemoteOffer` — a third implementation of
    //  "apply the offer and answer" that negotiates, stamps `answeredAt` and sets the call
    //  `.active` with no consent, and without touching `pendingRemoteOfferSdp`. Which one ran was
    //  a race between the VoIP push (call id, fast) and the E2EE offer (SDP, slow), and the push
    //  usually wins:
    //
    //      13:52:06  Incoming VoIP push — CallKit notified
    //      13:52:06  Answer (proto) sent via E2EE          ← answered, unasked
    //      13:52:13  CallKit answer                        ← the user, seven seconds later
    //      13:52:13  "Answered before the offer arrived — waiting up to 45s for SDP"
    //      13:52:22  Call end                              ← never worked

    /// Once answered, an offer is the peer renegotiating — an ICE restart. Holding it would strand
    /// a call the user is in the middle of.
    ///
    /// Mutation: `CallRuleWire.held` passes `answered: false`.
    func testAnsweredIncomingCallRenegotiates() {
        XCTAssertEqual(action(session: incoming(), answered: true), .renegotiate)
    }

    /// An offer on our own outgoing call is never a consent question — we placed the call.
    ///
    /// Mutation: `CallRuleWire.direction` maps outgoing to incoming.
    func testOutgoingCallAlwaysRenegotiates() {
        XCTAssertEqual(action(callId: "c0", session: outgoing()), .renegotiate)
        XCTAssertEqual(action(callId: "c0", session: outgoing(), answered: true), .renegotiate)
    }

    // MARK: - Glare: both dialled each other

    /// The higher account id keeps its outgoing call and ignores the offer; the lower one gives
    /// way. Without one answer both sides tear down their call and none is established.
    ///
    /// Mutation: `CallRuleWire.held` passes `withOfferer: false`.
    func testGlareKeepsOneCallOfTheTwo() {
        XCTAssertEqual(action(from: "a", me: "b", session: outgoing(to: "a")), .keepOurs)
        XCTAssertEqual(action(from: "b", me: "a", session: outgoing(to: "b")), .replaceOutgoing)
    }

    /// Our outgoing call is to someone else: their offer is a second caller, not glare.
    ///
    /// Mutation: `CallRuleWire.held` passes `withOfferer: true`.
    func testAnOfferFromSomeoneElseWhileWeDialIsBusy() {
        XCTAssertEqual(action(from: "a", me: "b", session: outgoing(to: "c")), .busy)
    }

    /// Every action is reachable from this app's state. An unreachable one is a branch of
    /// `handleOffer` that cannot be exercised on a device either.
    func testEveryActionIsReachableFromThisAppsState() {
        var seen: Set<CallOfferAction> = []
        let sessions: [CallSession?] = [nil, incoming(), incoming("c0"), outgoing(to: "a"), outgoing(to: "b"),
                                        outgoing("c1", to: "a")]
        for ended in [true, false] {
            for session in sessions {
                for busy in [true, false] {
                    for answered in [true, false] {
                        for awaiting in [true, false] {
                            seen.insert(action(from: "a", me: "b", ended: ended, session: session, busy: busy,
                                               answered: answered, awaiting: awaiting))
                            seen.insert(action(from: "b", me: "a", ended: ended, session: session, busy: busy,
                                               answered: answered, awaiting: awaiting))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(seen, [.ignoreEnded, .resumeAnswer, .holdUntilAnswered, .renegotiate, .ring,
                              .keepOurs, .replaceOutgoing, .busy])
    }

    // MARK: - Not covered here, on purpose
    //
    // The 45 s answer-without-offer timeout and the `applyOfferAndAnswer` sequence itself are not
    // covered: both live inside `CallManager`, a @MainActor singleton wired to CallKit, PushKit and
    // WebRTC, and a test that stands none of that up would assert nothing while looking like
    // coverage (decisions/ios-semantic-divergence-signals, amendment 2026-08-04). On device they
    // read as `answer_before_offer` labelled `wait` → `resumed`, or `wait` → `timeout`; a `wait`
    // with neither successor is the defect returning.

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
                matchesTrackedCallId: true,
                isGlareWithCaller: false
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
                matchesTrackedCallId: true,
                isGlareWithCaller: false
            ),
            .alreadyTracking
        )
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: true,
                matchesTrackedCallId: true,
                isGlareWithCaller: false
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
                matchesTrackedCallId: false,
                isGlareWithCaller: false
            ),
            .declineBusy
        )
    }

    /// A stale ActiveCall left behind in a non-busy state (`.idle`, `.ended`) must not block a
    /// genuinely new call — this is the path the foreground `IncomingCallNotification` fallback
    /// takes.
    func testADifferentCallWithNothingInProgressBegins() {
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: false,
                matchesTrackedCallId: false,
                isGlareWithCaller: false
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
                matchesTrackedCallId: false,
                isGlareWithCaller: false
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
                        matchesTrackedCallId: match,
                        isGlareWithCaller: false
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
                        matchesTrackedCallId: match,
                        isGlareWithCaller: false
                    ))
                }
            }
        }
        XCTAssertEqual(seen, [.declineBusy, .alreadyTracking, .beginNewCall])
    }

    // MARK: - A second call never ends the call in progress (2026-10-01)
    //
    //  Android pointed at it from its own code: there the offer decides "busy", the second caller
    //  gets hangup BUSY and the call in progress is untouched. Here only the push asked; the offer
    //  for the same second call found no match, rang as a new call, and `begin()` began with
    //  `active?.close()` — the call in progress was hung up by someone else dialling in.

    /// The defect. An offer for a different call while one is up is refused, not begun.
    func testAnOfferForASecondCallIsDeclinedAsBusy() {
        XCTAssertEqual(
            action(session: incoming("c0")),
            .busy,
            "ringing it runs begin(), which closes the call in progress"
        )
    }

    /// The push declined this call first and remembered it as ended; its offer, arriving later,
    /// must be dropped quietly rather than refused a second time.
    func testAnEndedSecondCallIsIgnoredNotDeclinedAgain() {
        XCTAssertEqual(action(ended: true, session: incoming("c0")), .ignoreEnded)
    }

    /// Being busy is about *another* call. The offer for the call we are ringing with is that call's
    /// own SDP, and must still be held.
    ///
    /// Mutation: `CallRuleWire.held` passes `sameCall: false`.
    func testBusyDoesNotRefuseTheOfferOfOurOwnCall() {
        XCTAssertEqual(action(session: incoming()), .holdUntilAnswered)
    }

    /// A call ringing unanswered occupies the phone. Until 2026-10-01 `.incoming` was not busy, and
    /// a second caller replaced the first while it was still ringing.
    ///
    /// Mutation: drop `.incoming` from `callStateIsBusy`.
    func testARingingIncomingCallIsBusy() {
        let session = CallSession(id: "c1", uuid: UUID(), peerUserId: "p", peerName: "P", direction: .incoming)
        XCTAssertTrue(callStateIsBusy(.incoming(session)))
        XCTAssertTrue(callStateIsBusy(.active(session)))
        XCTAssertFalse(callStateIsBusy(.idle))
        XCTAssertFalse(callStateIsBusy(.ended(session, .local("test"))))
    }

    /// Glare is not a second caller: our call to them is up and they dialled us. The push must not
    /// refuse it or remember it as ended — the offer's tie-break decides which call survives.
    ///
    /// Mutation: return `.declineBusy` regardless of `isGlareWithCaller` — the loser of the
    /// tie-break would then find the winner's call ended and never answer it.
    func testAPushInGlareDefersToTheTieBreak() {
        XCTAssertEqual(
            incomingPushDisposition(
                hasActiveCall: true,
                isBusyState: true,
                matchesTrackedCallId: false,
                isGlareWithCaller: true
            ),
            .deferToGlareTieBreak
        )
    }

    /// Every push combination maps to one disposition and each is reachable, glare included.
    func testEveryPushOrderingWithGlareHasADisposition() {
        var seen: Set<IncomingPushDisposition> = []
        for hasActive in [true, false] {
            for busy in [true, false] {
                for match in [true, false] {
                    for glare in [true, false] {
                        seen.insert(incomingPushDisposition(
                            hasActiveCall: hasActive,
                            isBusyState: busy,
                            matchesTrackedCallId: match,
                            isGlareWithCaller: glare
                        ))
                    }
                }
            }
        }
        XCTAssertEqual(seen, [.declineBusy, .deferToGlareTieBreak, .alreadyTracking, .beginNewCall])
    }
}
