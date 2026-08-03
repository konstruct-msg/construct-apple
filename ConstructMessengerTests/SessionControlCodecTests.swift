//
//  SessionControlCodecTests.swift
//  Construct MessengerTests
//
//  The producer seam of session control. This suite used to be built entirely around
//  `binarySessionControlPayload`: three of its four tests asserted that flipping the flag OFF
//  produced the legacy `__session_ping_<nonce>__` magic string, and that the string parser
//  recognised it again.
//
//  Both went away on 2026-08-03. The type now travels in KNST byte 5, the string parser is gone,
//  and a flag whose OFF position emits payloads no peer can read is not an escape hatch. What is
//  left worth pinning is that the payload is one binary shape, that it carries no magic string,
//  and that the nonce survives — the nonce is the only thing a consumer opens this payload for.
//

import XCTest
@testable import Construct_Messenger

final class SessionControlCodecTests: XCTestCase {

    /// One wire form, always: a parseable `SessionControl`. There is no second branch to test.
    func testEncodePayloadEmitsParseableSessionControl() throws {
        let nonce = UUID().uuidString

        for op in [SessionControlCodec.Op.ping, .ready, .resetInit] {
            let payload = SessionControlCodec.encodePayload(op: op, nonce: nonce)
            let control = try XCTUnwrap(SessionControlCodec.decode(payload),
                                        "payload must decode to a SessionControl for \(op)")
            XCTAssertEqual(control.op, op)
            XCTAssertEqual(control.nonce, nonce, "the nonce is the only field a consumer reads")
        }
    }

    /// No magic string may creep back into the payload. It was the second representation of the
    /// op, and a producer that emits it again would be emitting something nothing parses.
    func testPayloadCarriesNoMagicString() {
        for op in [SessionControlCodec.Op.ping, .ready, .resetInit] {
            let text = String(decoding: SessionControlCodec.encodePayload(op: op, nonce: "N"), as: UTF8.self)
            XCTAssertFalse(text.contains("__session_"),
                           "the legacy magic string must not come back for \(op)")
        }
    }

    /// END_SESSION keeps its marker, and it must stay recognisable: it is the one control payload
    /// with no ciphertext to hold a frame, so the string is the only thing identifying it.
    func testEndSessionMarkerStillRecognised() {
        XCTAssertTrue(SessionControlCodec.isEndSessionMarker(Data("__END_SESSION__".utf8)))
        XCTAssertTrue(SessionControlCodec.isEndSessionMarker(Data("__END_SESSION__trailing".utf8)))
        XCTAssertFalse(SessionControlCodec.isEndSessionMarker(Data("__session_ping_N__".utf8)),
                       "a retired control string must not be mistaken for END_SESSION")
        XCTAssertFalse(SessionControlCodec.isEndSessionMarker(Data("hello".utf8)))
    }

    /// The content-type table and the op enum must agree in both directions, since routing now
    /// crosses between them (frame byte → op → handler).
    func testContentTypeTableRoundTrips() {
        XCTAssertEqual(SessionControlCodec.op(forContentType: 25), .ping)
        XCTAssertEqual(SessionControlCodec.op(forContentType: 26), .ready)
        XCTAssertEqual(SessionControlCodec.op(forContentType: 24), .resetInit)
        XCTAssertEqual(SessionControlCodec.op(forContentType: 21), .end)
        XCTAssertNil(SessionControlCodec.op(forContentType: 1), "a regular body is not a control op")
        XCTAssertNil(SessionControlCodec.op(forContentType: 0))
    }
}
