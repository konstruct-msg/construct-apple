//
//  VeilLocalDiscoveryTests.swift
//  ConstructMessengerTests
//
//  EntryDirectory Source 3 — trust core.
//
//  The load-bearing security property: local discovery gives *reachability*, never
//  *trust*. A discovered relay is accepted ONLY when its advertised SPKI matches an
//  already-trusted identity (seed pin ∪ cached manifest pin). These tests pin that gate
//  and the TXT-advert parsing so a LAN adversary cannot introduce a new trusted relay.
//

import XCTest
@testable import Construct_Messenger

final class VeilLocalDiscoveryTests: XCTestCase {

    // MARK: - accept(spki:trusted:) — the trust gate

    func testAcceptMatchingSPKI() {
        let trusted: Set<String> = ["aabbcc"]
        XCTAssertTrue(VeilLocalDiscovery.accept(spki: "aabbcc", trusted: trusted))
    }

    func testAcceptIsCaseInsensitive() {
        let trusted: Set<String> = ["aabbcc"]           // lowercased, as trustedSPKIs() produces
        XCTAssertTrue(VeilLocalDiscovery.accept(spki: "AABBCC", trusted: trusted))
    }

    func testRejectUnknownSPKI() {
        // An adversary on the LAN advertising a real address but a foreign key.
        let trusted: Set<String> = ["aabbcc"]
        XCTAssertFalse(VeilLocalDiscovery.accept(spki: "deadbeef", trusted: trusted))
    }

    func testRejectEmptySPKI() {
        XCTAssertFalse(VeilLocalDiscovery.accept(spki: "", trusted: ["aabbcc"]))
    }

    func testRejectWhenNothingTrusted() {
        XCTAssertFalse(VeilLocalDiscovery.accept(spki: "aabbcc", trusted: []))
    }

    // MARK: - parseAdvert — TXT record

    func testParseFullAdvert() {
        let parsed = VeilLocalDiscovery.parseAdvert(
            ["spki": "aabbcc", "sni": "relay.local", "wt": "/api/stream", "v": "1"])
        XCTAssertEqual(parsed?.spki, "aabbcc")
        XCTAssertEqual(parsed?.sni, "relay.local")
        XCTAssertEqual(parsed?.wtPath, "/api/stream")
        XCTAssertEqual(parsed?.version, 1)
    }

    func testParseAdvertOptionalWTPath() {
        // Absent or empty `wt` → nil (plain-TLS island relay, no WebTunnel path).
        XCTAssertNil(VeilLocalDiscovery.parseAdvert(["spki": "aabbcc"])?.wtPath)
        XCTAssertNil(VeilLocalDiscovery.parseAdvert(["spki": "aabbcc", "wt": ""])?.wtPath)
    }

    func testParseAdvertWithoutSPKIIsNil() {
        // No trust key → cannot be gated → must not parse.
        XCTAssertNil(VeilLocalDiscovery.parseAdvert(["sni": "relay.local"]))
        XCTAssertNil(VeilLocalDiscovery.parseAdvert(["spki": "", "sni": "relay.local"]))
    }

    func testParseAdvertOptionalSNIAndVersionDefault() {
        let parsed = VeilLocalDiscovery.parseAdvert(["spki": "aabbcc"])
        XCTAssertEqual(parsed?.spki, "aabbcc")
        XCTAssertNil(parsed?.sni)                        // absent SNI → nil (caller falls back)
        XCTAssertNil(parsed?.wtPath)                     // absent wt → nil (plain-TLS)
        XCTAssertEqual(parsed?.version, 1)               // absent v → defaults to 1
    }

    func testParseAdvertEmptySNITreatedAsNil() {
        let parsed = VeilLocalDiscovery.parseAdvert(["spki": "aabbcc", "sni": ""])
        XCTAssertNil(parsed?.sni)
    }

    // MARK: - trustedSPKIs — always includes the bundled seed pins

    func testTrustedSPKIsIncludeSeedPins() {
        let trusted = VeilLocalDiscovery.trustedSPKIs()
        for seed in VEILConfig.seedRelays {
            XCTAssertTrue(trusted.contains(seed.spki.lowercased()),
                          "seed pin \(seed.spki) must be trusted for Source-3 discovery")
        }
    }

    /// End-to-end trust decision: an advert bearing a bundled seed's own SPKI is accepted
    /// (it's just a new LAN reachability path for a relay we already trust); a foreign
    /// SPKI at the same address is rejected.
    func testDiscoveryAcceptsSeedIdentityRejectsForeign() {
        let trusted = VeilLocalDiscovery.trustedSPKIs()
        guard let seedSPKI = VEILConfig.seedRelays.first?.spki else {
            return XCTFail("expected at least one bundled seed relay")
        }
        XCTAssertTrue(VeilLocalDiscovery.accept(spki: seedSPKI, trusted: trusted))
        XCTAssertFalse(VeilLocalDiscovery.accept(
            spki: "00000000000000000000000000000000000000000000000000000000deadbeef",
            trusted: trusted))
    }

    // MARK: - DiscoveredRelayStore — the nonisolated producer→consumer bridge

    func testDiscoveredRelayStorePublishLookupClear() {
        let store = DiscoveredRelayStore.shared
        store.clear()
        defer { store.clear() }

        let relay = DiscoveredRelay(
            host: "192.168.1.42", port: 443, sni: "relay.local", spki: "aabbcc", wtPath: "/api/stream")
        store.publish([relay])

        // Keyed by host:port identity, carrying the trust-gated fields for buildRelay.
        XCTAssertEqual(store.relay(for: "192.168.1.42:443"), relay)
        XCTAssertEqual(store.addresses(), ["192.168.1.42:443"])
        XCTAssertEqual(store.relay(for: "192.168.1.42:443")?.spki, "aabbcc")
        XCTAssertEqual(store.relay(for: "192.168.1.42:443")?.wtPath, "/api/stream")

        store.clear()
        XCTAssertNil(store.relay(for: "192.168.1.42:443"))
        XCTAssertTrue(store.addresses().isEmpty)
    }

    /// publish replaces the whole snapshot (LAN reachability is not additive across scans).
    func testDiscoveredRelayStorePublishReplacesSnapshot() {
        let store = DiscoveredRelayStore.shared
        store.clear()
        defer { store.clear() }

        let a = DiscoveredRelay(host: "10.0.0.1", port: 443, sni: nil, spki: "aa", wtPath: nil)
        let b = DiscoveredRelay(host: "10.0.0.2", port: 443, sni: nil, spki: "bb", wtPath: nil)
        store.publish([a])
        store.publish([b])

        XCTAssertNil(store.relay(for: "10.0.0.1:443"), "prior snapshot entry must be dropped")
        XCTAssertEqual(store.relay(for: "10.0.0.2:443"), b)
    }
}
