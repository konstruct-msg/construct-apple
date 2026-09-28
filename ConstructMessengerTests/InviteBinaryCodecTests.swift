//
//  InviteBinaryCodecTests.swift
//  ConstructMessengerTests
//
//  The v5 invite against `knst_invite.json` — the file construct-protos, construct-server and
//  Android are held to as well. Three implementations build the canonical string and the CIv1
//  bytes independently, and a disagreement surfaces only at redeem, as "invalid signature".
//

import XCTest
@testable import Construct_Messenger

final class InviteBinaryCodecTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Fields: Decodable {
            let v: Int
            let jti: String
            let uuid: String
            let device_id: String
            let server: String
            let ts: Int
            let ttl: UInt32
            let addr: String
            let un: String?
        }
        struct Valid: Decodable {
            let name: String
            let fields: Fields
            let verifying_key: String
            let canonical: String
            let signature: String
            let binary: String
        }
        struct Refused: Decodable {
            let name: String
            let why: String
            let binary: String
        }
        let valid: [Valid]
        let refused: [Refused]
    }

    private func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_invite.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func hex(_ string: String) throws -> Data {
        try XCTUnwrap(InviteBinaryCodec.data(hex: string), "not hex: \(string)")
    }

    private func invite(_ v: Vectors.Valid) throws -> InviteObject {
        InviteObject(
            v: v.fields.v,
            jti: v.fields.jti,
            uuid: v.fields.uuid,
            deviceId: v.fields.device_id,
            server: v.fields.server,
            ts: v.fields.ts,
            sig: try hex(v.signature).base64EncodedString(),
            un: v.fields.un,
            ttl: v.fields.ttl,
            addr: try hex(v.fields.addr)
        )
    }

    /// The vector's `ts` is fixed in the past, and `validate()` refuses nothing for age — expiry
    /// is a separate check — so the fixtures stay valid forever.
    func testTheCanonicalStringMatchesTheVector() throws {
        for v in try vectors().valid {
            XCTAssertEqual(try invite(v).canonicalString(), v.canonical, v.name)
        }
    }

    func testTheBinaryMatchesTheVector() throws {
        for v in try vectors().valid {
            XCTAssertEqual(try invite(v).encodeBinary(), try hex(v.binary), v.name)
            XCTAssertEqual(try InviteObject.decodeBinary(try hex(v.binary)), try invite(v), v.name)
        }
    }

    /// The core's verifier accepts the vector's signature over the canonical string — the same
    /// call `InviteVerifier` makes on redeem.
    func testTheVectorSignatureVerifies() throws {
        for v in try vectors().valid {
            XCTAssertTrue(
                try verifyInviteSignature(
                    data: v.canonical,
                    signature: [UInt8](try hex(v.signature)),
                    verifyingKey: [UInt8](try hex(v.verifying_key))
                ),
                v.name
            )
        }
    }

    func testRefusedBlobsDoNotDecode() throws {
        let refused = try vectors().refused
        XCTAssertFalse(refused.isEmpty)
        for r in refused {
            XCTAssertThrowsError(try InviteObject.decodeBinary(try hex(r.binary)), "\(r.name): \(r.why)")
        }
    }

    func testBase64URLRoundTrip() throws {
        let original = try invite(try vectors().valid[0])
        let encoded = try original.toBase64URL()
        XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(try InviteObject.fromBase64(encoded), original)
    }

    /// A QR's capacity is what this layout is fitted to. v5 with an address is 32 bytes over the
    /// old v4 — still well inside the byte-mode budget the scanner reads reliably.
    func testTheBinaryStaysSmall() throws {
        let binary = try invite(try vectors().valid[0]).encodeBinary()
        XCTAssertLessThan(binary.count, 230, "got \(binary.count) bytes")
    }

    func testLatin1QRStringRecovery() throws {
        let binary = try invite(try vectors().valid[0]).encodeBinary()
        let latin1 = String(binary.map { Character(UnicodeScalar($0)) })
        let recovered = InviteBinaryCodec.dataFromLatin1QRString(latin1)
        XCTAssertEqual(recovered, binary)
        XCTAssertTrue(InviteObject.isCompactBinary(try XCTUnwrap(recovered)))
    }
}
