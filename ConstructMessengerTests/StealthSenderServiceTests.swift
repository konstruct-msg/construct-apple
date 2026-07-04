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

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: VeilCertFetcher.cachedBundleSigningKeyKey)
        StealthSenderService.shared.extraTrustedBundleKeysForTesting = []
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
