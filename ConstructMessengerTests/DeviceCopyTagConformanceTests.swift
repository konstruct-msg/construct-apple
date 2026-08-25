//
//  DeviceCopyTagConformanceTests.swift
//  ConstructMessengerTests
//
//  The per-device copy tag is computed by the core. This asserts that what we get through the FFI
//  is what the cross-client vectors say — the same file every other client reads.
//

import XCTest
@testable import Construct_Messenger

/// Why vectors and not a round-trip.
///
/// A round-trip test — seal, open, assert they agree — passes for any construction, including one
/// that has silently drifted from every other client. The failure this mechanism actually has is
/// two implementations that each round-trip perfectly and disagree with each other, and its
/// symptom is not an error: a copy is discarded as foreign, a message never appears, and there is
/// no way to tell which side is wrong.
///
/// The values in `knst_device_copy_tag.json` were produced by the iOS CryptoKit implementation
/// **before** it was replaced by the core, so this file is also the proof that the port did not
/// change the wire.
final class DeviceCopyTagConformanceTests: XCTestCase {

    private struct Vector: Decodable {
        let name: String
        let ourPrivate: String
        let peerPublic: String
        let pairSecret: String?
        let baseMessageId: String?
        let targetDeviceId: String?
        let tag: String?

        enum CodingKeys: String, CodingKey {
            case name
            case ourPrivate = "our_private"
            case peerPublic = "peer_public"
            case pairSecret = "pair_secret"
            case baseMessageId = "base_message_id"
            case targetDeviceId = "target_device_id"
            case tag
        }
    }

    private struct Keys: Decodable {
        let aPrivate: String
        let aPublic: String
        let bPrivate: String
        let bPublic: String

        enum CodingKeys: String, CodingKey {
            case aPrivate = "a_private"
            case aPublic = "a_public"
            case bPrivate = "b_private"
            case bPublic = "b_public"
        }
    }

    private struct Vectors: Decodable {
        let keys: Keys
        let vectors: [Vector]
    }

    /// Located from this file rather than a bundle resource — adding a resource to the test target
    /// is a project-file change, and the fixture is vendored in the repo.
    private func loadVectors() throws -> Vectors {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance")
            .appendingPathComponent("knst_device_copy_tag.json")
        let loaded = try JSONDecoder().decode(Vectors.self, from: try Data(contentsOf: url))
        // An empty list would make every loop below vacuous, which is the failure mode the whole
        // exercise exists to avoid.
        XCTAssertGreaterThanOrEqual(loaded.vectors.count, 3, "vectors look truncated")
        return loaded
    }

    private func bytes(_ hex: String) throws -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else {
                throw XCTSkip("bad hex in vectors: \(hex)")
            }
            out.append(b)
            i = j
        }
        return out
    }

    // MARK: - The wire contract

    /// Mutation: change the HKDF salt or drop the NUL from the MAC input in the core — this reddens.
    func testTagMatchesTheCrossClientVectors() throws {
        let loaded = try loadVectors()
        var checked = 0
        for v in loaded.vectors {
            guard let base = v.baseMessageId, let target = v.targetDeviceId, let expected = v.tag else {
                continue
            }
            let produced = try deviceCopyTag(
                baseMessageId: base,
                targetDeviceId: target,
                ourIdentityPrivate: try bytes(v.ourPrivate),
                peerIdentityPublic: try bytes(v.peerPublic)
            )
            XCTAssertEqual(produced, expected, "vector '\(v.name)' — this is a wire change")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no tag vectors exercised — the loop passed by being empty")
    }

    /// The tag names the device a copy is **for**, so the same message to two devices differs.
    ///
    /// Without this the pair secret alone would key it, and since X25519 is symmetric a device
    /// would read its own echo — which delivery hands back to it — as addressed to itself.
    func testTagIsDirectional() throws {
        let k = try loadVectors().keys
        let forB = try deviceCopyTag(
            baseMessageId: "m", targetDeviceId: "device-b",
            ourIdentityPrivate: try bytes(k.aPrivate), peerIdentityPublic: try bytes(k.bPublic)
        )
        let forA = try deviceCopyTag(
            baseMessageId: "m", targetDeviceId: "device-a",
            ourIdentityPrivate: try bytes(k.aPrivate), peerIdentityPublic: try bytes(k.bPublic)
        )
        XCTAssertNotEqual(forA, forB)
    }

    /// A copy A addresses to B: foreign on A, ours on B. Both sides derive the same pair secret
    /// from opposite halves, which is the property that lets the receiver check without asking.
    func testACopyForBIsForeignOnAAndOursOnB() throws {
        let k = try loadVectors().keys
        let tag = try deviceCopyTag(
            baseMessageId: "m", targetDeviceId: "device-b",
            ourIdentityPrivate: try bytes(k.aPrivate), peerIdentityPublic: try bytes(k.bPublic)
        )
        XCTAssertTrue(deviceCopyTagMatches(
            tag: tag, baseMessageId: "m", ourDeviceId: "device-b",
            ourIdentityPrivate: try bytes(k.bPrivate), peerIdentityPublic: try bytes(k.aPublic)
        ))
        XCTAssertFalse(deviceCopyTagMatches(
            tag: tag, baseMessageId: "m", ourDeviceId: "device-a",
            ourIdentityPrivate: try bytes(k.aPrivate), peerIdentityPublic: try bytes(k.bPublic)
        ))
    }

    /// Every chunk of one message carries one tag, so a receiver can recompute it from whichever
    /// chunk arrives first. The sender MACs the base id for exactly this reason.
    func testTagDependsOnTheBaseIdNotTheChunkId() throws {
        let k = try loadVectors().keys
        let one = try deviceCopyTag(
            baseMessageId: "m", targetDeviceId: "d",
            ourIdentityPrivate: try bytes(k.aPrivate), peerIdentityPublic: try bytes(k.bPublic)
        )
        let two = try deviceCopyTag(
            baseMessageId: "m-c3", targetDeviceId: "d",
            ourIdentityPrivate: try bytes(k.aPrivate), peerIdentityPublic: try bytes(k.bPublic)
        )
        XCTAssertNotEqual(one, two, "a chunk suffix must never reach the MAC input")
    }

    // MARK: - The Swift seam

    /// `SenderSyncDeviceTag` holds no cryptography any more; it must forward unchanged.
    ///
    /// Mutation: have the shim swap `ourDeviceId` and `targetDeviceId` — this reddens while the
    /// core's own tests stay green, which is the whole reason the seam is tested separately.
    func testTheSwiftSeamForwardsWithoutAlteringAnything() throws {
        let k = try loadVectors().keys
        let viaCore = try deviceCopyTag(
            baseMessageId: "m", targetDeviceId: "device-b",
            ourIdentityPrivate: try bytes(k.aPrivate), peerIdentityPublic: try bytes(k.bPublic)
        )
        let viaSeam = SenderSyncDeviceTag.tag(
            baseMessageId: "m",
            targetDeviceId: "device-b",
            ourIdentityPrivateKey: Data(try bytes(k.aPrivate)),
            peerIdentityPublicKey: Data(try bytes(k.bPublic))
        )
        XCTAssertEqual(viaSeam, viaCore)
    }

    /// Unusable key material is "not foreign", never a throw that reaches the routing path.
    ///
    /// Callers ask "is this copy for another of my devices?", and the answer to an undecidable
    /// question there must be no: wrongly opening a copy costs failed decrypts, wrongly discarding
    /// one loses a message from the transcript, silently.
    func testUnusableKeyMaterialDoesNotMatchAndDoesNotThrow() throws {
        let k = try loadVectors().keys
        XCTAssertNil(SenderSyncDeviceTag.tag(
            baseMessageId: "m",
            targetDeviceId: "d",
            ourIdentityPrivateKey: Data(repeating: 0, count: 31),
            peerIdentityPublicKey: Data(try bytes(k.bPublic))
        ))
        XCTAssertFalse(SenderSyncDeviceTag.matches(
            "0123456789abcdef",
            baseMessageId: "m",
            ourDeviceId: "d",
            ourIdentityPrivateKey: Data(repeating: 0, count: 31),
            peerIdentityPublicKey: Data(try bytes(k.bPublic))
        ))
    }
}
