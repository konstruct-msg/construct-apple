//
//  VeilEntryPointSignatureTests.swift
//  ConstructMessengerTests
//
//  Phase 3: an alternate front is accepted on the strength of an issuer signature over
//  its coordinate tuple, and on nothing else.
//

import XCTest
import CryptoKit
@testable import Construct_Messenger

final class VeilEntryPointSignatureTests: XCTestCase {

    private let key = Curve25519.Signing.PrivateKey()

    private var pubHex: String {
        key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// Sign the same bytes the server signs.
    private func sign(relay: String, sni: String, spki: String, exp: Int64) -> String {
        let canonical = VeilEntryPointSignature.canonicalTuple(
            relay: relay, sni: sni, spki: spki, exp: exp
        )!
        let sig = try! key.signature(for: canonical)
        return "ed25519:" + sig.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - The bytes

    func testCanonicalTupleIsSortedCompactAndUnescaped() {
        // Must match `sign_entrypoint_tuple` in veil-service/src/core.rs byte for byte.
        let data = VeilEntryPointSignature.canonicalTuple(
            relay: "front.example:443",
            sni: "cdn/front.example",
            spki: "deadbeef",
            exp: 1_770_000_000
        )
        let json = String(data: data!, encoding: .utf8)
        XCTAssertEqual(
            json,
            #"{"exp":1770000000,"relay":"front.example:443","sni":"cdn/front.example","spki":"deadbeef"}"#
        )
    }

    func testCanonicalTupleExcludesTheCapability() {
        // The capability is verified on its own. Including it here would invalidate the
        // signature every time the capability rotates on unchanged coordinates.
        let json = String(
            data: VeilEntryPointSignature.canonicalTuple(
                relay: "a:443", sni: "a", spki: "ff", exp: 1
            )!,
            encoding: .utf8
        )!
        XCTAssertFalse(json.contains("capability"))
    }

    // MARK: - The verifier

    func testValidSignatureVerifies() {
        let exp = Int64(Date().timeIntervalSince1970) + 3600
        let sig = sign(relay: "a.example:443", sni: "a.example", spki: "abcd", exp: exp)
        XCTAssertTrue(VeilEntryPointSignature.verify(
            signature: sig, relay: "a.example:443", sni: "a.example", spki: "abcd",
            exp: exp, publicKeyHex: pubHex
        ))
    }

    func testAnySingleFieldChangeInvalidates() {
        // The requirement the spec calls out: a signature over the address alone would
        // authenticate `relay` while leaving `spki` free to substitute.
        let exp = Int64(Date().timeIntervalSince1970) + 3600
        let sig = sign(relay: "a.example:443", sni: "a.example", spki: "abcd", exp: exp)
        let v = { (r: String, s: String, p: String, e: Int64) in
            VeilEntryPointSignature.verify(
                signature: sig, relay: r, sni: s, spki: p, exp: e, publicKeyHex: self.pubHex
            )
        }
        XCTAssertTrue(v("a.example:443", "a.example", "abcd", exp))
        XCTAssertFalse(v("evil.example:443", "a.example", "abcd", exp), "relay")
        XCTAssertFalse(v("a.example:443", "evil.example", "abcd", exp), "sni")
        XCTAssertFalse(v("a.example:443", "a.example", "cafe", exp), "spki")
        XCTAssertFalse(v("a.example:443", "a.example", "abcd", exp + 1), "exp")
    }

    func testAForeignKeyDoesNotVerify() {
        let exp = Int64(Date().timeIntervalSince1970) + 3600
        let sig = sign(relay: "a.example:443", sni: "a.example", spki: "abcd", exp: exp)
        let other = Curve25519.Signing.PrivateKey()
        let otherHex = other.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(VeilEntryPointSignature.verify(
            signature: sig, relay: "a.example:443", sni: "a.example", spki: "abcd",
            exp: exp, publicKeyHex: otherHex
        ))
    }

    func testEmptyAndMalformedSignaturesAreRefused() {
        let exp = Int64(Date().timeIntervalSince1970) + 3600
        for sig in ["", "abcd", "ed25519:", "ed25519:!!!!", "ecdsa:AAAA"] {
            XCTAssertFalse(VeilEntryPointSignature.verify(
                signature: sig, relay: "a.example:443", sni: "a.example", spki: "abcd",
                exp: exp, publicKeyHex: pubHex
            ), "must refuse \(sig.isEmpty ? "<empty>" : sig)")
        }
    }

    func testEmptyCoordinateFieldsAreRefused() {
        // A tuple with an empty spki would otherwise pin nothing while looking verified.
        let exp = Int64(Date().timeIntervalSince1970) + 3600
        let sig = sign(relay: "a.example:443", sni: "a.example", spki: "", exp: exp)
        XCTAssertFalse(VeilEntryPointSignature.verify(
            signature: sig, relay: "a.example:443", sni: "a.example", spki: "",
            exp: exp, publicKeyHex: pubHex
        ))
    }

    // MARK: - The gate

    func testUnsignedAlternateForAnUnknownRelayIsStillRejected() {
        // Today's behaviour, and the fallback for a server that predates the field.
        let alt = VeilServiceClient.Alternate(
            capability: Data([1, 2, 3]),
            relayAddress: "unknown.example:443",
            spki: "aabbccdd",
            sni: "unknown.example",
            notAfter: Int64(Date().timeIntervalSince1970) + 86_400,
            capabilityVersion: 1,
            signature: ""
        )
        XCTAssertFalse(VeilAlternatesCache.accept(alt))
        XCTAssertNil(VeilLearnedFrontStore.shared.pin(for: "unknown.example:443"),
                     "a rejected alternate must not leave a pin behind")
    }

    func testAGarbageSignatureLearnsNothing() {
        let alt = VeilServiceClient.Alternate(
            capability: Data([1, 2, 3]),
            relayAddress: "forged.example:443",
            spki: String(repeating: "a", count: 64),
            sni: "forged.example",
            notAfter: Int64(Date().timeIntervalSince1970) + 86_400,
            capabilityVersion: 1,
            signature: "ed25519:" + String(repeating: "A", count: 86)
        )
        XCTAssertFalse(VeilAlternatesCache.accept(alt))
        XCTAssertNil(VeilLearnedFrontStore.shared.pin(for: "forged.example:443"))
    }

    func testAValidSignatureOverAnInvalidCapabilityRollsThePinBack() throws {
        // `verifyAndLearn` writes the pin before gate 3, so gate 3 can read it. A refused
        // capability must not leave a trusted address behind — the same rollback
        // `VeilConfigImporter.importBlob` performs.
        let store = VeilLearnedFrontStore.shared
        let address = "rollback.example:443"
        try XCTSkipUnless(store.pin(for: address) == nil, "address must start unlearned")
        defer { store.remove(address) }

        let exp = Int64(Date().timeIntervalSince1970) + 3600
        let spki = String(repeating: "b", count: 64)
        let rejection = VeilRelayTrust.verifyAndLearn(
            relayAddress: address,
            spki: spki,
            sni: "rollback.example",
            notAfter: exp,
            signature: sign(relay: address, sni: "rollback.example", spki: spki, exp: exp),
            capabilityB64: Data("not-a-real-capability".utf8).base64EncodedString(),
            capabilityVersion: 1,
            publicKeyHex: pubHex
        )
        guard case .invalidCapability = rejection else {
            return XCTFail("expected the tuple to anchor and the capability to fail, got \(String(describing: rejection))")
        }
        XCTAssertNil(store.pin(for: address), "a refused coordinate must leave no pin")
    }

    func testAnExpiredTupleIsNotAnAnchor() {
        // Without `exp` in the signed bytes a retired front could never be un-vouched.
        let past = Int64(Date().timeIntervalSince1970) - 60
        let address = "expired.example:443"
        let rejection = VeilRelayTrust.verifyAndLearn(
            relayAddress: address,
            spki: String(repeating: "c", count: 64),
            sni: "expired.example",
            notAfter: past,
            signature: sign(relay: address, sni: "expired.example",
                            spki: String(repeating: "c", count: 64), exp: past),
            capabilityB64: Data([1, 2, 3]).base64EncodedString(),
            capabilityVersion: 1,
            publicKeyHex: pubHex
        )
        XCTAssertEqual(rejection, .unknownRelay)
        XCTAssertNil(VeilLearnedFrontStore.shared.pin(for: address))
    }

    func testASignatureCannotRepointASeedRelay() throws {
        // The invariant that keeps the manifest meaningful: a public anchor wins, so the
        // live server cannot re-point a published front by signing over it.
        let seed = try XCTUnwrap(VEILConfig.seedRelays.first)
        let exp = Int64(Date().timeIntervalSince1970) + 3600
        let foreign = String(repeating: "d", count: 64)
        let rejection = VeilRelayTrust.verifyAndLearn(
            relayAddress: seed.address,
            spki: foreign,
            sni: seed.sni,
            notAfter: exp,
            signature: sign(relay: seed.address, sni: seed.sni, spki: foreign, exp: exp),
            capabilityB64: Data(repeating: 0xAB, count: 130).base64EncodedString(),
            capabilityVersion: 1,
            publicKeyHex: pubHex
        )
        guard case .spkiMismatch = rejection else {
            return XCTFail("expected spkiMismatch, got \(String(describing: rejection))")
        }
    }
}
