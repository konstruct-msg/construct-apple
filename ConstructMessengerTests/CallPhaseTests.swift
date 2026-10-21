//
//  CallPhaseTests.swift
//  ConstructMessengerTests
//
//  The phase a call screen shows for each call state, and how an ended call reads: a declined
//  call is not a failure, a failure is not "ended", a normal end carries its duration.
//

import XCTest
@testable import Construct_Messenger

final class CallPhaseTests: XCTestCase {
    private let session = CallSession(id: "c", uuid: UUID(), peerUserId: "p", peerName: "P", direction: .outgoing)

    func testEachLiveStateHasItsPhase() {
        XCTAssertNil(CallPhase.of(.idle, quality: .good, connectedSeconds: nil))
        XCTAssertEqual(CallPhase.of(.incoming(session), quality: .good, connectedSeconds: nil), .incoming)
        XCTAssertEqual(CallPhase.of(.dialing(session), quality: .good, connectedSeconds: nil), .calling)
        XCTAssertEqual(CallPhase.of(.ringing(session), quality: .good, connectedSeconds: nil), .ringing)
        XCTAssertEqual(CallPhase.of(.connecting(session), quality: .good, connectedSeconds: nil), .connecting)
        XCTAssertEqual(CallPhase.of(.active(session), quality: .good, connectedSeconds: 3), .live)
    }

    func testALostPathWhileActiveIsReconnecting() {
        XCTAssertEqual(CallPhase.of(.active(session), quality: .reconnecting, connectedSeconds: 3), .reconnecting)
    }

    func testHowTheOtherSideEndedIsKept() {
        func outcome(_ r: Shared_Proto_Signaling_V1_HangupReason) -> CallOutcome {
            CallPhase.outcome(of: .hangup(r), connectedSeconds: nil)
        }
        XCTAssertEqual(outcome(.declined), .declined)
        XCTAssertEqual(outcome(.busy), .busy)
        XCTAssertEqual(outcome(.timeout), .noAnswer)
        XCTAssertEqual(outcome(.connectionFailed), .failed)
    }

    func testANormalEndCarriesHowLongTheCallWasConnected() {
        XCTAssertEqual(CallPhase.of(.ended(session, .hangup(.normal)), quality: .good, connectedSeconds: 845),
                       .over(.ended(seconds: 845)))
        XCTAssertEqual(CallPhase.outcome(of: .hangup(.normal), connectedSeconds: nil), .ended(seconds: nil))
    }

    func testLocalReasonsAreFailures() {
        XCTAssertEqual(CallPhase.outcome(of: .local("ICE connection failed"), connectedSeconds: nil), .failed)
        XCTAssertEqual(CallPhase.outcome(of: .local("Call setup failed"), connectedSeconds: 12), .failed)
    }

    func testTheServersErrorsSayBusyOrUnansweredWhenThatIsWhatTheyMean() {
        XCTAssertEqual(CallPhase.outcome(of: .error(.calleeBusy), connectedSeconds: nil), .busy)
        XCTAssertEqual(CallPhase.outcome(of: .error(.callExpired), connectedSeconds: nil), .noAnswer)
        XCTAssertEqual(CallPhase.outcome(of: .error(.rateLimited), connectedSeconds: nil), .failed)
    }

    func testOnlyANormalEndClosesItself() {
        XCTAssertFalse(CallOutcome.ended(seconds: 10).wantsAttention)
        for o in [CallOutcome.declined, .busy, .noAnswer, .failed] {
            XCTAssertTrue(o.wantsAttention, "\(o)")
        }
    }

    func testTheMicrophoneMattersOnlyWhileTheCallHoldsIt() {
        for p in [CallPhase.calling, .ringing, .connecting, .live, .reconnecting] { XCTAssertTrue(p.isLive, "\(p)") }
        for p in [CallPhase.incoming, .over(.declined)] { XCTAssertFalse(p.isLive, "\(p)") }
    }
}
