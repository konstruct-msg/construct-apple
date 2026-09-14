import XCTest
import CryptoKit
import SwiftProtobuf
@testable import Construct_Messenger

/// stealth-sealed-sender-v2 Phase 3 pinned the certificate to a single canonical payload
/// (direct concat, big-endian i64 times). sealed-sender-resilience Stage 1 turns the bare
/// pass/fail into a `SenderTrust` verdict, adds pinned bundle keys as a fallback trust
/// anchor, and distinguishes "no key to check with" from "bad signature". These tests lock
/// both contracts.
@MainActor
final class StealthSenderServiceTests: XCTestCase {

    private func makeCert(
        userId: String = "user-123",
        domain: String = "construct.example",
        ik: Data = Data(repeating: 0xAB, count: 32),
        deviceId: String = "device-1",
        issued: Int64 = 1_000,
        expires: Int64 = 2_000
    ) -> Shared_Proto_Core_V1_SenderCertificate {
        var cert = Shared_Proto_Core_V1_SenderCertificate()
        cert.senderUserID = userId
        cert.senderDomain = domain
        cert.senderIdentityKey = ik
        cert.senderDeviceID = deviceId
        cert.issuedAt = issued
        cert.expiresAt = expires
        return cert
    }

    private func sign(_ cert: inout Shared_Proto_Core_V1_SenderCertificate, with key: Curve25519.Signing.PrivateKey) {
        let payload = StealthSenderService.buildCertPayload(
            userID: cert.senderUserID, domain: cert.senderDomain, ik: cert.senderIdentityKey,
            deviceID: cert.senderDeviceID, issued: cert.issuedAt, expires: cert.expiresAt
        )
        cert.serverSignature = try! key.signature(for: payload)
    }

    /// A cert with a comfortably-future expiry — needed for the full `attest` ladder, whose
    /// first check is expiry (the Stage-1 `makeCert` default expires at epoch 2000).
    private func futureCert(
        userId: String = "user-kt",
        ik: Data = Data(repeating: 0xAB, count: 32)
    ) -> Shared_Proto_Core_V1_SenderCertificate {
        let now = Int64(Date().timeIntervalSince1970)
        return makeCert(userId: userId, ik: ik, issued: now - 60, expires: now + 3_600)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        StealthSenderService.shared.extraTrustedBundleKeysForTesting = []
        StealthSenderService.shared.ktLookupOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - Signature attestation (fetched key)

    func testAttest_vouchesCanonicalVariant0Signature() {
        let signingKey = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(signingKey.publicKey.rawRepresentation, forKey: VeilCertFetcher.cachedBundleSigningKeyKey)

        var cert = makeCert()
        sign(&cert, with: signingKey)

        XCTAssertEqual(StealthSenderService.shared.attestSignature(cert), .vouched(.signature))
    }

    func testAttest_rejectsLegacyColonAsciiFormat() {
        let signingKey = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(signingKey.publicKey.rawRepresentation, forKey: VeilCertFetcher.cachedBundleSigningKeyKey)

        var cert = makeCert()
        // Old variant 2: colon-separated, ASCII-decimal times — must no longer verify.
        var legacyPayload = Data()
        legacyPayload.append(contentsOf: cert.senderUserID.utf8)
        legacyPayload.append(UInt8(ascii: ":"))
        legacyPayload.append(contentsOf: cert.senderDomain.utf8)
        legacyPayload.append(UInt8(ascii: ":"))
        legacyPayload.append(cert.senderIdentityKey)
        legacyPayload.append(UInt8(ascii: ":"))
        legacyPayload.append(contentsOf: cert.senderDeviceID.utf8)
        legacyPayload.append(UInt8(ascii: ":"))
        legacyPayload.append(contentsOf: String(cert.issuedAt).utf8)
        legacyPayload.append(UInt8(ascii: ":"))
        legacyPayload.append(contentsOf: String(cert.expiresAt).utf8)
        cert.serverSignature = try! signingKey.signature(for: legacyPayload)

        XCTAssertEqual(StealthSenderService.shared.attestSignature(cert), .unvouched(.badSignature))
    }

    func testAttest_rejectsWrongSigner() {
        let signingKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(otherKey.publicKey.rawRepresentation, forKey: VeilCertFetcher.cachedBundleSigningKeyKey)

        var cert = makeCert()
        sign(&cert, with: signingKey)

        XCTAssertEqual(StealthSenderService.shared.attestSignature(cert), .unvouched(.badSignature))
    }

    func testAttest_emptySignatureIsBadSignature() {
        UserDefaults.standard.set(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                  forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        let cert = makeCert() // serverSignature left empty
        XCTAssertEqual(StealthSenderService.shared.attestSignature(cert), .unvouched(.badSignature))
    }

    // MARK: - Pinned-key fallback (lever B) — the 2026-07-05 incident fix

    func testAttest_vouchesViaPinnedKey_whenFetchedCacheEmpty() {
        // No fetched key cached at all (the incident: VEIL never populated it). A cert
        // signed by a pinned key must still vouch — this is the whole point of the pin.
        UserDefaults.standard.removeObject(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        let pin = Curve25519.Signing.PrivateKey()
        StealthSenderService.shared.extraTrustedBundleKeysForTesting = [pin.publicKey.rawRepresentation]

        var cert = makeCert()
        sign(&cert, with: pin)

        XCTAssertEqual(StealthSenderService.shared.attestSignature(cert), .vouched(.signature))
    }

    func testAttest_badSignatureNotNoKey_whenOnlyPinsPresent() {
        // Empty fetched cache but a real pin ships in prod → the key set is non-empty, so a
        // genuinely bad signature must be `.badSignature`, never `.noKey`. (The old code
        // conflated "no key" with "bad signature" and mislogged the incident.)
        UserDefaults.standard.removeObject(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        var cert = makeCert()
        sign(&cert, with: Curve25519.Signing.PrivateKey()) // random signer, not a pin
        XCTAssertEqual(StealthSenderService.shared.attestSignature(cert), .unvouched(.badSignature))
    }

    func testAttest_rotationSet_acceptsEitherPinnedKey() {
        UserDefaults.standard.removeObject(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        let current = Curve25519.Signing.PrivateKey()
        let next = Curve25519.Signing.PrivateKey()
        StealthSenderService.shared.extraTrustedBundleKeysForTesting =
            [current.publicKey.rawRepresentation, next.publicKey.rawRepresentation]

        var certCurrent = makeCert(userId: "u-current")
        sign(&certCurrent, with: current)
        var certNext = makeCert(userId: "u-next")
        sign(&certNext, with: next)

        XCTAssertEqual(StealthSenderService.shared.attestSignature(certCurrent), .vouched(.signature))
        XCTAssertEqual(StealthSenderService.shared.attestSignature(certNext), .vouched(.signature))
    }

    // MARK: - Full attest ladder (lever C: KT anchoring)

    func testAttest_vouchesViaKT_whenIdentityKeyMatchesVerified() {
        // No bundle key cached AND empty signature — KT alone must vouch (the whole point
        // of lever C: existing-contact sealed receive with zero bundle-key dependency).
        UserDefaults.standard.removeObject(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        let ik = Data(repeating: 0x11, count: 32)
        let cert = futureCert(userId: "alice", ik: ik) // serverSignature left empty
        StealthSenderService.shared.ktLookupOverrideForTesting = { uid in
            uid == "alice" ? (ik, .verified) : nil
        }
        XCTAssertEqual(StealthSenderService.shared.attest(cert), .vouched(.kt))
    }

    func testAttest_keyChangedDoesNotVouchViaKT() {
        // Matching key but status .keyChanged — must NOT vouch via KT (that is exactly the
        // MITM-suspicion case KT exists to surface). Empty sig → falls through to badSignature.
        let ik = Data(repeating: 0x22, count: 32)
        let cert = futureCert(userId: "bob", ik: ik)
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in (ik, .keyChanged) }
        XCTAssertEqual(StealthSenderService.shared.attest(cert), .unvouched(.badSignature))
    }

    func testAttest_ktKeyMismatchFallsBackToSignature() {
        // KT knows a DIFFERENT key for this user → KT path skipped → signature vouches.
        let signer = Curve25519.Signing.PrivateKey()
        StealthSenderService.shared.extraTrustedBundleKeysForTesting = [signer.publicKey.rawRepresentation]
        var cert = futureCert(userId: "carol", ik: Data(repeating: 0x33, count: 32))
        sign(&cert, with: signer)
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in (Data(repeating: 0x99, count: 32), .verified) }
        XCTAssertEqual(StealthSenderService.shared.attest(cert), .vouched(.signature))
    }

    func testAttest_expiredBeatsKT() {
        // An expired cert is .unvouched(.expired) even when KT would otherwise vouch.
        let ik = Data(repeating: 0x44, count: 32)
        let cert = makeCert(userId: "dave", ik: ik, issued: 1_000, expires: 2_000) // long expired
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in (ik, .verified) }
        XCTAssertEqual(StealthSenderService.shared.attest(cert), .unvouched(.expired))
    }

    func testAttest_noKTRecordFallsBackToSignature() {
        let signer = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(signer.publicKey.rawRepresentation, forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        var cert = futureCert(userId: "erin")
        sign(&cert, with: signer)
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in nil }
        XCTAssertEqual(StealthSenderService.shared.attest(cert), .vouched(.signature))
    }

    // MARK: - Shipped pin is a valid 32-byte Ed25519 key

    func testShippedPin_isValid32ByteKey() {
        let pins = VEILConfig.pinnedBundleSigningKeys
        XCTAssertFalse(pins.isEmpty, "at least one bundle key must be pinned")
        for b64 in pins {
            guard let raw = Data(base64Encoded: b64) else {
                return XCTFail("pinned bundle key is not valid base64: \(b64)")
            }
            XCTAssertEqual(raw.count, 32, "pinned bundle key must be 32 bytes")
            XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
        }
    }
}

/// Locks the core sealed-sender wire invariant: a sealed send never carries the real `senderId`
/// (or `conversationID` / `contentType`) on the outer envelope, and an identified send always does.
/// This is the structural foundation every sealed-eligible sender (bodies, retries, receipts,
/// call-signals) relies on — if `buildEnvelope` ever leaked the sender under a sealed send, every
/// upstream fail-closed guard would be moot.
final class SealedSenderEnvelopeTests: XCTestCase {

    func testSealedSend_omitsSenderConversationAndContentType() {
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1",
            recipientId: "recipient-abc",
            senderId: "SECRET-SENDER-must-not-leak",
            conversationId: "conv-xyz",
            encryptedPayload: Data([0x01, 0x02, 0x03]),
            timestamp: 42,
            recipientDeviceId: "rdev",
            contentType: .e2EeSignal,
            sealedInnerBytes: Data([0x09, 0x09, 0x09])
        )
        // The whole point of sealed sender: none of the sender-identifying metadata on the wire.
        XCTAssertFalse(env.hasSender, "sealed send leaked sender on the outer envelope")
        XCTAssertTrue(env.conversationID.isEmpty, "sealed send leaked conversationId")
        XCTAssertTrue(env.hasSealedSender, "sealed send must carry the SealedSenderEnvelope")
        XCTAssertEqual(env.sealedSender.sealedInner, Data([0x09, 0x09, 0x09]))
        // Routing metadata the server legitimately needs is still present.
        XCTAssertEqual(env.recipient.userID, "recipient-abc")
    }

    /// The padded ciphertext went up the wire twice on every sealed send: once on the outer
    /// envelope and once inside `SealedInner`. The relay drops the outer copy — its sealed branch
    /// returns before reading `encrypted_payload`, and the envelope it delivers is rebuilt by
    /// `MessageEnvelope::from_sealed_sender` from `sealed_inner` alone — so the duplicate bought
    /// nothing and cost 1024, 4096 or 16384 bytes per chunk.
    ///
    /// Mutation: set `encryptedPayload` unconditionally again — this reddens, and it is what
    /// shipped until 2026-08-17.
    func testSealedSend_DoesNotDuplicateTheCiphertextOnTheOuterEnvelope() {
        let payload = Data(repeating: 0xAB, count: 1024)
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1",
            recipientId: "recipient-abc",
            senderId: "sender",
            conversationId: "conv",
            encryptedPayload: payload,
            timestamp: 42,
            recipientDeviceId: nil,
            contentType: .e2EeSignal,
            sealedInnerBytes: Data([0x09, 0x09, 0x09])
        )
        XCTAssertTrue(env.encryptedPayload.isEmpty,
                      "the ciphertext is inside SealedInner; the relay never reads this copy")
        XCTAssertEqual(env.sealedSender.sealedInner, Data([0x09, 0x09, 0x09]))
    }

    /// The unsealed path — multi-device fan-out and SENDER_SYNC — is the only one whose delivery
    /// depends on the outer payload. Removing it there would stop those copies dead.
    func testIdentifiedSend_StillCarriesTheCiphertext() {
        let payload = Data(repeating: 0xCD, count: 512)
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1", recipientId: "r", senderId: "s", conversationId: "c",
            encryptedPayload: payload, timestamp: 42,
            recipientDeviceId: nil,
            contentType: .e2EeSignal, sealedInnerBytes: nil
        )
        XCTAssertEqual(env.encryptedPayload, payload)
    }

    /// `SealedSenderEnvelope.timestamp` is read by the federation forward and was never written,
    /// so every federated sealed message arrived stamped 0.
    ///
    /// Mutation: drop the assignment — this reddens.
    func testSealedSend_StampsTheEnvelopeFederationForwards() {
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1", recipientId: "r", senderId: "s", conversationId: "c",
            encryptedPayload: Data([0x01]), timestamp: 1786992000,
            recipientDeviceId: nil,
            contentType: .e2EeSignal, sealedInnerBytes: Data([0x09])
        )
        XCTAssertEqual(env.sealedSender.timestamp, 1786992000)
    }

    /// `Envelope.recipient_device` had no writer between 2026-08-17 and 2026-08-30. The removal
    /// was correct when made — nothing read the field — and became wrong on 2026-08-29, when the
    /// server began routing on it (`construct-server@619bad8`). Three fan-out call sites went on
    /// passing `target.deviceId` into a function that dropped it, so a copy addressed to one
    /// device was written to every device of the account: N copies × N devices.
    ///
    /// Mutation: drop the assignment again — this reddens.
    func testIdentifiedSend_NamesTheRecipientDevice() {
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1", recipientId: "r", senderId: "s", conversationId: "c",
            encryptedPayload: Data([0x01]), timestamp: 1,
            recipientDeviceId: "6f5e37ac1b2c3d4e5f60718293a4b5c6",
            contentType: .e2EeSignal, sealedInnerBytes: nil
        )
        XCTAssertTrue(env.hasRecipientDevice, "the unsealed path is the only one that can name a device")
        XCTAssertEqual(env.recipientDevice.deviceID, "6f5e37ac1b2c3d4e5f60718293a4b5c6")
    }

    /// The outer field is visible to the relay, so a sealed send must not use it — that is the
    /// whole reason `SealedInner.recipient_device` (field 19) exists. Naming the device outside
    /// the seal would hand the relay a device-granular topology of exactly the traffic sealed
    /// sender exists to hide.
    ///
    /// Mutation: move the assignment above the `if`/`else` — this reddens.
    func testSealedSend_DoesNotNameTheDeviceOnTheOuterEnvelope() {
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1", recipientId: "r", senderId: "s", conversationId: "c",
            encryptedPayload: Data([0x01]), timestamp: 1,
            recipientDeviceId: "6f5e37ac1b2c3d4e5f60718293a4b5c6",
            contentType: .e2EeSignal, sealedInnerBytes: Data([0x09])
        )
        XCTAssertFalse(env.hasRecipientDevice,
                       "a sealed send names its device inside SealedInner, never on the envelope")
    }

    /// An empty device id must leave the field unset rather than set it to "". The server reads
    /// the presence of the field: an empty named device would be a device it cannot find, which
    /// routes as `unknown_device` and logs a warning on every ordinary send.
    func testAnEmptyDeviceIdIsNotADevice() {
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1", recipientId: "r", senderId: "s", conversationId: "c",
            encryptedPayload: Data([0x01]), timestamp: 1,
            recipientDeviceId: "",
            contentType: .e2EeSignal, sealedInnerBytes: nil
        )
        XCTAssertFalse(env.hasRecipientDevice)
    }

    func testIdentifiedSend_populatesSender() {
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1",
            recipientId: "recipient-abc",
            senderId: "sender-visible",
            conversationId: "conv-xyz",
            encryptedPayload: Data([0x01]),
            timestamp: 42,
            recipientDeviceId: nil,
            contentType: .e2EeSignal,
            sealedInnerBytes: nil
        )
        XCTAssertTrue(env.hasSender)
        XCTAssertEqual(env.sender.userID, "sender-visible")
        XCTAssertEqual(env.conversationID, "conv-xyz")
        XCTAssertFalse(env.hasSealedSender)
    }

    func testEmptySealedBytesFallsBackToIdentified_neverSilentlyDropsSender() {
        // Empty sealed bytes must NOT be treated as a sealed send — otherwise the sender would be
        // silently dropped, producing an unroutable envelope with no sender AND no seal.
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1",
            recipientId: "r",
            senderId: "sender-visible",
            conversationId: "c",
            encryptedPayload: Data(),
            timestamp: 1,
            recipientDeviceId: nil,
            contentType: .e2EeSignal,
            sealedInnerBytes: Data()
        )
        XCTAssertTrue(env.hasSender)
        XCTAssertFalse(env.hasSealedSender)
    }
}

/// §A.0 client half: a sealed envelope names the device its certificate is sealed to.
///
/// Before `SealedInner.recipient_device`, a sealed message — which is every user message, since
/// `StealthPolicy.isEnabled` is a release-time constant — was written to every mailbox of the
/// recipient's account. It is encrypted in a Double Ratchet session with **one** device, so the
/// others received a ciphertext they could not decrypt and a certificate they could not unseal.
///
/// The regression these tests exist to catch is silent: drop the assignment and everything still
/// works, just fanned out to the whole account again, with no error anywhere.
@MainActor
final class SealedInnerRecipientDeviceTests: XCTestCase {

    private func sealedInner(to identityKey: Data) async throws -> Shared_Proto_Core_V1_SealedInner {
        let bytes = try await StealthSenderService.shared.buildSealedInner(
            recipientUserId: "14f28d31-0000-0000-0000-000000000001",
            certBytes: Data([0x01, 0x02, 0x03]),
            recipientIdentityKey: identityKey,
            encryptedPayload: Data([0xAA, 0xBB]),
            contentType: .generic
        )
        return try Shared_Proto_Core_V1_SealedInner(serializedBytes: bytes)
    }

    func testNamesTheDeviceTheCertificateIsSealedTo() async throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let inner = try await sealedInner(to: key)

        XCTAssertFalse(
            inner.recipientDevice.isEmpty,
            "an empty device field is the pre-2026-08-29 account-wide delivery, silently"
        )
        XCTAssertEqual(
            inner.recipientDevice,
            SessionAddressing.cryptoIdentity(ofIdentityKey: key),
            "the routed device must be the one whose key the certificate was sealed to"
        )
    }

    /// The wiring, not the derivation: a device id that does not follow the key it was handed is
    /// one read out of a store or off a parameter, and either can name a device the ciphertext
    /// was never for.
    func testTheDeviceFollowsTheKeyRatherThanTheAccount() async throws {
        let keyA = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let keyB = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

        let deviceA = try await sealedInner(to: keyA).recipientDevice
        let deviceB = try await sealedInner(to: keyB).recipientDevice

        // Same recipientUserId both times — only the key differs.
        XCTAssertNotEqual(deviceA, deviceB, "the device must track the key, not the account id")
        XCTAssertEqual(deviceA, SessionAddressing.cryptoIdentity(ofIdentityKey: keyA))
        XCTAssertEqual(deviceB, SessionAddressing.cryptoIdentity(ofIdentityKey: keyB))
    }

    func testTheDeviceIsAShapedCryptoDeviceId() async throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let device = try await sealedInner(to: key).recipientDevice

        // 32 hex chars — SHA256(identity_public)[0..16]. A ServerUserId here would be a 36-char
        // dashed UUID, which is the identity-space mix-up this codebase has paid for repeatedly.
        XCTAssertEqual(device.count, 32)
        XCTAssertTrue(device.allSatisfy(\.isHexDigit))
    }
}
