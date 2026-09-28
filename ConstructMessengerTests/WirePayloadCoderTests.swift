//
//  WirePayloadCoderTests.swift
//  ConstructMessengerTests
//
//  Tests for WirePayloadCoder — the Swift adapter over the Rust core's wire reader
//  (`wirePayloadUnpack`, backed by construct-core/wire_payload.rs).
//
//  The byte layout is owned and unit-tested in the Rust core. This app no longer packs payloads
//  (`encryptToWire` returns them whole since 2026-09-28), so what is left to test here is the
//  reader: that it reads a payload the core packed, and honours the core's reject contract.
//

import XCTest
@testable import Construct_Messenger

final class WirePayloadCoderTests: XCTestCase {

    /// A first flight as the core packs it: the header fields come back as the core wrote them,
    /// and the sealed box is the tail of the payload.
    func testDecodeReadsWhatTheCorePacked() throws {
        let (alice, _) = try makeTestDevice()
        let (bob, bobId) = try makeTestDevice()
        _ = try alice.initSession(contactId: bobId, recipientBundle: try bob.pqxdhTestBundle())
        let wire = try alice.encryptToWire(contactId: bobId, plaintext: Data("hello".utf8))

        let decoded = try WirePayloadCoder.decode(wire)
        XCTAssertEqual(decoded.messageNumber, 0)
        XCTAssertEqual(decoded.ephemeralPublicKey.count, 32)
        XCTAssertEqual(decoded.kemCiphertext?.count, 1568, "the first flight carries the handshake")
        XCTAssertEqual(decoded.content, wire.suffix(decoded.content.count), "the sealed box ends the payload")
    }

    // MARK: - Decode Errors

    func testDecodeRejectsTooShortPayload() {
        // Payload <= headerSize (52) → the core rejects it (TooShort → thrown CryptoError).
        let shortPayload = Data(repeating: 0, count: 10)
        XCTAssertThrowsError(try WirePayloadCoder.decode(shortPayload))
    }

    func testDecodeRejectsExactlyHeaderSizePayload() {
        let payload = Data(repeating: 0, count: WirePayloadCoder.headerSize)
        XCTAssertThrowsError(try WirePayloadCoder.decode(payload))
    }

    func testDecodeAcceptsMinimalValidPayload() throws {
        var payload = Data(repeating: 0, count: WirePayloadCoder.headerSize + 1)
        for i in 4..<36 { payload[i] = UInt8(i) }
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.messageNumber, 0)
        XCTAssertEqual(decoded.ephemeralPublicKey.count, 32)
    }
}
