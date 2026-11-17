//
//  CallFailureHangupTests.swift
//  ConstructMessengerTests
//
//  A failure of ours tells the peer. On 2026-11-16 (build 779) two calls failed on this side and
//  ended here only:
//
//      iPhone  13:41:34  WebRTC connection failed — ending call      ← no hangup sent
//      Android 13:41:38  end requested (state=Active, media=false)   ← a person, four seconds on
//
//      iPhone  13:42:00  Failed to accept call: noRelay              ← no hangup sent
//      caller  13:42:08  Call end requested source=ui_end_button state=dialing
//
//  Whether the peer is told is the core's (`CallMachine.fail`, construct-core 0.76.0, tested there
//  over every phase); these tests hold the wiring: `endActiveCall` for a `.local` reason sends the
//  machine's hangup before it tears the call down.
//

import CoreData
import XCTest
@testable import Construct_Messenger

@MainActor
final class CallFailureHangupTests: XCTestCase {

    private let manager = CallManager.shared

    override func setUp() async throws {
        try await super.setUp()
        // The end records the call; not in the simulator's app store.
        LocalRepositories.useCallsForTesting(PersistenceController(inMemory: true).container)
    }

    override func tearDown() async throws {
        manager.endActiveCall(reason: .local("test"), reportToCallKit: false)
        manager.dismissEndedCall()
        LocalRepositories.useCallsForTesting(nil)
        try await super.tearDown()
    }

    /// The hangup reasons `body` wrote to the call's signalling stream.
    private func streamHangups(of session: CallSession,
                               _ body: () -> Void) async throws -> [Shared_Proto_Signaling_V1_HangupReason] {
        let active = try XCTUnwrap(manager.active)
        let (sent, outbound) = AsyncStream<Shared_Proto_Signaling_V1_SignalRequest>.makeStream()
        active.stream = SignalStream(streamTask: Task {}, outboundContinuation: outbound,
                                     accepted: AsyncStream { _ in }, incoming: AsyncStream { _ in })
        body()
        outbound.finish()
        var reasons: [Shared_Proto_Signaling_V1_HangupReason] = []
        for await request in sent {
            if case .routedSignal(let routed) = request.request,
               routed.signal.callID == session.id,
               case .hangup(let hangup) = routed.signal.signal {
                reasons.append(hangup.reason)
            }
        }
        return reasons
    }

    /// Our call failed (ICE, here): the callee is told, and the server with it.
    ///
    /// Mutation: drop the `.local` branch in `endActiveCall` — the call ends here only; this reddens.
    func testOurFailedCallTellsTheCallee() async throws {
        let session = CallSession(id: "failed-out", uuid: UUID(), peerUserId: "peer",
                                  peerName: "", direction: .outgoing)
        manager.begin(session: session, initialState: .dialing(session))
        XCTAssertEqual(manager.withMachine { $0.dial(callId: session.id, peerUserId: "peer", nowMs: Self.nowMs()) }, .start)
        manager.withMachine { $0.offerSent(devices: ["d1"]) }

        let reasons = try await streamHangups(of: session) {
            manager.endActiveCall(reason: .local("ICE connection failed"), reportToCallKit: false)
        }
        XCTAssertEqual(reasons, [.connectionFailed])
        XCTAssertNil(manager.active)
        XCTAssertNil(manager.machine.active(), "the machine ended it too")
    }

    /// Their call, still ringing here, failed: nothing goes out — the caller may be ringing our
    /// other devices, and a hangup from this one would end it there too.
    ///
    /// Mutation: send the hangup whatever the machine says (`failure.hangup` ignored); this reddens.
    func testTheirCallStillRingingFailsQuietly() async throws {
        let session = CallSession(id: "failed-in", uuid: UUID(), peerUserId: "peer",
                                  peerName: "", direction: .incoming)
        manager.begin(session: session, initialState: .incoming(session))
        XCTAssertEqual(manager.withMachine { $0.push(callId: session.id, peerUserId: "peer", nowMs: Self.nowMs()) }, .begin)

        let reasons = try await streamHangups(of: session) {
            manager.endActiveCall(reason: .local("Offer handling failed"), reportToCallKit: false)
        }
        XCTAssertEqual(reasons, [])
        XCTAssertNil(manager.active)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
