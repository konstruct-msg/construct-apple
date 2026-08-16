//
//  InviteAcceptOutcomeTests.swift
//  ConstructMessengerTests
//
//  Created 2026-08-16.
//
//  The incident these are named after: revoking a link worked end to end on the two-simulator
//  stand — the server pre-burned the `jti` and refused the redeemer — and the redeemer was
//  shown "Could not verify invite: The operation couldn’t be completed. (GRPCCore.RPCError
//  error 1.)". The server had said `invalidArgument: "Failed to accept invite: Invite already
//  used"`. Every assertion below is a sentence a person could read off the screen.
//
//  Pure over `(code, message)`: no channel, no server, no network condition to reproduce.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

final class InviteAcceptOutcomeTests: XCTestCase {

    // MARK: - What the server says today

    /// Verbatim from the stand, 2026-08-16, after revoking the link in ISSUED INVITES.
    func testRevokedLinkReadsAsAlreadyUsed() {
        let outcome = InviteAcceptClassification.outcome(
            code: .invalidArgument,
            message: "Failed to accept invite: Invite already used"
        )
        XCTAssertEqual(outcome, .alreadyUsed)
    }

    func testExpiredInviteIsNotLumpedInWithAlreadyUsed() {
        let outcome = InviteAcceptClassification.outcome(
            code: .invalidArgument,
            message: "Failed to accept invite: Invite expired"
        )
        XCTAssertEqual(outcome, .expired)
    }

    func testTamperedLinkReadsAsBadSignature() {
        let outcome = InviteAcceptClassification.outcome(
            code: .invalidArgument,
            message: "Failed to accept invite: Invalid invite signature"
        )
        XCTAssertEqual(outcome, .badSignature)
    }

    // MARK: - What the server will say once it carries a typed code

    /// Server spec item 5. These must already pass, or the deploy silently regresses every
    /// message back to the useless one — which is exactly how this defect shipped.
    func testTypedCodeIsReadWithoutTheEnglishSentence() {
        XCTAssertEqual(
            InviteAcceptClassification.outcome(code: .failedPrecondition, message: "INVITE_ALREADY_USED"),
            .alreadyUsed
        )
        XCTAssertEqual(
            InviteAcceptClassification.outcome(code: .failedPrecondition, message: "INVITE_EXPIRED"),
            .expired
        )
        XCTAssertEqual(
            InviteAcceptClassification.outcome(code: .invalidArgument, message: "INVITE_INVALID_SIGNATURE"),
            .badSignature
        )
    }

    /// The classification is on the message, so a changed status code must not move a
    /// verdict. `alreadyUsed` is `invalidArgument` today and `failedPrecondition` after
    /// item 5; both are the same fact about the invite.
    func testVerdictSurvivesTheServerChangingItsStatusCode() {
        for code in [RPCError.Code.invalidArgument, .failedPrecondition, .alreadyExists] {
            XCTAssertEqual(
                InviteAcceptClassification.outcome(code: code, message: "Invite already used"),
                .alreadyUsed,
                "code \(code) changed the verdict"
            )
        }
    }

    // MARK: - No verdict is not a verdict

    /// The distinction the old code could not express, and the reason this type exists:
    /// "this link is dead, ask for another" and "we never reached the server" call for
    /// opposite actions from the user.
    func testTransportFailureNeverClaimsTheInviteIsBad() {
        let codes: [RPCError.Code] = [.unavailable, .deadlineExceeded, .internalError, .unknown, .cancelled, .aborted]
        for code in codes {
            let outcome = InviteAcceptClassification.outcome(code: code, message: "ipc channel closed")
            guard case .unreachable = outcome else {
                return XCTFail("\(code) was classified \(outcome), which tells the user to ask for a new link")
            }
        }
    }

    func testANonGRPCErrorIsUnreachableRatherThanRefused() {
        struct Boom: Error {}
        guard case .unreachable = InviteAcceptClassification.outcome(from: Boom()) else {
            return XCTFail("a failure that never became a gRPC status is not a verdict on the invite")
        }
    }

    func testAnUnmodelledRefusalKeepsTheServersWords() {
        let outcome = InviteAcceptClassification.outcome(
            code: .resourceExhausted,
            message: "too many invites accepted, retry in 60s"
        )
        XCTAssertEqual(outcome, .refused("resourceExhausted: too many invites accepted, retry in 60s"))
    }

    // MARK: - The description that replaced the bridged NSError

    /// The bug in one assertion: `localizedDescription` on an `RPCError` names neither the
    /// code nor the message, and reads the same for every failure there will ever be.
    func testDescriptionCarriesWhatTheBridgedNSErrorDropped() {
        let error = RPCError(code: .invalidArgument, message: "Failed to accept invite: Invite already used")
        let described = InviteAcceptClassification.describe(code: error.code, message: error.message)

        XCTAssertTrue(described.contains("Invite already used"), "the reason must survive: \(described)")
        XCTAssertTrue(described.contains("invalidArgument"), "the status must survive: \(described)")
        XCTAssertFalse(
            error.localizedDescription.contains("Invite already used"),
            "if the bridged description ever carries the message, this workaround can go"
        )
    }

    func testEmptyMessageStillNamesTheStatus() {
        XCTAssertEqual(InviteAcceptClassification.describe(code: .unavailable, message: ""), "unavailable")
    }

    // MARK: - Mapping onto what the screen says

    func testAlreadyUsedReachesTheSentenceAboutAskingForANewLink() {
        let error = LinkParser.mapAcceptError(.alreadyUsed)
        guard case .inviteAlreadyUsed = error else {
            return XCTFail("revoked and spent links must read as already used, got \(error)")
        }
    }

    func testUnreachableIsNotShownAsAnInvalidInvite() {
        let error = LinkParser.mapAcceptError(.unreachable("unavailable: connection refused"))
        guard case .verificationFailed(let underlying) = error else {
            return XCTFail("a call that reached no verdict must not be reported as a bad invite, got \(error)")
        }
        XCTAssertEqual(underlying.localizedDescription, "unavailable: connection refused")
    }

    func testRefusedShowsTheServersOwnWords() {
        let error = LinkParser.mapAcceptError(.refused("resourceExhausted: slow down"))
        guard case .inviteInvalid(let reason) = error else {
            return XCTFail("expected inviteInvalid, got \(error)")
        }
        XCTAssertEqual(reason, "resourceExhausted: slow down")
    }
}
