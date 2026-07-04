import XCTest
import CryptoKit
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
