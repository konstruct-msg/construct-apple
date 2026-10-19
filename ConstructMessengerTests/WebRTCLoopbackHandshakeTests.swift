//
//  WebRTCLoopbackHandshakeTests.swift
//  ConstructMessengerTests
//
//  Two of this app's `WebRTCSession`s, caller and callee, connected to each other in one process:
//  SDP and ICE are handed across directly, and the test waits for both to report `.connected` —
//  which needs the DTLS handshake to have finished. It proves that a call still connects with
//  `WebRTC-EnableDtlsPqc` on, both sides offering X25519MLKEM768 first.
//
//  Which group was agreed is not visible from here (WebRTC does not expose it to Objective-C).
//  The handshake goes over the host's loopback, so a capture taken while this runs shows it —
//  `decisions/calls-post-quantum-dtls.md`, "Проверка".
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class WebRTCLoopbackHandshakeTests: XCTestCase {

    func testTwoSessionsConnectWithThePostQuantumTrialOn() async throws {
        let caller = try WebRTCSession(loopbackRole: .caller, video: true)
        let callee = try WebRTCSession(loopbackRole: .callee, video: true)
        defer {
            caller.close()
            callee.close()
        }

        let callerConnected = expectation(description: "caller connected")
        let calleeConnected = expectation(description: "callee connected")
        caller.onConnected = { callerConnected.fulfill() }
        callee.onConnected = { calleeConnected.fulfill() }

        caller.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await callee.addRemoteIceCandidate(candidate) }
        }
        callee.onLocalIceCandidate = { candidate in
            Task { @MainActor in try? await caller.addRemoteIceCandidate(candidate) }
        }

        let offer = try await caller.createOffer()
        try await callee.setRemoteOffer(sdp: offer)
        let answer = try await callee.createAnswer()
        try await caller.setRemoteAnswer(sdp: answer)

        await fulfillment(of: [callerConnected, calleeConnected], timeout: 30)
    }

    /// The tests above connect without a relay through `init(loopbackRole:)`, a Debug-only door.
    /// The door a call uses has none: no TURN, no session.
    ///
    /// Mutation: fall back to an empty configuration when `CallIcePlan.make` returns nil — this
    /// reddens.
    func testACallWithoutARelayIsNotPlaced() {
        XCTAssertThrowsError(try WebRTCSession(role: .caller, turn: nil, video: false, veilOn: false)) { error in
            guard case WebRTCSessionError.noRelay = error else {
                return XCTFail("expected noRelay, got \(error)")
            }
        }
    }
}
