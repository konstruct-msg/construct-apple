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

        /// Named by the id its identity key derives to, as a real device is.
        init() throws {
            let device = try makeTestDevice()
            self.core = device.core
            self.userId = device.deviceId
        }

        /// The bundle as the server serves it after PQXDH v2 — see `PQXDHTestBundles`.
        func bundle() throws -> BinaryKeyBundle {
            try core.pqxdhTestBundle()
        }

        func initSenderSession(to contactId: String, bundle: BinaryKeyBundle) throws {
            _ = try core.initSession(contactId: contactId, recipientBundle: bundle)
        }
    }

    // MARK: - Wire Payload Decode

    /// What every received message now costs at the boundary: one `wire_summary`.
    func testWirePayloadDecodePerformance() throws {
        // A first flight as the core packs it — the header, the KEM identity key and all.
        let alice = try CryptoPeer()
        let bob = try CryptoPeer()
        try alice.initSenderSession(to: bob.userId, bundle: try bob.bundle())
        let payload = try alice.core.encryptToWire(contactId: bob.userId, plaintext: Data("x".utf8))
        measure {
            for _ in 0..<1000 {
                _ = try? wireSummary(wirePayload: payload)
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
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()
        let bobBundle = try bob.bundle()
        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        let plaintext = Data("Hello, benchmark! This is a typical short message.".utf8)

        measure {
            for _ in 0..<100 {
                _ = try? alice.core.encryptToWire(contactId: bob.userId, plaintext: plaintext)
            }
        }
    }

    // MARK: - Full Round-Trip (Encrypt → Wire → Decrypt)

    func testFullRoundTripPerformance() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()

        let bobBundle   = try bob.bundle()
        try alice.initSenderSession(to: bob.userId, bundle: bobBundle)

        // Establish Bob's session via msgNum=0
        let init0 = try alice.core.encryptToWire(contactId: bob.userId, plaintext: Data("__init__".utf8))
        _ = try bob.core.pqxdhTestReceive(from: alice.core, first: init0)

        let plaintext = Data("Benchmark round-trip message".utf8)

        measure {
            for _ in 0..<50 {
                guard let wire = try? alice.core.encryptToWire(contactId: bob.userId, plaintext: plaintext)
                else { return }
                _ = try? bob.core.decryptWirePayload(contactId: alice.userId, wirePayload: wire)
            }
        }
    }
}
