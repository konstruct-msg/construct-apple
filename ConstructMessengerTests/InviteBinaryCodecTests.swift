//
//  InviteBinaryCodecTests.swift
//  ConstructMessengerTests
//
//  Compact binary invite encoding (F1) + v4 without ephKey (F2).
//

import XCTest
@testable import Construct_Messenger

final class InviteBinaryCodecTests: XCTestCase {

    private func sampleInviteV3(un: String? = "alice") -> InviteObject {
        let eph = Data(repeating: 0xAB, count: 32).base64EncodedString()
        let sig = Data(repeating: 0xCD, count: 64).base64EncodedString()
        return InviteObject(
            v: 3,
            jti: "550e8400-e29b-41d4-a716-446655440000",
            uuid: "14f28d31-1234-4abc-8def-0123456789ab",
            deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
            server: "konstruct.cc",
            ephKey: eph,
            ts: 1_738_156_800,
            sig: sig,
            un: un
        )
    }

    private func sampleInviteV4(un: String? = "alice") -> InviteObject {
        let sig = Data(repeating: 0xCD, count: 64).base64EncodedString()
        return InviteObject(
            v: 4,
            jti: "550e8400-e29b-41d4-a716-446655440000",
            uuid: "14f28d31-1234-4abc-8def-0123456789ab",
            deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
            server: "konstruct.cc",
            ephKey: "",
            ts: 1_738_156_800,
            sig: sig,
            un: un
        )
    }

    func testV4BinaryRoundTrip() throws {
        let original = sampleInviteV4()
        let binary = try original.encodeBinary()
        XCTAssertTrue(InviteObject.isCompactBinary(binary))
        let decoded = try InviteObject.decodeBinary(binary)
        XCTAssertEqual(decoded.v, 4)
        XCTAssertEqual(decoded.ephKey, "")
        XCTAssertEqual(decoded.un, "alice")
        XCTAssertEqual(decoded.canonicalString(), original.canonicalString())
        XCTAssertEqual(
            decoded.canonicalString(),
            "4|550e8400-e29b-41d4-a716-446655440000|14f28d31-1234-4abc-8def-0123456789ab|4e1f9dbe209c1bedb33ee32dda5a28f0|konstruct.cc|1738156800|alice"
        )
    }

    func testV4SmallerThanV3() throws {
        let v3 = try sampleInviteV3().encodeBinary()
        let v4 = try sampleInviteV4().encodeBinary()
        XCTAssertLessThan(v4.count, v3.count)
        XCTAssertEqual(v3.count - v4.count, 32, "v4 should drop exactly 32-byte ephKey")
    }

    func testV3BinaryRoundTripWithUsername() throws {
        let original = sampleInviteV3(un: "alice")
        let binary = try original.encodeBinary()
        let decoded = try InviteObject.decodeBinary(binary)
        XCTAssertEqual(decoded.v, 3)
        XCTAssertEqual(decoded.ephKey, original.ephKey)
        XCTAssertEqual(decoded.un, original.un)
    }

    func testV3BinaryRoundTripWithoutUsername() throws {
        let original = sampleInviteV3(un: nil)
        let decoded = try InviteObject.decodeBinary(try original.encodeBinary())
        XCTAssertNil(decoded.un)
    }

    func testBase64URLRoundTrip() throws {
        let original = sampleInviteV4()
        let encoded = try original.toBase64URL()
        XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        let decoded = try InviteObject.fromBase64(encoded)
        XCTAssertEqual(decoded.v, 4)
        XCTAssertEqual(decoded.uuid, original.uuid.lowercased())
    }

    func testLegacyJSONDualRead() throws {
        let original = sampleInviteV3()
        let jsonData = try JSONEncoder().encode(original)
        let decoded = try InviteObject.decodePayload(jsonData)
        XCTAssertEqual(decoded.jti.lowercased(), original.jti.lowercased())
    }

    func testLegacyStandardBase64JSONDualRead() throws {
        let original = sampleInviteV3()
        let jsonData = try JSONEncoder().encode(original)
        let legacy = jsonData.base64EncodedString()
        let decoded = try InviteObject.fromBase64(legacy)
        XCTAssertEqual(decoded.server, "konstruct.cc")
    }

    func testBinaryMuchSmallerThanJSON() throws {
        let original = sampleInviteV4()
        let binary = try original.encodeBinary()
        let json = try JSONEncoder().encode(original)
        XCTAssertLessThan(binary.count, json.count)
        XCTAssertLessThan(binary.count, 190, "Expected ~145–160B compact v4 invite, got \(binary.count)")
    }

    func testLatin1QRStringRecovery() throws {
        let original = sampleInviteV4()
        let binary = try original.encodeBinary()
        let latin1 = String(binary.map { Character(UnicodeScalar($0)) })
        let recovered = InviteBinaryCodec.dataFromLatin1QRString(latin1)
        XCTAssertEqual(recovered, binary)
        XCTAssertTrue(InviteObject.isCompactBinary(recovered!))
    }

    func testV4RejectsNonEmptyEphKey() {
        let sig = Data(repeating: 0xCD, count: 64).base64EncodedString()
        let bad = InviteObject(
            v: 4,
            jti: "550e8400-e29b-41d4-a716-446655440000",
            uuid: "14f28d31-1234-4abc-8def-0123456789ab",
            deviceId: "4e1f9dbe209c1bedb33ee32dda5a28f0",
            server: "konstruct.cc",
            ephKey: Data(repeating: 1, count: 32).base64EncodedString(),
            ts: 1_738_156_800,
            sig: sig,
            un: nil
        )
        XCTAssertThrowsError(try bad.validate())
    }
}
