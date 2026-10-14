//
//  WebRTCFieldTrialsTests.swift
//  ConstructMessengerTests
//
//  The trial that makes a call's DTLS exchange post-quantum is a string WebRTC looks up at
//  runtime. If an update renames or drops it, nothing fails to compile and nothing logs: the
//  handshake quietly falls back to X25519 alone. So the test reads the WebRTC binary this app
//  ships with for the key it configures, and for the hybrid group the key turns on.
//

import XCTest
@testable import Construct_Messenger

final class WebRTCFieldTrialsTests: XCTestCase {

    private func linkedWebRTCBinary() throws -> Data {
        let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL, "the test host has no Frameworks directory")
        let binary = frameworks.appendingPathComponent("WebRTC.framework/WebRTC")
        return try Data(contentsOf: binary, options: .mappedIfSafe)
    }

    func testTheLinkedWebRTCKnowsThePostQuantumDtlsTrial() throws {
        let binary = try linkedWebRTCBinary()
        XCTAssertNotNil(
            binary.range(of: Data(WebRTCFieldTrials.dtlsPqcKey.utf8)),
            "WebRTC no longer knows \(WebRTCFieldTrials.dtlsPqcKey): calls would fall back to X25519 alone"
        )
        XCTAssertNotNil(
            binary.range(of: Data("X25519MLKEM768".utf8)),
            "the BoringSSL in this WebRTC has no hybrid ML-KEM group"
        )
    }

    func testTheTrialIsConfiguredEnabled() {
        // WebRTC's `IsEnabled` reads the group name after the key; anything but "Enabled…" is off.
        XCTAssertEqual(WebRTCFieldTrials.configured, "WebRTC-EnableDtlsPqc/Enabled/")
    }
}
