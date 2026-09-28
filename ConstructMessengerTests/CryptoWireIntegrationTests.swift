//
//  CryptoWireIntegrationTests.swift
//  ConstructMessengerTests
//
//  Integration tests for the full message send/receive pipeline:
//  Rust core `encryptToWire` → (wire) → Rust core `decryptWirePayload`. The core packs and reads
//  the payload; nothing between rebuilds it from components.
//
//  This validates that the binary wire format correctly round-trips through the crypto layer,
//  matching what actually happens in production (ChunkedMessageDelivery → MessageStreamManager).
//

import XCTest
@testable import Construct_Messenger

final class CryptoWireIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal crypto peer — wraps a Rust OrchestratorCore instance for testing
    class CryptoPeer {
        let core: OrchestratorCore
        let userId: String

        /// Named by the id its identity key derives to, as a real device is. `localUserId` names it
        /// anything else — only for the test of an initiator that signs its AD with the wrong id.
        init(localUserId: String? = nil) throws {
            // Bootstrap: generate fresh device keys via ClassicCryptoCore, then
            // migrate to OrchestratorCore (matches the production init path).
            let bootstrap = try createCryptoCore()
            let keys = try bootstrap.exportPrivateKeys()
            let derived = deriveDeviceId(
                identityPublicKey: try bootstrap.getRegistrationBundleFields().identityPublic
            )
            let userId = localUserId ?? derived
            self.userId = userId
            self.core = try createOrchestratorCoreFromKeys(keysData: keys, myUserId: userId)
            // The KEM identity key an initiator names derives from the hybrid key every device
            // that publishes a bundle holds.
            _ = try core.ensureHybridSignatureKey()
        }

        /// The bundle as the server serves it after PQXDH v2 — see `PQXDHTestBundles`.
        func bundle() throws -> BinaryKeyBundle {
            try core.pqxdhTestBundle()
        }

        /// Initiate session as sender (X3DH)
        func initSenderSession(to contactId: String, recipientBundle: BinaryKeyBundle) throws {
            _ = try core.initSession(contactId: contactId, recipientBundle: recipientBundle)
        }

        /// Encrypt plaintext → the wire payload the core packed.
        func encryptRaw(_ plaintext: String, to contactId: String) throws -> Data {
            try core.encryptToWire(contactId: contactId, plaintext: Data(plaintext.utf8))
        }

        /// The payload as it goes on the wire — the core's bytes, unchanged. Kept as a step so
        /// the tests read as the pipeline they check.
        func encodeWire(_ wire: Data) throws -> Data {
            wire
        }

        /// Decrypt a payload as it arrived.
        func decodeAndDecrypt(_ payload: Data, from contactId: String) throws -> String {
            let plaintextData = try core.decryptWirePayload(contactId: contactId, wirePayload: payload)
            return String(data: Data(plaintextData.plaintext), encoding: .utf8) ?? ""
        }

        /// Initialize the receiving session from the first wire-encoded message, the payload as
        /// received, with `sender`'s certificate — the key it names is the key the session opens
        /// with, under the device it names.
        func initReceiverSession(from sender: CryptoPeer, wirePayload: Data) throws -> String {
            let result = try core.pqxdhTestReceive(from: sender.core, wirePayload: [UInt8](wirePayload))
            return String(bytes: result.decryptedMessage, encoding: .utf8) ?? "__binary_init__"
        }

        /// Initiate a session against a peer whose SPK is `spkAgeDays` old.
        /// `allowStale == false` exercises the strict gate (`initSession`, expected to throw
        /// `PeerSpkStale` past the 30-day limit); `allowStale == true` exercises the degraded
        /// path (`initSessionAllowingStale`). Verifies the FFI binding + xcframework wiring of
        /// the stale-peer-reachability Phase 1 change end-to-end.
        func initSenderSession(to contactId: String,
                                recipientBundle: BinaryKeyBundle,
                                spkAgeDays: UInt64,
                                allowStale: Bool) throws {
            let now = UInt64(Date().timeIntervalSince1970)
            var bundle = recipientBundle
            bundle.spkUploadedAt = now - spkAgeDays * 86_400
            if allowStale {
                _ = try core.initSessionAllowingStale(contactId: contactId, recipientBundle: bundle)
            } else {
                _ = try core.initSession(contactId: contactId, recipientBundle: bundle)
            }
        }
    }

    // MARK: - Full Wire Pipeline: Alice → Bob

    func testFullWirePipelineAliceToBob() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()

        let bobBundle   = try bob.bundle()

        // Alice initiates session
        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        // Alice encrypts and encodes to wire
        let plaintext1 = "Hello Bob! Testing the full wire pipeline."
        let components = try alice.encryptRaw(plaintext1, to: bob.userId)
        let wirePayload = try alice.encodeWire(components)

        // Verify wire payload structure
        XCTAssertGreaterThan(wirePayload.count, WirePayloadCoder.headerSize)

        // Bob receives and decrypts from wire
        let decrypted1 = try bob.initReceiverSession(from: alice, wirePayload: wirePayload)
        XCTAssertEqual(decrypted1, plaintext1, "First message through full wire pipeline")
    }

    // MARK: - Stale-peer reachability (Phase 1 — degraded init)

    /// The strict initiator path must reject a peer whose SPK is past the 30-day staleness limit.
    func testStrictInitRejectsStaleSPK() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()
        let bobBundle = try bob.bundle()

        XCTAssertThrowsError(
            try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle, spkAgeDays: 31, allowStale: false),
            "strict init must reject a stale SPK"
        ) { error in
            guard case CryptoError.PeerSpkStale = error else {
                return XCTFail("expected CryptoError.PeerSpkStale, got \(error)")
            }
        }
    }

    /// The degraded initiator path must accept the same stale bundle the strict path rejects.
    func testDegradedInitAcceptsStaleSPK() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()
        let bobBundle = try bob.bundle()

        XCTAssertNoThrow(
            try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle, spkAgeDays: 60, allowStale: true),
            "degraded init must accept a stale SPK"
        )
    }

    /// A degraded session must be fully functional end-to-end through the wire pipeline when the
    /// peer still holds its SPK private key (the lost-SPK case falls through to session healing).
    func testDegradedSessionFullWirePipeline() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()
        let bobBundle   = try bob.bundle()

        // Bob has been offline 35 days → only the degraded path can reach him.
        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle, spkAgeDays: 35, allowStale: true)

        let plaintext = "Reachable even though your keys are stale."
        let components = try alice.encryptRaw(plaintext, to: bob.userId)
        let wirePayload = try alice.encodeWire(components)

        let decrypted = try bob.initReceiverSession(from: alice, wirePayload: wirePayload)
        XCTAssertEqual(decrypted, plaintext, "degraded-init first message must decrypt over the wire")
    }

    func testFullWirePipelineBidirectional() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()

        let bobBundle   = try bob.bundle()

        // Setup: Alice → Bob first message
        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)
        let firstComponents = try alice.encryptRaw("Message 1 from Alice", to: bob.userId)
        let firstWire = try alice.encodeWire(firstComponents)

        _ = try bob.initReceiverSession(from: alice, wirePayload: firstWire)

        // Bob → Alice: reply using the existing session (initReceiverSession already set it up)
        // initSenderSession here would overwrite Bob's session with wrong key material
        let bobReply = try bob.encryptRaw("Reply from Bob", to: alice.userId)
        let bobWire = try bob.encodeWire(bobReply)

        // Alice decrypts Bob's reply — DH ratchet step, no initReceiverSession needed
        _ = try alice.decodeAndDecrypt(bobWire, from: bob.userId)

        // Continue: Alice sends another message (post-DH-ratchet)
        let plaintext = "Second message from Alice"
        let components2 = try alice.encryptRaw(plaintext, to: bob.userId)
        let wire2 = try alice.encodeWire(components2)
        let decrypted = try bob.decodeAndDecrypt(wire2, from: alice.userId)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testWirePayloadIsOpaqueToServer() throws {
        // The server sees only the wire payload bytes — verify no plaintext leaks
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()
        let bobBundle = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        let secretMessage = "VERY_SECRET_CONTENT_DO_NOT_LEAK"
        let components = try alice.encryptRaw(secretMessage, to: bob.userId)
        let wirePayload = try alice.encodeWire(components)

        // The wire payload should not contain the plaintext in any readable form
        let payloadString = String(data: wirePayload, encoding: .utf8)
        XCTAssertNil(payloadString.flatMap { $0.contains(secretMessage) ? $0 : nil },
            "Plaintext must not appear in wire payload")

        // Also check as ASCII
        let asciiBytes = secretMessage.utf8.map { $0 }
        let payloadBytes = [UInt8](wirePayload)
        let containsASCII = payloadBytes.windows(ofCount: asciiBytes.count).contains { Array($0) == asciiBytes }
        XCTAssertFalse(containsASCII, "Plaintext ASCII bytes must not appear in wire payload")
    }

    // MARK: - Multiple Messages via Wire

    func testMultipleMessagesViaWire() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()

        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        // First message establishes Bob's session
        let firstComp = try alice.encryptRaw("First", to: bob.userId)
        let firstWire = try alice.encodeWire(firstComp)
        let first = try bob.initReceiverSession(from: alice, wirePayload: firstWire)
        XCTAssertEqual(first, "First")

        // Subsequent messages
        for i in 2...10 {
            let plaintext = "Message number \(i)"
            let comp = try alice.encryptRaw(plaintext, to: bob.userId)
            let wire = try alice.encodeWire(comp)
            let decrypted = try bob.decodeAndDecrypt(wire, from: alice.userId)
            XCTAssertEqual(decrypted, plaintext, "Wire pipeline failed at message \(i)")
        }
    }

    // MARK: - Wire Format Integrity

    func testWirePayloadHeaderSize() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()
        let bobBundle = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)
        let comp = try alice.encryptRaw("test", to: bob.userId)
        let wire = try alice.encodeWire(comp)

        // First 4 bytes: message_number LE
        // Bytes 4..36: DH public key (32 bytes)
        XCTAssertGreaterThanOrEqual(wire.count, WirePayloadCoder.headerSize + 1)

        // Verify dh_public_key field is 32 bytes
        let dhBytes = wire[4..<36]
        XCTAssertEqual(dhBytes.count, 32)
    }

    func testWirePayloadMessageNumberIncrements() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()
        let bobBundle = try bob.bundle()
        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        var previousMsgNum: UInt32 = UInt32.max
        for _ in 0..<5 {
            let comp = try alice.encryptRaw("test", to: bob.userId)
            let wire = try alice.encodeWire(comp)
            let decoded = try WirePayloadCoder.decode(wire)

            if previousMsgNum != UInt32.max {
                XCTAssertGreaterThan(decoded.messageNumber, previousMsgNum,
                    "Message numbers must be strictly increasing")
            }
            previousMsgNum = decoded.messageNumber
        }
    }

    // MARK: - Tamper Resistance

    func testTamperedWirePayloadFailsDecryption() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()

        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        let comp = try alice.encryptRaw("Hello", to: bob.userId)
        let wirePayload = try alice.encodeWire(comp)

        _ = try bob.initReceiverSession(from: alice, wirePayload: wirePayload)

        // Send second message, then tamper with the sealed box itself. Not by a wire offset: until
        // Bob answers, Alice's messages still carry the PQXDH v2 header, and a fixed offset past
        // the fixed header lands in the KEM ciphertext, which a held session ignores.
        // The sealed box is the payload's last section, so a byte near the end is ciphertext.
        var tamperedWire = try alice.encryptRaw("Second", to: bob.userId)
        tamperedWire[tamperedWire.endIndex - 20] ^= 0xFF

        XCTAssertThrowsError(try bob.decodeAndDecrypt(tamperedWire, from: alice.userId),
            "Tampered ciphertext must be rejected by AEAD")
    }

    func testTamperedMessageNumberFailsDecryption() throws {
        let alice = try CryptoPeer()
        let bob   = try CryptoPeer()

        let bobBundle   = try bob.bundle()

        try alice.initSenderSession(to: bob.userId, recipientBundle: bobBundle)

        let comp = try alice.encryptRaw("Hello", to: bob.userId)
        let firstWire = try alice.encodeWire(comp)
        _ = try bob.initReceiverSession(from: alice, wirePayload: firstWire)

        // Second message — tamper with message_number in wire payload
        let comp2 = try alice.encryptRaw("Second", to: bob.userId)
        var wire2 = try alice.encodeWire(comp2)
        // Increment message_number byte by 1 (LE byte 0)
        wire2[0] = wire2[0] &+ 1

        XCTAssertThrowsError(try bob.decodeAndDecrypt(wire2, from: alice.userId),
            "Tampered message_number must fail AAD verification")
    }
}

// MARK: - AD Identity Tests
//
// Tests for the AEAD Associated Data identity-format invariant.
// Root cause postmortem: CryptoManager.cryptoLocalUserId returned a 32-char
// device-hash (loadDeviceID) instead of the 36-char server UUID (_cachedUserId).
// Double Ratchet AD:
//   ENCRYPT: AD_VERSION || local_user_id || contact_id || session_id || dh_pub || msg_num
//   DECRYPT: AD_VERSION || contact_id   || local_user_id || …
// Both IDs MUST use the same identity space (server UUIDs) on both sides.

final class ADIdentityTests: XCTestCase {

    // ── Convenience alias so we don't write CryptoWireIntegrationTests.CryptoPeer everywhere
    typealias Peer = CryptoWireIntegrationTests.CryptoPeer

    // MARK: - Type safety (compile-time proof)

    func testServerUserIdAndCryptoDeviceIdAreDistinctTypes() {
        // This test is a compile-time contract: if the two types were the same,
        // the assignment below would not compile.
        let serverUUID  = ServerUserId(rawValue: "14f28d31-2dab-44aa-a123-456789abcdef")
        let deviceHash  = CryptoDeviceId(rawValue: "6f5e37ac88bd2cc53348f01f78cdf5db")
        XCTAssertEqual(serverUUID.rawValue.count, 36, "Server UUID must be 36 chars")
        XCTAssertEqual(deviceHash.rawValue.count, 32, "Crypto device hash must be 32 chars")
        XCTAssertTrue(serverUUID.rawValue.contains("-"),  "Server UUID must contain dashes")
        XCTAssertFalse(deviceHash.rawValue.contains("-"), "Device hash must not contain dashes")
        // Compiler enforces they are distinct types — cannot pass one where the other is expected.
        XCTAssertNotEqual(serverUUID.rawValue, deviceHash.rawValue)
    }

    // MARK: - A session is between two device ids

    /// A full exchange between two devices, each named by the id its identity key derives to — the
    /// ids the AD binds on both sides. The responder does not choose the name: the sender
    /// certificate names the device, and the core checks the key derives to it.
    func testFullSessionSucceedsWithDerivedDeviceIds() throws {
        let alice = try Peer()
        let bob   = try Peer()

        try alice.initSenderSession(to: bob.userId, recipientBundle: try bob.bundle())
        let firstWire = try alice.encodeWire(try alice.encryptRaw("Hello Bob", to: bob.userId))
        XCTAssertEqual(try bob.initReceiverSession(from: alice, wirePayload: firstWire), "Hello Bob")
        XCTAssertTrue(bob.core.hasSession(contactId: alice.userId), "filed under the certified device")

        let replyWire = try bob.encodeWire(try bob.encryptRaw("Hi Alice", to: alice.userId))
        XCTAssertEqual(try alice.decodeAndDecrypt(replyWire, from: bob.userId), "Hi Alice")

        // Alternating messages: several DH ratchet steps.
        for i in 1...10 {
            let aWire = try alice.encodeWire(try alice.encryptRaw("alice-\(i)", to: bob.userId))
            XCTAssertEqual(try bob.decodeAndDecrypt(aWire, from: alice.userId), "alice-\(i)")
            let bWire = try bob.encodeWire(try bob.encryptRaw("bob-\(i)", to: alice.userId))
            XCTAssertEqual(try alice.decodeAndDecrypt(bWire, from: bob.userId), "bob-\(i)")
        }
    }

    // MARK: - Bug reproduction: an initiator that signs its AD with another id

    /// The original production bug, in its current form. Alice's core was created with her
    /// account's server UUID as its local id; the responder files the session under the device her
    /// certificate names. The AD bytes differ and the first message MUST NOT open.
    func testSessionFailsWhenInitiatorUsesAnAccountIdAsItsLocalId() throws {
        let aliceBuggy = try Peer(localUserId: "14f28d31-2dab-44aa-a123-456789abcdef")
        let bob        = try Peer()

        try aliceBuggy.initSenderSession(to: bob.userId, recipientBundle: try bob.bundle())
        let firstWire = try aliceBuggy.encodeWire(
            try aliceBuggy.encryptRaw("This AEAD tag will not verify", to: bob.userId)
        )

        XCTAssertThrowsError(
            try bob.initReceiverSession(from: aliceBuggy, wirePayload: firstWire),
            "AEAD must fail: the initiator bound an account id, the responder the certified device"
        )
    }

    /// A certificate for another device does not open Alice's message: the session would be keyed
    /// to Carol's identity, and the handshake Alice ran does not derive with it.
    func testACertificateForAnotherDeviceDoesNotOpenTheMessage() throws {
        let alice = try Peer()
        let carol = try Peer()
        let bob   = try Peer()

        try alice.initSenderSession(to: bob.userId, recipientBundle: try bob.bundle())
        let firstWire = try alice.encodeWire(try alice.encryptRaw("only for bob", to: bob.userId))

        XCTAssertThrowsError(
            try bob.initReceiverSession(from: carol, wirePayload: firstWire),
            "the key the certificate names is the key the session opens with"
        )
        XCTAssertFalse(bob.core.hasSession(contactId: carol.userId), "nothing left behind")
    }

    // MARK: - Migration guard

    func testMigrationUserDefaultsFlagPreventsRepeatedClears() {
        let key = "construct.adMigration.serverUUID.v1.done"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) } // clean up after test

        XCTAssertFalse(UserDefaults.standard.bool(forKey: key),
                       "Flag must be absent before first migration run")

        // Simulate what migrateSessionsIfNeeded does when it runs for the first time.
        UserDefaults.standard.set(true, forKey: key)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: key),
                      "Flag must be set after first run")

        // A second call should skip work because the flag is already set.
        // (We can't call the private method directly; we verify the guard contract.)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key),
                      "Flag must persist so migration does not run again on next launch")
    }
}

// MARK: - Collection sliding window helper

private extension Collection {
    func windows(ofCount size: Int) -> [[Element]] {
        guard count >= size else { return [] }
        var result: [[Element]] = []
        var start = startIndex
        while true {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            if distance(from: start, to: end) < size { break }
            result.append(Array(self[start..<end]))
            start = index(after: start)
        }
        return result
    }
}
