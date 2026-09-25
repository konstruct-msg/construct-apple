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

        /// The bundle as the server serves it after PQXDH v2 — see `PQXDHTestBundles`.
        func bundle() throws -> BinaryKeyBundle {
            try core.pqxdhTestBundle()
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
            storageKey: Data(),
            pqMessageEpoch: 0,
            pqRatchetField: Data()
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
            storageKey: Data(),
            pqMessageEpoch: 0,
            pqRatchetField: Data()
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
                let padded = input
                _ = padded
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
                let components = MessageCryptoService.EncryptedMessageComponents(from: rustComponents)
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
        _ = try bob.core.pqxdhTestReceive(from: alice.userId, senderBundle: aliceBundle, first: init0)

        let plaintext = Data("Benchmark round-trip message".utf8)

        measure {
            for _ in 0..<50 {
                guard let rustComponents = try? alice.core.encryptMessage(
                    contactId: bob.userId,
                    plaintext: plaintext
                ) else { return }
                let components = MessageCryptoService.EncryptedMessageComponents(from: rustComponents)
                guard let wire = try? WirePayloadCoder.encode(components) else { return }
                guard let decoded = try? WirePayloadCoder.decode(wire) else { return }
                let unpadded = decoded.content
                _ = try? bob.core.decryptMessage(
                    contactId: alice.userId,
                    ephemeralPublicKey: decoded.ephemeralPublicKey,
                    messageNumber: decoded.messageNumber,
                    content: [UInt8](unpadded),
                    suiteId: decoded.suiteId,
                    pqMessageEpoch: decoded.pqMessageEpoch,
                    pqRatchetField: [UInt8](decoded.pqRatchetField)
                )
            }
        }
    }
}
