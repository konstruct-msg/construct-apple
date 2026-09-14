//
//  ProactiveInitDeferralTests.swift
//  ConstructMessengerTests
//
//  A session is opened when there is something to put in it. The decision belongs to the core
//  (`plan_initiation`); what these tests pin is that the client asks it, and asks it **before** the
//  bundle fetch — because the fetch is what spends the peer's one-time prekey, so a deferral
//  decided after it would have already cost what it was meant to save.
//
//  Devices 2026-09-04, one account and one device on each side, after A deleted the chat:
//
//      12:30:11  B  no session after restart → prewarm init → INITIATOR session created
//      12:30:44  A  its user types           → init
//      12:30:59  A  init succeeds — two INITIATOR sessions, different root keys
//      12:30:59  B  DR diverged
//      12:31:15  A  DR diverged
//      12:31:16  A  RESPONDER fallback opens a receiving session
//      12:31:32  A  four messages appear at once
//
//  Thirty-two seconds of silence, four messages batched, seven one-time prekeys spent. The
//  initiation at 12:30:11 carried nothing.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class ProactiveInitDeferralTests: XCTestCase {

    private let peer = "14f28d31-0000-0000-0000-00000000beef"
    private var service: SessionInitializationService { SessionInitializationService.shared }

    override func tearDown() {
        service.proactiveInitOverrideForTests = nil
        service.peerInitInFlight = nil
        SessionAddressing.pinnedIdentityKeyOverrideForTesting = nil
        super.tearDown()
    }

    /// Runs one call and reports whether the init run was reached and what came back.
    private func run(hasOutboundWork: Bool) async -> (reachedInit: Bool, error: Error?) {
        var reached = false
        var failure: Error?
        service.proactiveInitOverrideForTests = { _ in
            reached = true
            return true
        }
        await service.initializeSessionProactively(
            userId: peer,
            hasOutboundWork: hasOutboundWork,
            onSuccess: { },
            onFailure: { failure = $0 }
        )
        return (reached, failure)
    }

    // MARK: - The initiation that caused the outage

    /// **B at 12:30:11.** Nothing to send, no init of the peer's in hand. The run must not start,
    /// and the assertion that matters is `reachedInit == false`: the bundle fetch is where the
    /// prekey goes, so "deferred but fetched anyway" would be the defect wearing the fix's name.
    func testAPrewarmWithNothingToSendNeverReachesTheBundleFetch() async {
        service.peerInitInFlight = { _ in false }

        let result = await run(hasOutboundWork: false)

        XCTAssertFalse(result.reachedInit, "a deferred initiation must not reach the bundle fetch")
        guard let error = result.error as? SessionError,
              case .initiationDeferred = error else {
            return XCTFail("expected a named deferral, got \(String(describing: result.error))")
        }
    }

    /// **The control, and the reason the test above is not vacuous.** The same call with something
    /// to send must proceed. Without this, a service that deferred everything — or one whose
    /// override was never wired — would pass the first test perfectly.
    func testTheSameCallWithSomethingToSendProceeds() async {
        service.peerInitInFlight = { _ in false }

        let result = await run(hasOutboundWork: true)

        XCTAssertTrue(result.reachedInit, "an initiation with work to carry must reach the init run")
        XCTAssertNil(result.error)
    }

    /// The peer's init already in our hands, and no pair to rank — we hold nothing of theirs
    /// pinned yet. Yielding is the safe answer: their init opens the session and our work flows
    /// into it. Initiating would guarantee a collision with no rule available to settle it.
    func testAnInboundInitDefersOursEvenWithSomethingToSend() async {
        service.peerInitInFlight = { _ in true }

        let result = await run(hasOutboundWork: true)

        XCTAssertFalse(result.reachedInit, "their init is opening the session; ours would collide with it")
        guard let error = result.error as? SessionError,
              case .initiationDeferred = error else {
            return XCTFail("expected a named deferral, got \(String(describing: result.error))")
        }
    }

    /// The deferral is not a failure, and it must not read as one. A caller that logs
    /// `errorDescription` should say what happened rather than blame the peer or the network.
    func testTheDeferralExplainsItself() {
        let described = SessionError.initiationDeferred(decision: "wait").errorDescription ?? ""
        XCTAssertTrue(described.contains("deferred"), "got \(described)")
        XCTAssertTrue(described.contains("wait"), "the decision itself must survive into the text")
    }
}
