//
//  WirePayloadCoderTests.swift
//  ConstructMessengerTests
//
//  Tests for WirePayloadCoder — the binary wire format encoder/decoder.
//
//  Wire format:
//    [4 bytes LE]  message_number
//    [32 bytes]    dh_public_key
//    [12+ bytes]   nonce || ciphertext || auth_tag
//

import XCTest
@testable import Construct_Messenger

final class WirePayloadCoderTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal valid sealed box: 12-byte nonce + 16-byte auth tag (no plaintext)
    private static let minSealedBox = Data(repeating: 0xAB, count: 28)

    /// Standard sealed box: 12 nonce + 32 ciphertext + 16 tag
    private static let sealedBox = Data(repeating: 0x42, count: 60)

    private static let dhPubKey = Data((0..<32).map { UInt8($0) })

    private func makeComponents(
        dhPub: Data = dhPubKey,
        msgNum: UInt32 = 7,
        sealedBox: Data = sealedBox
    ) -> MessageCryptoService.EncryptedMessageComponents {
        return MessageCryptoService.EncryptedMessageComponents(
            ephemeralPublicKey: dhPub,
            messageNumber: msgNum,
            content: sealedBox,
            suiteId: 1,
            oneTimePreKeyId: 0,
            storageKey: Data()
        )
    }

    // MARK: - Encode → Decode Roundtrip

    func testRoundtripPreservesMessageNumber() throws {
        let components = makeComponents(msgNum: 42)
        let payload = try WirePayloadCoder.encode(components)
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.messageNumber, 42)
    }

    func testRoundtripPreservesDHPublicKey() throws {
        let components = makeComponents()
        let payload = try WirePayloadCoder.encode(components)
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.ephemeralPublicKey, [UInt8](Self.dhPubKey))
    }

    func testRoundtripPreservesContent() throws {
        let components = makeComponents()
        let payload = try WirePayloadCoder.encode(components)
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.content, Self.sealedBox)
    }

    func testRoundtripWithMessageNumberZero() throws {
        let components = makeComponents(msgNum: 0)
        let payload = try WirePayloadCoder.encode(components)
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.messageNumber, 0)
    }

    func testRoundtripWithMaxMessageNumber() throws {
        let components = makeComponents(msgNum: UInt32.max)
        let payload = try WirePayloadCoder.encode(components)
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.messageNumber, UInt32.max)
    }

    func testRoundtripWithMinSealedBox() throws {
        let components = makeComponents(sealedBox: Self.minSealedBox)
        let payload = try WirePayloadCoder.encode(components)
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.content, Self.minSealedBox)
    }

    // MARK: - Payload Structure

    func testPayloadSize() throws {
        let components = makeComponents()
        let payload = try WirePayloadCoder.encode(components)
        // Header (36) + sealed box bytes
        XCTAssertEqual(payload.count, WirePayloadCoder.headerSize + Self.sealedBox.count)
    }

    func testMessageNumberIsLittleEndian() throws {
        // Encode message_number = 1 and verify the raw bytes
        let components = makeComponents(msgNum: 1)
        let payload = try WirePayloadCoder.encode(components)
        let bytes = [UInt8](payload)
        XCTAssertEqual(bytes[0], 0x01)  // LE: least significant byte first
        XCTAssertEqual(bytes[1], 0x00)
        XCTAssertEqual(bytes[2], 0x00)
        XCTAssertEqual(bytes[3], 0x00)
    }

    func testMessageNumberLittleEndian256() throws {
        let components = makeComponents(msgNum: 256)
        let payload = try WirePayloadCoder.encode(components)
        let bytes = [UInt8](payload)
        XCTAssertEqual(bytes[0], 0x00)
        XCTAssertEqual(bytes[1], 0x01)  // 256 = 0x0100 in LE
        XCTAssertEqual(bytes[2], 0x00)
        XCTAssertEqual(bytes[3], 0x00)
    }

    func testDHPublicKeyAtOffset4() throws {
        let components = makeComponents()
        let payload = try WirePayloadCoder.encode(components)
        let dhBytes = [UInt8](payload[4..<36])
        XCTAssertEqual(dhBytes, [UInt8](Self.dhPubKey))
    }

    func testSealedBoxStartsAtHeaderSize() throws {
        let components = makeComponents()
        let payload = try WirePayloadCoder.encode(components)
        let sealedBytes = Data(payload[WirePayloadCoder.headerSize...])
        XCTAssertEqual(sealedBytes, Self.sealedBox)
    }

    // MARK: - Encode Errors

    func testEncodeRejectsShortDHPublicKey() {
        let components = MessageCryptoService.EncryptedMessageComponents(
            ephemeralPublicKey: Data(repeating: 0, count: 16),  // too short
            messageNumber: 0,
            content: Self.sealedBox,
            suiteId: 1,
            oneTimePreKeyId: 0,
            storageKey: Data()
        )
        XCTAssertThrowsError(try WirePayloadCoder.encode(components)) { error in
            XCTAssertEqual(error as? WirePayloadError, .invalidDHPublicKey)
        }
    }

    func testEncodeRejectsLongDHPublicKey() {
        let components = MessageCryptoService.EncryptedMessageComponents(
            ephemeralPublicKey: Data(repeating: 0, count: 64),  // too long
            messageNumber: 0,
            content: Self.sealedBox,
            suiteId: 1,
            oneTimePreKeyId: 0,
            storageKey: Data()
        )
        XCTAssertThrowsError(try WirePayloadCoder.encode(components)) { error in
            XCTAssertEqual(error as? WirePayloadError, .invalidDHPublicKey)
        }
    }

    // MARK: - Decode Errors

    func testDecodeRejectsTooShortPayload() {
        // Payload < 37 bytes (headerSize + 1 minimum content byte)
        let shortPayload = Data(repeating: 0, count: 10)
        XCTAssertThrowsError(try WirePayloadCoder.decode(shortPayload)) { error in
            if case WirePayloadError.payloadTooShort(_) = error { } else {
                XCTFail("Expected payloadTooShort, got \(error)")
            }
        }
    }

    func testDecodeRejectsExactlyHeaderSizePayload() {
        // Exactly 36 bytes — no content at all
        let payload = Data(repeating: 0, count: WirePayloadCoder.headerSize)
        XCTAssertThrowsError(try WirePayloadCoder.decode(payload))
    }

    func testDecodeAcceptsMinimalValidPayload() throws {
        // 36 bytes header + 1 byte content = 37 bytes minimum
        var payload = Data(repeating: 0, count: WirePayloadCoder.headerSize + 1)
        // Set dh_public_key bytes (offset 4..36)
        for i in 4..<36 { payload[i] = UInt8(i) }
        let decoded = try WirePayloadCoder.decode(payload)
        XCTAssertEqual(decoded.messageNumber, 0)
        XCTAssertEqual(decoded.ephemeralPublicKey.count, 32)
    }

    // MARK: - Multiple Roundtrips (different message numbers)

    func testMultipleRoundtrips() throws {
        for msgNum: UInt32 in [0, 1, 100, 1000, 65535, UInt32.max / 2] {
            let components = makeComponents(msgNum: msgNum)
            let payload = try WirePayloadCoder.encode(components)
            let decoded = try WirePayloadCoder.decode(payload)
            XCTAssertEqual(decoded.messageNumber, msgNum, "Roundtrip failed for msgNum=\(msgNum)")
        }
    }
}
