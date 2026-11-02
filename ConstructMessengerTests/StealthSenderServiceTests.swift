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

    /// A sender certificate as the core returns it from `open_sealed`. The verdict is passed to
    /// `attest` explicitly — it is the core's, and construct-core's tests lock it.
    private func cert(
        userId: String = "user-123",
        ik: Data = Data(repeating: 0xAB, count: 32)
    ) -> SenderCertificate {
        SenderCertificate(
            userId: userId,
            domain: "construct.example",
            identityKey: ik,
            deviceId: deriveDeviceId(identityPublicKey: ik),
            issuedAt: 1_000,
            expiresAt: 2_000,
            signature: Data(),
            serverKid: Data(),
            serverSignatureHybrid: Data()
        )
    }

    override func tearDown() async throws {
        StealthSenderService.shared.ktLookupOverrideForTesting = nil
        try await super.tearDown()
    }

    // MARK: - Trust label over the core's verdict (lever C: KT anchoring)
    //
    // The verdict (vouched / noKey / badSignature / expired) is the core's — `open_sealed`
    // computes it and construct-core's tests lock it. These tests lock only the layer this app
    // adds on top: the local KT anchor.

    func testAttest_vouchesViaKT_whenIdentityKeyMatchesVerified() {
        // KT alone must vouch (the whole point of lever C: existing-contact sealed receive
        // with zero bundle-key dependency).
        let ik = Data(repeating: 0x11, count: 32)
        let c = cert(userId: "alice", ik: ik)
        StealthSenderService.shared.ktLookupOverrideForTesting = { uid in
            uid == "alice" ? (ik, .verified) : nil
        }
        XCTAssertEqual(StealthSenderService.shared.attest(c, verdict: .vouched), .vouched(.kt))
    }

    func testAttest_keyChangedDoesNotVouchViaKT() {
        // Matching key but status .keyChanged — must NOT vouch via KT (that is exactly the
        // MITM-suspicion case KT exists to surface). A bad signature falls through to badSignature.
        let ik = Data(repeating: 0x22, count: 32)
        let c = cert(userId: "bob", ik: ik)
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in (ik, .keyChanged) }
        XCTAssertEqual(StealthSenderService.shared.attest(c, verdict: .badSignature), .unvouched(.badSignature))
    }

    func testAttest_ktKeyMismatchFallsBackToSignature() {
        // KT knows a DIFFERENT key for this user → KT path skipped → signature vouches.
        let c = cert(userId: "carol", ik: Data(repeating: 0x33, count: 32))
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in (Data(repeating: 0x99, count: 32), .verified) }
        XCTAssertEqual(StealthSenderService.shared.attest(c, verdict: .vouched), .vouched(.signature))
    }

    func testAttest_expiredBeatsKT() {
        // An expired cert is .unvouched(.expired) even when KT would otherwise vouch.
        let ik = Data(repeating: 0x44, count: 32)
        let c = cert(userId: "dave", ik: ik)
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in (ik, .verified) }
        XCTAssertEqual(StealthSenderService.shared.attest(c, verdict: .expired), .unvouched(.expired))
    }

    func testAttest_noKTRecordFallsBackToSignature() {
        let c = cert(userId: "erin")
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in nil }
        XCTAssertEqual(StealthSenderService.shared.attest(c, verdict: .vouched), .vouched(.signature))
    }

    func testAttest_noKeyIsItsOwnReason() {
        // "No key to check with" is transient and must not be reported as a bad signature
        // (the 2026-07-05 nil-key failure was mislogged that way).
        let c = cert(userId: "frank")
        StealthSenderService.shared.ktLookupOverrideForTesting = { _ in nil }
        XCTAssertEqual(StealthSenderService.shared.attest(c, verdict: .noKey), .unvouched(.noKey))
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

/// Locks the sealed-sender wire invariant at its two doors. Since 2026-09-28 a sealed envelope
/// leaves only as a `SendSealedMessageRequest`, which has no field for the sender, the
/// conversation, the content type or the device; the identified `Envelope` has no field for a
/// seal. The invariant is structural now, and these tests pin what each door does carry.
@MainActor
final class SealedSenderEnvelopeTests: XCTestCase {

    /// The request carries the seal, the timestamp and the attempt id — nothing that names anyone.
    func testSealedRequest_CarriesOnlyTheSeal() {
        let request = MessagingServiceClient.buildSealedRequest(
            sealedInner: Data([0x09, 0x09, 0x09]),
            timestamp: 42,
            attemptId: "a1"
        )
        XCTAssertEqual(request.sealedSender.sealedInner, Data([0x09, 0x09, 0x09]))
        XCTAssertEqual(request.attemptID, "a1")
        XCTAssertTrue(request.sealedSender.recipientServer.isEmpty,
                      "a local send leaves recipient_server empty; the relay routes on SealedInner")
    }

    /// `SealedSenderEnvelope.timestamp` is read by the federation forward. It was never written
    /// until 2026-08-17, and the dedicated RPC dropped it again until 2026-09-28, when it became
    /// the only door — every federated sealed message would have arrived stamped 0.
    ///
    /// Mutation: drop the assignment in `buildSealedRequest` — this reddens.
    func testSealedRequest_StampsTheEnvelopeFederationForwards() {
        let request = MessagingServiceClient.buildSealedRequest(
            sealedInner: Data([0x09]),
            timestamp: 1786992000,
            attemptId: "a1"
        )
        XCTAssertEqual(request.sealedSender.timestamp, 1786992000)
    }

    /// The unsealed path — multi-device fan-out and SENDER_SYNC — is the only one whose delivery
    /// depends on the outer payload. Removing it there would stop those copies dead.
    func testIdentifiedSend_CarriesTheCiphertext() {
        let payload = Data(repeating: 0xCD, count: 512)
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1", recipientId: "r", senderId: "s", conversationId: "c",
            encryptedPayload: payload, timestamp: 42,
            recipientDeviceId: nil,
            contentType: .e2EeSignal
        )
        XCTAssertEqual(env.encryptedPayload, payload)
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
            contentType: .e2EeSignal
        )
        XCTAssertTrue(env.hasRecipientDevice, "the unsealed path is the only one that can name a device")
        XCTAssertEqual(env.recipientDevice.deviceID, "6f5e37ac1b2c3d4e5f60718293a4b5c6")
    }

    /// An empty device id must leave the field unset rather than set it to "". The server reads
    /// the presence of the field: an empty named device would be a device it cannot find, which
    /// routes as `unknown_device` and logs a warning on every ordinary send.
    func testAnEmptyDeviceIdIsNotADevice() {
        let env = MessagingServiceClient.buildEnvelope(
            messageId: "m1", recipientId: "r", senderId: "s", conversationId: "c",
            encryptedPayload: Data([0x01]), timestamp: 1,
            recipientDeviceId: "",
            contentType: .e2EeSignal
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
            contentType: .e2EeSignal
        )
        XCTAssertTrue(env.hasSender)
        XCTAssertEqual(env.sender.userID, "sender-visible")
        XCTAssertEqual(env.conversationID, "conv-xyz")
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

    /// FF-1: a first flight the core sealed whole replaces the certificate box and the clear wire
    /// payload — leaving either beside it would put the PQXDH header, and the initiator's KEM
    /// identity key in it, back on the wire (`decisions/first-flight-sealed-whole.md`).
    ///
    /// Mutation: drop the `firstFlight` branch in `buildSealedInner` — this reddens.
    func testAFirstFlightReplacesTheCertificateAndThePayload() async throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let sealed = Data(repeating: 0x5F, count: 40)
        let bytes = try await StealthSenderService.shared.buildSealedInner(
            recipientUserId: "14f28d31-0000-0000-0000-000000000001",
            certBytes: Data([0x01, 0x02, 0x03]),
            recipientIdentityKey: key,
            encryptedPayload: Data([0xAA, 0xBB]),
            contentType: .generic,
            firstFlight: sealed
        )
        let inner = try Shared_Proto_Core_V1_SealedInner(serializedBytes: bytes)
        XCTAssertEqual(inner.firstFlight, sealed)
        XCTAssertTrue(inner.senderCertCiphertext.isEmpty)
        XCTAssertTrue(inner.encryptedPayload.isEmpty)
        XCTAssertEqual(inner.recipientDevice, SessionAddressing.cryptoIdentity(ofIdentityKey: key))
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
