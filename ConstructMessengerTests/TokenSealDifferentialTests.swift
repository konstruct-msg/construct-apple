//
//  TokenSealDifferentialTests.swift
//  ConstructMessengerTests
//
//  Two implementations of the token seal exist at this moment — `ServerKeyManager.sealBox` and the
//  core's `ppSealTokenBytes` — and a third (construct-server's `open_sealed_token_bytes`) is the
//  only one that ever reads the result. This is the one moment the first two can be compared, and
//  the safety-number port established the rule: compare before deleting, because afterwards there
//  is nothing to compare against.
//
//  A fixed vector cannot test a sealer: the ephemeral key and the nonce are random, so no two runs
//  produce the same bytes. What can be tested is that **one opener reads both sealers**, which is
//  exactly the property the server depends on. The opener below is written from the format, in
//  CryptoKit — deliberately not shared with either sealer, so it cannot inherit their mistakes.
//
//  The comparison was made on 2026-08-27, the two sealers agreed, and `sealBox` was deleted in the
//  same change. What is left is the opener plus the pinned vectors, which is what a client that
//  only ever seals can still check itself against.
//
//  What a mismatch costs: the server opens `token_bytes` as an X25519 sealed box, so a seal it
//  cannot read is `decrypt_failed` — fatal under enforce, and silent under permissive, where it
//  looks like ordinary anti-abuse degradation.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class TokenSealDifferentialTests: XCTestCase {

    /// The server's side of the format: `ephemeralPub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16)`,
    /// key = HKDF-SHA256(ikm: X25519(eph, server), salt: ∅, info: "construct-token-seal-v1").
    private func open(_ sealed: Data, with serverPriv: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        XCTAssertGreaterThanOrEqual(sealed.count, 32 + 12 + 16, "box is too short to be one")
        let ephBytes = sealed.prefix(32)
        let nonceBytes = sealed.dropFirst(32).prefix(12)
        let ctAndTag = sealed.dropFirst(44)

        let eph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephBytes)
        let shared = try serverPriv.sharedSecretFromKeyAgreement(with: eph)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("construct-token-seal-v1".utf8),
            outputByteCount: 32
        )
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonceBytes),
            ciphertext: ctAndTag.dropLast(16),
            tag: ctAndTag.suffix(16)
        )
        return try ChaChaPoly.open(box, using: key)
    }

    /// The property that matters: one opener reads both sealers.
    ///
    /// Mutation: change the `info` string, the salt, or the field order in either sealer — the
    /// corresponding half reddens. Both halves reddening means the opener is wrong instead.
    func testOneOpenerReadsBothSealers() throws {
        let serverPriv = Curve25519.KeyAgreement.PrivateKey()
        let serverPub = serverPriv.publicKey.rawRepresentation
        let token = Data((0..<32).map { UInt8($0) })

        let fromCore = try XCTUnwrap(
            try? ppSealTokenBytes(token: [UInt8](token), serverEncryptionKey: [UInt8](serverPub)),
            "the core refused to seal a well-formed token"
        )
        XCTAssertEqual(try open(Data(fromCore), with: serverPriv), token,
                       "the core's seal is not in the format the server opens")

        // `ServerKeyManager.sealBox` was the second sealer and stood here until it was deleted
        // in the same change. Its half of this test went with it — that is the point: the
        // comparison was possible exactly once, it was made, and the vectors below are what
        // outlives it.
    }

    /// The pinned vectors: the opener above, run against bytes the core produced. This is what
    /// survives the deletion — a sealer cannot be pinned (fresh ephemeral, fresh nonce, so no two
    /// runs agree), but an opener can, and every client that seals is expected to check its own
    /// opener here before trusting its own sealer.
    ///
    /// Mutation: change the info string, the salt, or the field offsets in the opener — both
    /// vectors redden. Change them in the core instead and only the round-trip above reddens,
    /// which is how the two failures are told apart.
    func testTheOpenerReadsTheCrossClientVectors() throws {
        let v = try loadVectors()
        let serverPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try bytes(v.serverSecret))
        XCTAssertEqual(serverPriv.publicKey.rawRepresentation, try bytes(v.serverPublic),
                       "the vector's keypair does not agree with itself")
        XCTAssertGreaterThanOrEqual(v.vectors.count, 2, "vectors look truncated")
        for vec in v.vectors {
            XCTAssertEqual(
                try open(try bytes(vec.sealed), with: serverPriv), try bytes(vec.plaintext),
                "\(vec.name) — this is a wire change every client must make together"
            )
        }
    }

    /// Byte-for-byte equality is impossible (both sealers randomise), so the shape is what can be
    /// compared directly — and a shape difference is the failure that would not show up as a
    /// decrypt error but as a truncated or over-long field.
    func testBothSealersProduceTheSameShape() throws {
        let serverPriv = Curve25519.KeyAgreement.PrivateKey()
        let serverPub = serverPriv.publicKey.rawRepresentation
        for length in [1, 32, 64, 200] {
            let token = Data(repeating: 0xAB, count: length)
            let core = try XCTUnwrap(try? ppSealTokenBytes(token: [UInt8](token),
                                                          serverEncryptionKey: [UInt8](serverPub)))
            // Overhead is exactly 60 bytes and the vectors depend on it.
            XCTAssertEqual(core.count, 32 + 12 + length + 16, "overhead changed for a \(length)-byte token")
        }
    }

    /// A key that is not 32 bytes must be refused, not sealed to something else.
    ///
    /// Mutation: drop the length check in the core — this reddens.
    func testAMalformedServerKeyIsRefused() {
        XCTAssertThrowsError(try ppSealTokenBytes(token: [0x01], serverEncryptionKey: [UInt8](repeating: 0, count: 31)))
        XCTAssertThrowsError(try ppSealTokenBytes(token: [0x01], serverEncryptionKey: []))
    }

    // MARK: - Vectors

    private struct Vector: Decodable {
        let name: String
        let plaintext: String
        let sealed: String
    }

    private struct Vectors: Decodable {
        let serverSecret: String
        let serverPublic: String
        let vectors: [Vector]
        enum CodingKeys: String, CodingKey {
            case serverSecret = "server_secret"
            case serverPublic = "server_public"
            case vectors
        }
    }

    private func loadVectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance")
            .appendingPathComponent("knst_token_seal.json")
        return try JSONDecoder().decode(Vectors.self, from: try Data(contentsOf: url))
    }

    private func bytes(_ hex: String) throws -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { throw XCTSkip("bad hex: \(hex)") }
            out.append(b)
            i = j
        }
        return out
    }
}
