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

        func bundle() throws -> BinaryKeyBundle {
            let fields = try core.getRegistrationBundleFields()
            return BinaryKeyBundle(
                identityPublic: fields.identityPublic, signedPrekeyPublic: fields.signedPrekeyPublic,
                signature: fields.signature, verifyingKey: fields.verifyingKey,
                suiteId: fields.suiteId, oneTimePrekeyPublic: nil, oneTimePrekeyId: nil,
                spkUploadedAt: 0, spkRotationEpoch: 0,
                kyberSpkUploadedAt: 0, kyberSpkRotationEpoch: 0,
                kyberPreKeyPublic: nil, kyberOneTimePrekeyPublic: nil, kyberOneTimePrekeyId: nil
            )
        }

        func initSenderSession(to contactId: String, bundle: BinaryKeyBundle) throws {
            _ = try core.initSession(contactId: contactId, recipientBundle: bundle)
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
        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

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
        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // Establish Bob's session via msgNum=0
        let init0 = try alice.core.encryptMessage(contactId: bob.userId, plaintext: Data("__init__".utf8))
        let init0Padded = MessagePadding.padCiphertext(Data(init0.content))
        let firstMsg = BinaryFirstMessage(
            ephemeralPublicKey: init0.ephemeralPublicKey,
            messageNumber: init0.messageNumber,
            content: [UInt8](init0Padded),
            oneTimePrekeyId: init0.oneTimePrekeyId
        )
        _ = try bob.core.initReceivingSession(
            contactId: alice.userId,
            recipientBundle: aliceBundle,
            firstMessage: firstMsg
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
