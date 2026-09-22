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
//  2026-09-22: the branch carries a second value for the same reason. `peerOnDeadSession` answers
//  `plan_teardown`; `cause` answers the window in `orchestration::session_machine`. They were one
//  `Bool` until step 2 of `decisions/session-is-one-state-machine.md`, and one `Bool` cannot say
//  "tell this device even though we hold no session with it" and "this teardown may be silenced
//  by the peer's own" separately — which is what the two branches here need it to say.
//

import XCTest
@testable import Construct_Messenger

final class InitFailureEvidenceTests: XCTestCase {

    /// The typed branch is the one the field failure ran through.
    func testTheOtpkBranchCarriesEvidence() {
        let action = SessionReducer.initFailureAction(otpkUnreproducible: true)
        XCTAssertEqual(action, .sendTypedOtpk)
        XCTAssertTrue(
            action.peerOnDeadSession,
            "an unreproducible OTPK means the peer built a session we cannot open — without this "
            + "the teardown plan skips every device and the request is never sent"
        )
    }

    func testThePlainInitFailureCarriesEvidence() {
        let action = SessionReducer.initFailureAction(otpkUnreproducible: false)
        XCTAssertEqual(action, .sendPlain)
        XCTAssertTrue(
            action.peerOnDeadSession,
            "an init we could not complete was still an init for a message that arrived"
        )
    }

    /// **The typed hint is never silenced.** It used to bypass a 20 s grace computed in the
    /// coordinator; it now declares `Explained`, which is the cause the machine does not answer
    /// away. Declaring `.blind` here would be invisible — the teardown would be swallowed inside
    /// the peer's quiet and the 4-DH retry loop this reason exists to break would continue.
    func testTheOtpkBranchIsNeverSilencedByThePeersOwnTeardown() {
        XCTAssertEqual(SessionReducer.initFailureAction(otpkUnreproducible: true).cause, .explained)
    }

    /// **The plain branch is the one the grace was for.** A plain AEAD failure right after the
    /// peer tore down is a stale-wire race, and answering it with a teardown is the storm. It
    /// declares `Blind`, which is the one cause the peer's own teardown answers away.
    func testThePlainBranchIsTheOneThePeersTeardownAnswers() {
        XCTAssertEqual(SessionReducer.initFailureAction(otpkUnreproducible: false).cause, .blind)
    }

    /// Pins the asymmetry itself rather than three separate values: every branch here sends, so
    /// every branch carries evidence, and what separates them is the cause. A branch added
    /// without deciding both questions fails here rather than shipping as a silent `.skip` or a
    /// silently swallowed teardown.
    func testEveryBranchDecidesBothQuestions() {
        let all: [SessionReducer.InitFailureAction] = [.sendTypedOtpk, .sendPlain]
        for action in all {
            XCTAssertTrue(
                action.peerOnDeadSession,
                "\(action): a branch that sends END_SESSION after a failed init must carry evidence"
            )
        }
        XCTAssertEqual(
            Set(all.map(\.cause)), [.explained, .blind],
            "the two branches must not declare the same cause — that is the fold that hid them"
        )
    }
}
