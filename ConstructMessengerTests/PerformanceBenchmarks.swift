//
//  PerformanceBenchmarks.swift
//  ConstructMessengerTests
//
//  XCTest measure{} benchmarks for the Construct message pipeline.
//  These run as part of the normal test suite and print baseline timing
//  to the test log. Use "Performance" filter in the Xcode test navigator
//  to view historical regressions.
//
//  Run from command line:
//    xcodebuild test -scheme ConstructMessenger \
//      -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
//      -only-testing ConstructMessengerTests/PerformanceBenchmarks
//

import XCTest
@testable import Construct_Messenger

final class PerformanceBenchmarks: XCTestCase {

    // MARK: - Helpers

    /// Reusable crypto peer backed by OrchestratorCore.
    private class CryptoPeer {
        let core: OrchestratorCore
        let userId: String

        init(userId: String) throws {
            self.userId = userId
            let bootstrap = try createCryptoCore()
            let keys = try bootstrap.exportPrivateKeys()
            self.core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
        }

        func bundle() throws -> [UInt8] {
            let json = try core.exportRegistrationBundleJson()
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = dict["identityPublic"] as? String,
                  let sp = dict["signedPrekeyPublic"] as? String,
                  let sig = dict["signature"] as? String,
                  let vk = dict["verifyingKey"] as? String,
                  let sid = dict["suiteId"] as? String,
                  let ipData = Data(base64Encoded: ip),
                  let spData = Data(base64Encoded: sp),
                  let sigData = Data(base64Encoded: sig),
                  let vkData = Data(base64Encoded: vk),
                  let sidVal = UInt16(sid) else {
                throw NSError(domain: "Bench", code: 1)
            }
            let dict2: [String: Any] = [
                "identity_public": [UInt8](ipData),
                "signed_prekey_public": [UInt8](spData),
                "signature": [UInt8](sigData),
                "verifying_key": [UInt8](vkData),
                "suite_id": sidVal,
            ]
            return [UInt8](try JSONSerialization.data(withJSONObject: dict2))
        }

        func initSenderSession(to contactId: String, bundleBytes: [UInt8]) throws {
            _ = try core.initSession(contactId: contactId, recipientBundle: bundleBytes)
        }
    }

    // MARK: - Wire Payload Encode/Decode

    func testWirePayloadEncodePerformance() throws {
        let sealedBox = Data(repeating: 0x42, count: 60)
        let epk = Data((0..<32).map { UInt8($0) })
        let components = MessageCryptoService.EncryptedMessageComponents(
            ephemeralPublicKey: epk,
            messageNumber: 0,
            content: sealedBox,
            suiteId: 1,
            oneTimePreKeyId: 0,
            storageKey: Data()
        )
        measure {
            for _ in 0..<1000 {
                _ = try? WirePayloadCoder.encode(components)
            }
        }
    }

    func testWirePayloadDecodePerformance() throws {
        let sealedBox = Data(repeating: 0x42, count: 60)
        let epk = Data((0..<32).map { UInt8($0) })
        let components = MessageCryptoService.EncryptedMessageComponents(
            ephemeralPublicKey: epk,
            messageNumber: 7,
            content: sealedBox,
            suiteId: 1,
            oneTimePreKeyId: 0,
            storageKey: Data()
        )
        let payload = try WirePayloadCoder.encode(components)
        measure {
            for _ in 0..<1000 {
                _ = try? WirePayloadCoder.decode(payload)
            }
        }
    }

    // MARK: - Message Padding

    func testPaddingRoundtripPerformance() {
        let input = Data(repeating: 0xAB, count: 512)
        measure {
            for _ in 0..<10_000 {
                let padded = MessagePadding.padCiphertext(input)
                _ = MessagePadding.unpadCiphertext(padded)
            }
        }
    }

    // MARK: - Encrypt + Wire Encode

    func testEncryptAndEncodePerformance() throws {
        let alice = try CryptoPeer(userId: "bench-alice-\(UUID().uuidString)")
        let bob   = try CryptoPeer(userId: "bench-bob-\(UUID().uuidString)")
        let bobBundle = try bob.bundle()
        try alice.initSenderSession(to: bob.userId, bundleBytes: bobBundle)

        let plaintext = Data("Hello, benchmark! This is a typical short message.".utf8)

        measure {
            for _ in 0..<100 {
                guard let rustComponents = try? alice.core.encryptMessage(
                    contactId: bob.userId,
                    plaintext: plaintext
                ) else { return }
                let content = MessagePadding.padCiphertext(Data(rustComponents.content))
                let components = MessageCryptoService.EncryptedMessageComponents(
                    ephemeralPublicKey: Data(rustComponents.ephemeralPublicKey),
                    messageNumber: rustComponents.messageNumber,
                    content: content,
                    suiteId: 1,
                    oneTimePreKeyId: 0,
                    storageKey: Data()
                )
                _ = try? WirePayloadCoder.encode(components)
            }
        }
    }

    // MARK: - Full Round-Trip (Encrypt → Wire → Decrypt)

    func testFullRoundTripPerformance() throws {
        let alice = try CryptoPeer(userId: "bench-alice-\(UUID().uuidString)")
        let bob   = try CryptoPeer(userId: "bench-bob-\(UUID().uuidString)")

        let aliceBundle = try alice.bundle()
        let bobBundle   = try bob.bundle()
        try alice.initSenderSession(to: bob.userId, bundleBytes: bobBundle)

        // Establish Bob's session via msgNum=0
        let init0 = try alice.core.encryptMessage(contactId: bob.userId, plaintext: Data("__init__".utf8))
        let init0Padded = MessagePadding.padCiphertext(Data(init0.content))
        let init0Dict: [String: Any] = [
            "ephemeral_public_key": init0.ephemeralPublicKey,
            "message_number": init0.messageNumber,
            "content": [UInt8](init0Padded),
        ]
        let init0Bytes = [UInt8](try JSONSerialization.data(withJSONObject: init0Dict))
        let aliceBundleBytes = try alice.bundle()
        _ = try bob.core.initReceivingSession(
            contactId: alice.userId,
            recipientBundle: aliceBundleBytes,
            firstMessage: init0Bytes
        )

        let plaintext = Data("Benchmark round-trip message".utf8)

        measure {
            for _ in 0..<50 {
                guard let rustComponents = try? alice.core.encryptMessage(
                    contactId: bob.userId,
                    plaintext: plaintext
                ) else { return }
                let content = MessagePadding.padCiphertext(Data(rustComponents.content))
                let components = MessageCryptoService.EncryptedMessageComponents(
                    ephemeralPublicKey: Data(rustComponents.ephemeralPublicKey),
                    messageNumber: rustComponents.messageNumber,
                    content: content,
                    suiteId: 1,
                    oneTimePreKeyId: 0,
                    storageKey: Data()
                )
                guard let wire = try? WirePayloadCoder.encode(components) else { return }
                guard let decoded = try? WirePayloadCoder.decode(wire) else { return }
                let unpadded = MessagePadding.unpadCiphertext(decoded.content)
                _ = try? bob.core.decryptMessage(
                    contactId: alice.userId,
                    ephemeralPublicKey: decoded.ephemeralPublicKey,
                    messageNumber: decoded.messageNumber,
                    content: [UInt8](unpadded)
                )
            }
        }
    }
}
