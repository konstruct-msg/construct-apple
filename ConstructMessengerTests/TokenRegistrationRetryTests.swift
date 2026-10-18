//
//  TokenRegistrationRetryTests.swift
//  ConstructMessengerTests
//
//  With VEIL `on` a cold start registered the push and VoIP tokens before the tunnel was up, got
//  `VeilTunnelNotUp`, and never tried again until the next launch (TODO 166, build 745).
//

import GRPCCore
import XCTest
@testable import Construct_Messenger

final class TokenRegistrationRetryTests: XCTestCase {

    private func retry(
        _ error: Error,
        routed: Bool = true,
        session: Bool = true
    ) async -> Bool {
        await TokenRegistrationRetry.shouldRetry(
            after: error, label: "Test",
            waitForRoute: { routed },
            waitForSession: { session }
        )
    }

    /// Mutation: drop the `VeilTunnelNotUp` branch — the first assertion reddens (it falls to
    /// `SendFailure`, which says retry at once, without waiting: the same red on the next try).
    func testNoTunnelWaitsForTheRouteThenRetries() async {
        let waited = Waited()
        let result = await TokenRegistrationRetry.shouldRetry(
            after: VeilTunnelNotUp(), label: "Test",
            waitForRoute: { await waited.mark(); return true },
            waitForSession: { true }
        )
        XCTAssertTrue(result)
        let didWait = await waited.value
        XCTAssertTrue(didWait, "waited for the tunnel before saying retry")
        let gaveUp = await retry(VeilTunnelNotUp(), routed: false)
        XCTAssertFalse(gaveUp, "no route within the limit: give up until the next launch")
    }

    /// Mutation: return false after the RPCError check — these redden.
    func testThePathFailingIsRetried() async {
        let ownDeadline = await retry(GRPCClientError.clientSideTimeout)
        let stoppedClient = await retry(RuntimeError(code: .clientIsStopped, message: ""))
        let unavailable = await retry(RPCError(code: .unavailable, message: ""))
        XCTAssertTrue(ownDeadline)
        XCTAssertTrue(stoppedClient)
        XCTAssertTrue(unavailable)
    }

    func testARefusalIsNotRetried() async {
        let denied = await retry(RPCError(code: .permissionDenied, message: ""))
        let invalid = await retry(RPCError(code: .invalidArgument, message: ""))
        XCTAssertFalse(denied)
        XCTAssertFalse(invalid)
    }

    /// Mutation: retry UNAUTHENTICATED without waiting for the session — the second reddens.
    func testUnauthenticatedWaitsForTheSession() async {
        let recovered = await retry(RPCError(code: .unauthenticated, message: ""), session: true)
        let notRecovered = await retry(RPCError(code: .unauthenticated, message: ""), session: false)
        XCTAssertTrue(recovered)
        XCTAssertFalse(notRecovered)
    }
}

private actor Waited {
    private(set) var value = false
    func mark() { value = true }
}
