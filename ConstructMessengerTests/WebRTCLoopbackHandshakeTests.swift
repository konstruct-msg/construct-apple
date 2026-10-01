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
        let caller = try WebRTCSession(role: .caller, turn: nil)
        let callee = try WebRTCSession(role: .callee, turn: nil)
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
}
