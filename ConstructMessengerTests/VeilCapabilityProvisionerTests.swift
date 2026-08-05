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
