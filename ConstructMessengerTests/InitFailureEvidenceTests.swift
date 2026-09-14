//
//  InitFailureEvidenceTests.swift
//  ConstructMessengerTests
//
//  2026-09-06, three devices on two accounts. B could not build a receiving session against A and
//  said so, six times in four minutes:
//
//      SESSION_STATE[otpk_unreproducible]: ffeeddc6… — will request 3-DH re-init via END_SESSION
//      END_SESSION: nothing to tear down for ffeeddc6… — 2 device(s) all skipped
//
//  Nothing reached the wire. `plan_teardown` returns `.skip` for a device we hold no session with
//  unless it is told the peer is on a session we cannot read — and after a failed RESPONDER init
//  that describes every device the peer has. The recovery request was suppressed by exactly the
//  condition that produced it, and the loop could not end: the peer kept re-sending a message that
//  could never open, and B kept asking, silently, for a restart.
//
//  The evidence now belongs to the branch rather than to the three call sites that act on it.
//

import XCTest
@testable import Construct_Messenger

final class InitFailureEvidenceTests: XCTestCase {

    /// The typed branch is the one the field failure ran through.
    func testTheOtpkBranchCarriesEvidence() {
        let action = SessionReducer.initFailureAction(
            otpkUnreproducible: true,
            withinInboundGrace: false
        )
        XCTAssertEqual(action, .sendTypedOtpk)
        XCTAssertTrue(
            action.peerOnDeadSession,
            "an unreproducible OTPK means the peer built a session we cannot open — without this "
            + "the teardown plan skips every device and the request is never sent"
        )
    }

    /// The otpk hint bypasses the inbound grace, so it must keep the evidence there too.
    func testTheOtpkBranchCarriesEvidenceEvenInsideTheInboundGrace() {
        let action = SessionReducer.initFailureAction(
            otpkUnreproducible: true,
            withinInboundGrace: true
        )
        XCTAssertEqual(action, .sendTypedOtpk)
        XCTAssertTrue(action.peerOnDeadSession)
    }

    func testThePlainInitFailureCarriesEvidence() {
        let action = SessionReducer.initFailureAction(
            otpkUnreproducible: false,
            withinInboundGrace: false
        )
        XCTAssertEqual(action, .sendPlain)
        XCTAssertTrue(
            action.peerOnDeadSession,
            "an init we could not complete was still an init for a message that arrived"
        )
    }

    /// The one branch that must NOT claim evidence: it sends nothing, and a flag on a suppressed
    /// branch would read as permission to send if anyone later moved the check.
    func testTheSuppressedBranchClaimsNoEvidence() {
        let action = SessionReducer.initFailureAction(
            otpkUnreproducible: false,
            withinInboundGrace: true
        )
        XCTAssertEqual(action, .suppressWithinGrace)
        XCTAssertFalse(action.peerOnDeadSession)
    }

    /// Pins the asymmetry itself rather than three separate values: every branch that sends
    /// carries evidence, and the one that does not send does not. A future branch added without
    /// deciding this question fails here rather than shipping as a silent `.skip`.
    func testEveryBranchThatSendsCarriesEvidence() {
        let all: [SessionReducer.InitFailureAction] = [.sendTypedOtpk, .sendPlain, .suppressWithinGrace]
        for action in all {
            let sends = action != .suppressWithinGrace
            XCTAssertEqual(
                action.peerOnDeadSession, sends,
                "\(action): a branch that sends END_SESSION after a failed init must carry evidence"
            )
        }
    }
}
