//
//  VeilCapabilityProvisionerTests.swift
//  ConstructMessengerTests
//
//  Auto first-issue decision + EntryDirectory Option-C accept gate.
//  Pure decision tests — no network, no Keychain writes for the decision path.
//

import XCTest
@testable import Construct_Messenger

final class VeilCapabilityProvisionerTests: XCTestCase {

    // MARK: - needsProvision

    func testNeedsProvision_nilTicket() {
        XCTAssertTrue(VeilCapabilityProvisioner.needsProvision(storedTicketB64: nil))
    }

    func testNeedsProvision_emptyTicket() {
        XCTAssertTrue(VeilCapabilityProvisioner.needsProvision(storedTicketB64: ""))
        XCTAssertTrue(VeilCapabilityProvisioner.needsProvision(storedTicketB64: "   "))
    }

    func testNeedsProvision_garbageTicket() {
        // Unparseable → re-issue (do not leave poison in store).
        XCTAssertTrue(VeilCapabilityProvisioner.needsProvision(storedTicketB64: "not-a-capability"))
        XCTAssertTrue(VeilCapabilityProvisioner.needsProvision(storedTicketB64: "YWJjZGVm")) // "abcdef"
    }

    func testNeedsProvision_expiredTicketViaInjectedParse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let parse: (String) throws -> VeilConfigImporter.ParsedCapability = { _ in
            VeilConfigImporter.ParsedCapability(
                scope: "ru",
                notBefore: 0,
                notAfter: 999_000 // before `now`
            )
        }
        XCTAssertTrue(
            VeilCapabilityProvisioner.needsProvision(
                storedTicketB64: "any-non-empty",
                now: now,
                parse: parse
            )
        )
    }

    func testNeedsProvision_liveTicketViaInjectedParse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let parse: (String) throws -> VeilConfigImporter.ParsedCapability = { _ in
            VeilConfigImporter.ParsedCapability(
                scope: "ru",
                notBefore: 0,
                notAfter: 2_000_000 // after `now`
            )
        }
        XCTAssertFalse(
            VeilCapabilityProvisioner.needsProvision(
                storedTicketB64: "any-non-empty",
                now: now,
                parse: parse
            )
        )
    }

    func testNeedsProvision_zeroNotAfterMeansNoExpiry() {
        // Mirror parseCapability: not_after == 0 → no expiry encoded → do not re-issue.
        let now = Date(timeIntervalSince1970: 9_999_999_999)
        let parse: (String) throws -> VeilConfigImporter.ParsedCapability = { _ in
            VeilConfigImporter.ParsedCapability(scope: "ru", notBefore: 0, notAfter: 0)
        }
        XCTAssertFalse(
            VeilCapabilityProvisioner.needsProvision(
                storedTicketB64: "any-non-empty",
                now: now,
                parse: parse
            )
        )
    }

    // MARK: - VeilAlternatesCache.accept (Option C)

    func testAlternatesAccept_rejectsUnknownRelay() {
        let alt = VeilServiceClient.Alternate(
            capability: Data([1, 2, 3]),
            relayAddress: "evil.example:443",
            spki: "aabbccdd",
            sni: "evil.example",
            notAfter: Int64(Date().timeIntervalSince1970) + 86_400,
            capabilityVersion: 1
        )
        XCTAssertFalse(VeilAlternatesCache.accept(alt),
                       "server-asserted coords for an unknown relay must be rejected")
    }

    func testAlternatesAccept_rejectsSPKIMismatchOnSeedRelay() {
        guard let seed = VEILConfig.seedRelays.first else {
            return XCTFail("expected at least one seed relay")
        }
        // Same address as a trusted seed, but a foreign pin — anti-redirection.
        let alt = VeilServiceClient.Alternate(
            capability: Data(repeating: 0xAB, count: 130),
            relayAddress: seed.address,
            spki: String(repeating: "0", count: 64),
            sni: seed.sni,
            notAfter: Int64(Date().timeIntervalSince1970) + 86_400,
            capabilityVersion: 1
        )
        XCTAssertFalse(VeilAlternatesCache.accept(alt),
                       "SPKI mismatch against seed/manifest pin must be rejected")
    }

    func testAlternatesAccept_rejectsEmptySPKIOnSeedRelay() {
        guard let seed = VEILConfig.seedRelays.first else {
            return XCTFail("expected at least one seed relay")
        }
        let alt = VeilServiceClient.Alternate(
            capability: Data([0]),
            relayAddress: seed.address,
            spki: "",
            sni: seed.sni,
            notAfter: Int64(Date().timeIntervalSince1970) + 86_400,
            capabilityVersion: 1
        )
        XCTAssertFalse(VeilAlternatesCache.accept(alt))
    }

    // MARK: - The same gate on the PRIMARY capability
    //
    // These are the twins of the four alternates tests above, and their absence is why the
    // asymmetry was invisible. The primary path used to check only the issuer signature, store
    // the ticket, and *then* compare the SPKI as a log line — skipping that comparison entirely
    // when the address matched no anchor. It matters because the address is the server's:
    // `issueCapability` prefers `response.relay_address` over the one we asked for, so answering
    // a request for relay A with relay B stored an unchecked ticket for B.

    /// Gate 1 on the primary path. Mutation: drop the `unknownRelay` branch from
    /// `VeilRelayTrust.verify` — the single change that reopens "server names any relay".
    func testPrimaryVerify_rejectsUnknownRelay() {
        let rejection = VeilRelayTrust.verify(
            relayAddress: "evil.example:443",
            spki: "aabbccdd",
            capabilityB64: Data([1, 2, 3]).base64EncodedString(),
            capabilityVersion: 1
        )
        XCTAssertEqual(rejection, .unknownRelay,
                       "an address no anchor vouches for must be refused, not silently skipped")
    }

    /// Gate 2 on the primary path — the anti-redirection check that used to run after the store.
    func testPrimaryVerify_rejectsSPKIMismatchOnSeedRelay() {
        guard let seed = VEILConfig.seedRelays.first else {
            return XCTFail("expected at least one seed relay")
        }
        let rejection = VeilRelayTrust.verify(
            relayAddress: seed.address,
            spki: String(repeating: "0", count: 64),
            capabilityB64: Data(repeating: 0xAB, count: 130).base64EncodedString(),
            capabilityVersion: 1
        )
        guard case .spkiMismatch = rejection else {
            return XCTFail("expected spkiMismatch, got \(String(describing: rejection))")
        }
    }

    /// An absent SPKI is a mismatch, not a pass. Mutation: drop `!spki.isEmpty` from the guard.
    func testPrimaryVerify_rejectsEmptySPKIOnSeedRelay() {
        guard let seed = VEILConfig.seedRelays.first else {
            return XCTFail("expected at least one seed relay")
        }
        let rejection = VeilRelayTrust.verify(
            relayAddress: seed.address,
            spki: "",
            capabilityB64: Data([0]).base64EncodedString(),
            capabilityVersion: 1
        )
        guard case .spkiMismatch = rejection else {
            return XCTFail("expected spkiMismatch for empty SPKI, got \(String(describing: rejection))")
        }
    }

    /// Gate 3: right coordinates, forged blob.
    func testPrimaryVerify_rejectsInvalidCapabilityWithMatchingCoords() {
        guard let seed = VEILConfig.seedRelays.first else {
            return XCTFail("expected at least one seed relay")
        }
        let rejection = VeilRelayTrust.verify(
            relayAddress: seed.address,
            spki: seed.spki,
            capabilityB64: Data("not-a-real-capability".utf8).base64EncodedString(),
            capabilityVersion: 1
        )
        guard case .invalidCapability = rejection else {
            return XCTFail("expected invalidCapability, got \(String(describing: rejection))")
        }
    }

    /// The gate must be the *same* gate. If the two paths can ever disagree about one coordinate,
    /// the weaker one decides what gets stored — which is exactly the state this replaced.
    func testPrimaryAndAlternatesAgreeOnTheSameCoordinate() {
        let cases: [(String, String, Data)] = [
            ("evil.example:443", "aabbccdd", Data([1, 2, 3])),
            (VEILConfig.seedRelays.first?.address ?? "", String(repeating: "0", count: 64), Data(repeating: 0xAB, count: 130)),
            (VEILConfig.seedRelays.first?.address ?? "", "", Data([0])),
            (VEILConfig.seedRelays.first?.address ?? "", VEILConfig.seedRelays.first?.spki ?? "", Data("nope".utf8))
        ]
        for (address, spki, blob) in cases {
            let alt = VeilServiceClient.Alternate(
                capability: blob,
                relayAddress: address,
                spki: spki,
                sni: address,
                notAfter: Int64(Date().timeIntervalSince1970) + 86_400,
                capabilityVersion: 1
            )
            let primaryRejected = VeilRelayTrust.verify(
                relayAddress: address,
                spki: spki,
                capabilityB64: blob.base64EncodedString(),
                capabilityVersion: 1
            ) != nil
            XCTAssertEqual(
                primaryRejected, !VeilAlternatesCache.accept(alt),
                "primary and alternates disagreed about \(address) — one gate, or the weaker one wins"
            )
        }
    }

    func testAlternatesAccept_rejectsMatchingCoordsButInvalidCapabilityBlob() {
        // Even with matching seed pin, a garbage capability blob must not be accepted —
        // the issuer signature is the third gate of Option C.
        guard let seed = VEILConfig.seedRelays.first else {
            return XCTFail("expected at least one seed relay")
        }
        let alt = VeilServiceClient.Alternate(
            capability: Data("not-a-real-capability".utf8),
            relayAddress: seed.address,
            spki: seed.spki,
            sni: seed.sni,
            notAfter: Int64(Date().timeIntervalSince1970) + 86_400,
            capabilityVersion: 1
        )
        XCTAssertFalse(VeilAlternatesCache.accept(alt),
                       "valid coords + invalid capability blob must be rejected")
    }
}
