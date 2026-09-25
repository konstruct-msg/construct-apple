//
//  PQXDHBundleConversionTests.swift
//  ConstructMessengerTests
//
//  The served bundle reaches the core through two conversions: the proto into
//  `PublicKeyBundleData` (`KeyServiceClient.bundleData`), and that into `BinaryKeyBundle`
//  (`PublicKeyBundleData.binaryKeyBundle`). Under PQXDH v2 the core refuses a session unless every
//  Kyber field it checks arrives — the key, its id, its signed `created_at`, both signatures, and
//  the hybrid identity with its binding. A field dropped in either conversion does not show up as a
//  wrong value; it shows up as `PQ_REQUIRED` for every peer. So these tests follow real keys from
//  one core, through both conversions, into another core's init.
//

import XCTest
@testable import Construct_Messenger

final class PQXDHBundleConversionTests: XCTestCase {

    private func freshCore(_ userId: String) throws -> OrchestratorCore {
        let keys = try createCryptoCore().exportPrivateKeys()
        return try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
    }

    /// The proto the key service would serve for `core`, with a Kyber one-time key.
    private func served(by core: OrchestratorCore) throws -> Shared_Proto_Services_V1_PreKeyBundle {
        let b = try core.pqxdhTestBundle(withOneTimeKey: true)
        var p = Shared_Proto_Services_V1_PreKeyBundle()
        p.identityKey = Data(b.identityPublic)
        p.signedPreKey = Data(b.signedPrekeyPublic)
        p.signedPreKeySignature = Data(b.signature)
        p.cryptoSuite = .classicX25519Chacha20
        p.spkUploadedAt = Int64(b.spkUploadedAt)
        p.spkRotationEpoch = b.spkRotationEpoch
        p.kyberSpkUploadedAt = Int64(b.kyberSpkUploadedAt)
        p.kyberSpkRotationEpoch = b.kyberSpkRotationEpoch
        p.kyberPreKey = Data(try XCTUnwrap(b.kyberPreKeyPublic))
        p.kyberPreKeyID = try XCTUnwrap(b.kyberPreKeyId)
        p.kyberPreKeySignature = Data(try XCTUnwrap(b.kyberPreKeySignature))
        p.kyberPreKeyCreatedAt = try XCTUnwrap(b.kyberPreKeyCreatedAt)
        p.kyberPreKeyHybridSignature = Data(try XCTUnwrap(b.kyberPreKeyHybridSignature))
        p.kyberOneTimePreKey = Data(try XCTUnwrap(b.kyberOneTimePrekeyPublic))
        p.kyberOneTimePreKeyID = try XCTUnwrap(b.kyberOneTimePrekeyId)
        p.kyberOneTimePreKeySignature = Data(try XCTUnwrap(b.kyberOneTimePrekeySignature))
        p.kyberOneTimePreKeyCreatedAt = try XCTUnwrap(b.kyberOneTimePrekeyCreatedAt)
        p.kyberOneTimePreKeyHybridSignature = Data(try XCTUnwrap(b.kyberOneTimePrekeyHybridSignature))
        p.hybridIdentityKey = Data(try XCTUnwrap(b.hybridIdentityKey))
        p.hybridIdentitySignature = Data(try XCTUnwrap(b.hybridIdentitySignature))
        return p
    }

    /// Every PQXDH v2 field survives both conversions, byte for byte.
    func testBothConversionsCarryEveryKyberField() throws {
        let bob = try freshCore("bob-\(UUID().uuidString)")
        let proto = try served(by: bob)
        let vk = Data(try bob.getRegistrationBundleFields().verifyingKey)

        let data = KeyServiceClient.bundleData(proto, userId: "bob", verifyingKey: vk)
        let binary = data.binaryKeyBundle()

        XCTAssertEqual(binary.kyberPreKeyPublic.map { Data($0) }, proto.kyberPreKey)
        XCTAssertEqual(binary.kyberPreKeyId, proto.kyberPreKeyID)
        XCTAssertEqual(binary.kyberPreKeyCreatedAt, proto.kyberPreKeyCreatedAt)
        XCTAssertEqual(binary.kyberPreKeySignature.map { Data($0) }, proto.kyberPreKeySignature)
        XCTAssertEqual(binary.kyberPreKeyHybridSignature.map { Data($0) }, proto.kyberPreKeyHybridSignature)
        XCTAssertEqual(binary.kyberOneTimePrekeyPublic.map { Data($0) }, proto.kyberOneTimePreKey)
        XCTAssertEqual(binary.kyberOneTimePrekeyId, proto.kyberOneTimePreKeyID)
        XCTAssertEqual(binary.kyberOneTimePrekeyCreatedAt, proto.kyberOneTimePreKeyCreatedAt)
        XCTAssertEqual(binary.kyberOneTimePrekeySignature.map { Data($0) }, proto.kyberOneTimePreKeySignature)
        XCTAssertEqual(binary.kyberOneTimePrekeyHybridSignature.map { Data($0) }, proto.kyberOneTimePreKeyHybridSignature)
        XCTAssertEqual(binary.hybridIdentityKey.map { Data($0) }, proto.hybridIdentityKey)
        XCTAssertEqual(binary.hybridIdentitySignature.map { Data($0) }, proto.hybridIdentitySignature)
        XCTAssertEqual(binary.verifyingKey, [UInt8](vk))
    }

    /// The same bundle opens a PQXDH v2 session end to end: the initiator through both
    /// conversions, the responder from the packed first message.
    func testAConvertedBundleOpensAV2Session() throws {
        let alice = try freshCore("alice-\(UUID().uuidString)")
        let bob = try freshCore("bob-\(UUID().uuidString)")
        let vk = Data(try bob.getRegistrationBundleFields().verifyingKey)
        let bundle = KeyServiceClient.bundleData(try served(by: bob), userId: "bob", verifyingKey: vk)

        _ = try alice.initSession(contactId: "bob", recipientBundle: bundle.binaryKeyBundle())
        let first = try alice.encryptMessage(contactId: "bob", plaintext: Data("hello".utf8))
        XCTAssertEqual(first.kemCiphertext.count, 1568, "the first message carries the ML-KEM-1024 ciphertext")
        XCTAssertEqual(first.kyberPrekeyId, bundle.kyberOneTimePreKeyId, "the one-time key is preferred")

        let result = try bob.pqxdhTestReceive(from: "alice", senderBundle: try alice.pqxdhTestBundle(), first: first)
        XCTAssertEqual(result.decryptedMessage, Array("hello".utf8))
        XCTAssertNotNil(result.kyberPrekeys, "the used one-time key was burned: the blob to persist comes back")
        XCTAssertEqual(alice.getSessionHealth(contactId: "bob")?.pqHandshake, .initialV2)
        XCTAssertEqual(bob.getSessionHealth(contactId: "alice")?.pqHandshake, .initialV2)
    }

    /// A 3-DH re-init drops the classic one-time key only; the Kyber one is a separate store.
    func testThreeDHReinitKeepsTheKyberOneTimeKey() throws {
        let bob = try freshCore("bob-\(UUID().uuidString)")
        var proto = try served(by: bob)
        proto.oneTimePreKey = Data(repeating: 0x11, count: 32)
        proto.oneTimePreKeyID = 1_000_001
        let data = KeyServiceClient.bundleData(proto, userId: "bob", verifyingKey: Data(repeating: 1, count: 32))

        let threeDH = data.binaryKeyBundle(withoutOneTimePrekey: true)
        XCTAssertNil(threeDH.oneTimePrekeyPublic)
        XCTAssertNil(threeDH.oneTimePrekeyId)
        XCTAssertNotNil(threeDH.kyberOneTimePrekeyPublic)
        XCTAssertEqual(data.binaryKeyBundle().oneTimePrekeyId, 1_000_001)
    }

    /// A bundle without the hybrid identity is refused before anything is created, and the app
    /// hears the reason as `peerNotPostQuantum` — not as a generic init failure.
    func testABundleWithoutTheHybridIdentityIsRefusedAsNotPostQuantum() throws {
        let bob = try freshCore("bob-\(UUID().uuidString)")
        var proto = try served(by: bob)
        proto.clearHybridIdentityKey()
        proto.clearHybridIdentitySignature()
        let vk = Data(try bob.getRegistrationBundleFields().verifyingKey)
        let data = KeyServiceClient.bundleData(proto, userId: "bob", verifyingKey: vk)
        XCTAssertNil(data.hybridIdentityKey, "an absent proto field reads as absent")

        let alice = try freshCore("alice-\(UUID().uuidString)")
        XCTAssertThrowsError(try CryptoSessionInitializationService().initializeSession(
            for: "bob",
            bundle: data,
            core: alice,
            archiveSession: { _, _ in XCTFail("nothing to archive") },
            archiveReplacedSession: { _, _, _ in XCTFail("nothing to archive") },
            saveSession: { _ in XCTFail("nothing was opened") }
        )) { error in
            guard case SessionError.peerNotPostQuantum? = error as? SessionError else {
                return XCTFail("expected peerNotPostQuantum, got \(error)")
            }
        }
        XCTAssertTrue(alice.getAllSessionContactIds().isEmpty, "the refusal leaves no session behind")
    }
}
