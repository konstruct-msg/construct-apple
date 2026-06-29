//
//  SessionControlCodecTests.swift
//  Construct MessengerTests
//
//  Covers the producer seam of the typed session-control migration (Phase 3 prep):
//  `SessionControlCodec.encodePayload` must be inert while `typedSessionControl` is OFF
//  (emit the exact legacy magic string) and emit a parseable `SessionControl` when ON.
//

import XCTest
@testable import Construct_Messenger

final class SessionControlCodecTests: XCTestCase {

    private var originalFlag: Bool!

    override func setUp() {
        super.setUp()
        originalFlag = FeatureFlags.typedSessionControl
    }

    override func tearDown() {
        FeatureFlags.typedSessionControl = originalFlag
        super.tearDown()
    }

    // MARK: - Flag OFF (Phase 2, default fleet state): legacy magic string, byte-identical

    func testEncodePayload_FlagOff_EmitsLegacyMagicString() {
        FeatureFlags.typedSessionControl = false
        let nonce = "ABC-123"

        for op in [SessionControlCodec.Op.ping, .ready, .resetInit] {
            let payload = SessionControlCodec.encodePayload(op: op, nonce: nonce)
            let decoded = String(data: payload, encoding: .utf8)
            XCTAssertEqual(decoded, SessionControlCodec.legacyString(op: op, nonce: nonce),
                           "flag-off payload must be the legacy string verbatim for \(op)")
        }
    }

    func testLegacyStringFormat_MatchesWireContract() {
        XCTAssertEqual(SessionControlCodec.legacyString(op: .ping, nonce: "N"), "__session_ping_N__")
        XCTAssertEqual(SessionControlCodec.legacyString(op: .ready, nonce: "N"), "__session_ready_N__")
        XCTAssertEqual(SessionControlCodec.legacyString(op: .resetInit, nonce: "N"), "__session_reset_init_N__")
    }

    /// The flag-off bytes the new producer emits must still be recognised by the consumer fallback,
    /// so a peer on an older (string-only) build keeps working.
    func testLegacyRoundTrip_ProducerToConsumerFallback() {
        FeatureFlags.typedSessionControl = false
        for op in [SessionControlCodec.Op.ping, .ready, .resetInit] {
            let payload = SessionControlCodec.encodePayload(op: op, nonce: UUID().uuidString)
            let text = String(data: payload, encoding: .utf8)!
            XCTAssertEqual(SessionControlCodec.legacyOp(plaintext: text), op,
                           "legacyOp must recognise the flag-off payload for \(op)")
        }
    }

    // MARK: - Flag ON (Phase 3): typed SessionControl payload, parseable, no magic string

    func testEncodePayload_FlagOn_EmitsParseableSessionControl() {
        FeatureFlags.typedSessionControl = true
        let nonce = UUID().uuidString

        for op in [SessionControlCodec.Op.ping, .ready, .resetInit] {
            let payload = SessionControlCodec.encodePayload(op: op, nonce: nonce)
            guard let control = SessionControlCodec.decode(payload) else {
                return XCTFail("flag-on payload must decode to a SessionControl for \(op)")
            }
            XCTAssertEqual(control.op, op)
            XCTAssertEqual(control.nonce, nonce)
            // The typed payload must NOT carry the legacy magic string.
            XCTAssertFalse(String(decoding: payload, as: UTF8.self).hasPrefix("__session_"),
                           "typed payload should not embed the legacy magic string for \(op)")
        }
    }
}
