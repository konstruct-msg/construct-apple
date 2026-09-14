//
//  VeilLearnedFrontStoreTests.swift
//  ConstructMessengerTests
//
//  The learned-front anchor (signature instead of list).
//
//  Two properties are load-bearing and everything else here supports them:
//   1. nothing malformed reaches the store — `VeilRelayTrust` compares the stored pin
//      against the offered SPKI, so an empty or garbage pin would be a comparison that
//      cannot fail meaningfully;
//   2. a learned pin anchors ONE address and never joins the address-free
//      `VeilLocalDiscovery.trustedSPKIs()` set — see the last test for why.
//

import XCTest
@testable import Construct_Messenger

/// In-memory backing so the store's own logic is testable without a Keychain.
private final class MemoryLearnedFrontPersistence: VeilLearnedFrontPersistence {
    var data: Data?
    var saveSucceeds = true
    private(set) var saveCount = 0

    func load() -> Data? { data }

    @discardableResult
    func save(_ data: Data) -> Bool {
        saveCount += 1
        guard saveSucceeds else { return false }
        self.data = data
        return true
    }

    func clear() { data = nil }
}

final class VeilLearnedFrontStoreTests: XCTestCase {

    private let pinA = String(repeating: "a", count: 64)
    private let pinB = String(repeating: "b", count: 64)

    private func makeStore() -> (VeilLearnedFrontStore, MemoryLearnedFrontPersistence) {
        let backing = MemoryLearnedFrontPersistence()
        return (VeilLearnedFrontStore(persistence: backing), backing)
    }

    // MARK: - normalize

    func testNormalizeAcceptsWellFormedTuple() {
        let entry = VeilLearnedFrontCore.normalize(
            address: "front-1.example:443", sni: "front-1.example", spki: pinA
        )
        XCTAssertEqual(entry?.address, "front-1.example:443")
        XCTAssertEqual(entry?.sni, "front-1.example")
        XCTAssertEqual(entry?.spki, pinA)
    }

    func testNormalizeLowercasesAddressAndPin() {
        let entry = VeilLearnedFrontCore.normalize(
            address: " Front-1.EXAMPLE:443 ", sni: " Front-1.EXAMPLE ",
            spki: "  " + pinA.uppercased() + "  "
        )
        XCTAssertEqual(entry?.address, "front-1.example:443")
        XCTAssertEqual(entry?.sni, "front-1.example")
        XCTAssertEqual(entry?.spki, pinA)
    }

    func testNormalizeDerivesSNIFromHostWhenAbsent() {
        let entry = VeilLearnedFrontCore.normalize(address: "front-1.example:8443", sni: "", spki: pinA)
        XCTAssertEqual(entry?.sni, "front-1.example")
    }

    func testNormalizeRejectsBadPins() {
        // Too short, too long, non-hex, empty — each would store a pin that can never
        // equal a real offered SPKI, i.e. a front that silently never connects.
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "f.example:443", sni: "f.example", spki: String(repeating: "a", count: 63)))
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "f.example:443", sni: "f.example", spki: String(repeating: "a", count: 65)))
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "f.example:443", sni: "f.example", spki: String(repeating: "z", count: 64)))
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "f.example:443", sni: "f.example", spki: ""))
    }

    func testNormalizeRejectsAddressWithoutUsablePort() {
        // buildRelay and VeilRelayTrust both key on the exact `host:port` string; an
        // address without one would be pinned under a key nothing ever looks up.
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "front-1.example", sni: "", spki: pinA))
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "front-1.example:", sni: "", spki: pinA))
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "front-1.example:0", sni: "", spki: pinA))
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: "front-1.example:99999", sni: "", spki: pinA))
        XCTAssertNil(VeilLearnedFrontCore.normalize(address: ":443", sni: "", spki: pinA))
    }

    func testNormalizeUnwrapsBracketedIPv6ForSNI() {
        let entry = VeilLearnedFrontCore.normalize(address: "[2001:db8::1]:443", sni: "", spki: pinA)
        XCTAssertEqual(entry?.address, "[2001:db8::1]:443")
        XCTAssertEqual(entry?.sni, "2001:db8::1")
    }

    // MARK: - merge

    func testMergeReplacesSameAddressRatherThanAccumulating() {
        let first = VeilLearnedFront(address: "f.example:443", sni: "f.example", spki: pinA,
                                     learnedAt: Date(timeIntervalSince1970: 1_000))
        let second = VeilLearnedFront(address: "f.example:443", sni: "f.example", spki: pinB,
                                      learnedAt: Date(timeIntervalSince1970: 2_000))
        let merged = VeilLearnedFrontCore.merge([first], adding: second)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.spki, pinB)
    }

    func testMergeKeepsNewestFirstAndEvictsOldest() {
        var entries: [VeilLearnedFront] = []
        for i in 0..<VeilLearnedFrontCore.maxEntries {
            entries = VeilLearnedFrontCore.merge(entries, adding: VeilLearnedFront(
                address: "f\(i).example:443", sni: "f\(i).example", spki: pinA,
                learnedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + i))
            ))
        }
        XCTAssertEqual(entries.count, VeilLearnedFrontCore.maxEntries)

        let newest = VeilLearnedFront(address: "new.example:443", sni: "new.example", spki: pinB,
                                      learnedAt: Date(timeIntervalSince1970: 9_000))
        let merged = VeilLearnedFrontCore.merge(entries, adding: newest)
        XCTAssertEqual(merged.count, VeilLearnedFrontCore.maxEntries)
        XCTAssertEqual(merged.first?.address, "new.example:443")
        XCTAssertFalse(merged.contains { $0.address == "f0.example:443" }, "oldest should be evicted")
    }

    // MARK: - store

    func testSaveThenReadBack() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.save(address: "front-1.example:443", sni: "front-1.example", spki: pinA))
        XCTAssertEqual(store.pin(for: "front-1.example:443"), pinA)
        XCTAssertEqual(store.sni(for: "front-1.example:443"), "front-1.example")
        XCTAssertEqual(store.addresses(), ["front-1.example:443"])
    }

    func testLookupIsCaseInsensitiveOnAddress() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.save(address: "Front-1.Example:443", sni: "", spki: pinA))
        XCTAssertEqual(store.pin(for: "front-1.example:443"), pinA)
        XCTAssertEqual(store.pin(for: "FRONT-1.EXAMPLE:443"), pinA)
    }

    func testUnknownAddressHasNoPin() {
        let (store, _) = makeStore()
        XCTAssertNil(store.pin(for: "front-1.example:443"))
        XCTAssertNil(store.sni(for: "front-1.example:443"))
        XCTAssertTrue(store.addresses().isEmpty)
    }

    func testSaveRefusesMalformedTupleAndPersistsNothing() {
        let (store, backing) = makeStore()
        XCTAssertFalse(store.save(address: "front-1.example:443", sni: "front-1.example", spki: "nope"))
        XCTAssertEqual(backing.saveCount, 0, "a malformed tuple must not reach persistence")
        XCTAssertNil(store.pin(for: "front-1.example:443"))
    }

    func testSaveReportsPersistenceFailure() {
        // The caller must be able to treat this as a refusal to import — never as a
        // reason to dial the address without a pin.
        let (store, backing) = makeStore()
        backing.saveSucceeds = false
        XCTAssertFalse(store.save(address: "front-1.example:443", sni: "front-1.example", spki: pinA))
        XCTAssertNil(store.pin(for: "front-1.example:443"))
    }

    func testSecondImportReplacesTheActiveFront() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.save(address: "front-1.example:443", sni: "front-1.example", spki: pinA,
                                 now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertTrue(store.save(address: "front-2.example:443", sni: "front-2.example", spki: pinB,
                                 now: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(store.mostRecent()?.address, "front-2.example:443")
        XCTAssertEqual(store.addresses().first, "front-2.example:443")
        // The earlier front is kept, not dropped: it is still a valid anchor to fall
        // back to when the new one is blocked.
        XCTAssertEqual(store.pin(for: "front-1.example:443"), pinA)
    }

    func testRemoveAndClear() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.save(address: "front-1.example:443", sni: "", spki: pinA))
        XCTAssertTrue(store.save(address: "front-2.example:443", sni: "", spki: pinB))
        XCTAssertTrue(store.remove("FRONT-1.EXAMPLE:443"))
        XCTAssertNil(store.pin(for: "front-1.example:443"))
        XCTAssertEqual(store.pin(for: "front-2.example:443"), pinB)
        store.clear()
        XCTAssertTrue(store.addresses().isEmpty)
    }

    func testSurvivesARestartOfTheStore() {
        let backing = MemoryLearnedFrontPersistence()
        XCTAssertTrue(VeilLearnedFrontStore(persistence: backing)
            .save(address: "front-1.example:443", sni: "front-1.example", spki: pinA))
        // A second instance reads the same backing — the in-memory cache is not the
        // source of truth.
        XCTAssertEqual(VeilLearnedFrontStore(persistence: backing).pin(for: "front-1.example:443"), pinA)
    }

    func testCorruptPersistedBlobReadsAsEmptyRatherThanCrashing() {
        let backing = MemoryLearnedFrontPersistence()
        backing.data = Data("not json".utf8)
        XCTAssertTrue(VeilLearnedFrontStore(persistence: backing).addresses().isEmpty)
    }


    // MARK: - Plumbing: a learned front is never dialed unpinned

    /// Saves a learned front into the shared (Keychain-backed) store for the duration of
    /// `body`. The shared store is deliberate: these tests are about the *wiring*, and an
    /// injected instance would not exercise it.
    private func withLearnedFront(
        address: String, sni: String, pin: String,
        _ body: () throws -> Void
    ) throws {
        let store = VeilLearnedFrontStore.shared
        try XCTSkipUnless(
            store.save(address: address, sni: sni, spki: pin),
            "Keychain unavailable in this test environment"
        )
        defer { _ = store.remove(address) }
        try body()
    }

    func testLearnedAddressLeadsTheCandidateList() throws {
        // `RelayPool.best()` is `min(by:)` on the failure score and `updateRelays` rebuilds
        // the pool with an empty failure map, so after an import everything ties at zero and
        // position decides. Leading is what makes a freshly vouched front the one tried.
        let address = "learned-order-test.invalid:443"
        try withLearnedFront(address: address, sni: "learned-order-test.invalid",
                             pin: String(repeating: "1", count: 64)) {
            let candidates = VeilRelaySelector.cachedRelayAddresses()
            XCTAssertEqual(candidates.first, address)
            XCTAssertEqual(candidates.filter { $0 == address }.count, 1, "must not be duplicated")
            XCTAssertTrue(candidates.contains(VEILConfig.ruRelayAddress),
                          "seed relays remain in the pool as fallback")
        }
    }

    func testSnapshotBuildsTheLearnedFrontWithItsPinAndSNI() throws {
        // The branch this covers exists because the general resolution below it drops the
        // pin for exactly this shape — an address unknown to both the seed maps and the
        // manifest, ending in :443 — and would build a relay with `pinnedSpki == nil`.
        let address = "learned-build-test.invalid:443"
        let pin = String(repeating: "2", count: 64)
        try withLearnedFront(address: address, sni: "learned-build-test.invalid", pin: pin) {
            let relays = ConnectionLoopRelayBridge.snapshotRelays()
            let built = relays.first { $0.address == address }
            XCTAssertNotNil(built, "a learned address must reach the relay pool")
            XCTAssertEqual(built?.pinnedSpki, pin)
            XCTAssertEqual(built?.tlsServerName, "learned-build-test.invalid")
        }
    }

    func testEffectorRefusesToDialALearnedFrontWithoutItsPin() async throws {
        // Simulates the plumbing bug the guard exists for: the address is learned, but the
        // relay reaching the effector carries no pin. The expected outcome is a refusal
        // before `veil_start`, not a connection.
        let address = "learned-effector-test.invalid:443"
        let pin = String(repeating: "3", count: 64)
        let store = VeilLearnedFrontStore.shared
        try XCTSkipUnless(
            store.save(address: address, sni: "learned-effector-test.invalid", spki: pin),
            "Keychain unavailable in this test environment"
        )
        defer { _ = store.remove(address) }

        let unpinned = VeilRelay(
            address: address, bridgeCert: "", iatMode: .enabled,
            tlsServerName: "learned-effector-test.invalid", pinnedSpki: nil
        )
        let effector = NativeProxyEffector(initialRelays: [unpinned], blockedPenalty: [:])
        let event = await effector.start()
        guard case .proxyStartFailed(let relay, let reason) = event else {
            return XCTFail("expected a refusal, got \(event)")
        }
        XCTAssertEqual(relay, address)
        XCTAssertTrue(reason.contains("pin"), "reason should name the missing pin, got: \(reason)")
    }

    // MARK: - Import pins nothing it has not verified

    func testImportOfAnUnsignedBlobPinsNothing() {
        // The order inside `importBlob` is load-bearing: signature, then inner capability,
        // then pin. A blob that fails verification must leave no trusted address behind —
        // otherwise anyone able to hand the user a QR could introduce a front.
        let address = "learned-import-test.invalid:443"
        let blob: [String: Any] = [
            "relay": address,
            "sni": "learned-import-test.invalid",
            "spki": String(repeating: "4", count: 64),
            "capability": "AAAA",
            "exp": NSNumber(value: Int64(Date().timeIntervalSince1970) + 86_400),
            "signature": "ed25519:" + Data(repeating: 0, count: 64).base64EncodedString(),
        ]
        let json = try! JSONSerialization.data(withJSONObject: blob)
        let encoded = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let result = VeilConfigImporter.importBlob(encoded)
        switch result {
        case .success:
            XCTFail("an unsigned blob must not import")
        case .failure:
            XCTAssertNil(VeilLearnedFrontStore.shared.pin(for: address),
                         "a refused import must not leave a pinned address")
        }
    }

    func testImportOfMalformedInputPinsNothing() {
        let result = VeilConfigImporter.importBlob("not-a-blob")
        guard case .failure = result else { return XCTFail("expected failure") }
    }

    // MARK: - The constraint

    func testLearnedPinDoesNotBecomeAnIslandRelayIdentity() throws {
        // `VeilLocalDiscovery.trustedSPKIs()` is keyed by SPKI with NO address, and
        // `accept(spki:trusted:)` asks only for membership. A voucher front's SPKI is
        // public to everyone who photographed the QR, so if a learned pin joined that
        // set, a LAN advert could claim that identity at any address it likes.
        //
        // This test uses the shared (Keychain-backed) store deliberately: an isolated
        // instance would pass trivially. It is the *wiring* that must stay absent.
        let store = VeilLearnedFrontStore.shared
        let address = "learned-front-test.invalid:443"
        let pin = String(repeating: "c", count: 64)

        try XCTSkipUnless(
            store.save(address: address, sni: "learned-front-test.invalid", spki: pin),
            "Keychain unavailable in this test environment"
        )
        defer { _ = store.remove(address) }

        XCTAssertEqual(store.pin(for: address), pin, "precondition: the pin really is learned")
        XCTAssertFalse(
            VeilLocalDiscovery.trustedSPKIs().contains(pin),
            "a learned front must anchor its own address only, never a LAN-advertised identity"
        )
    }

    func testLearnedPinIsAcceptedByRelayTrustForItsOwnAddress() throws {
        // The other half of the same wiring: VeilRelayTrust must consult the store, so a
        // learned address is no longer `.unknownRelay`. The capability is garbage here,
        // so the expected outcome is the *capability* rejection, not the coordinate one.
        let store = VeilLearnedFrontStore.shared
        let address = "learned-trust-test.invalid:443"
        let pin = String(repeating: "d", count: 64)

        try XCTSkipUnless(
            store.save(address: address, sni: "learned-trust-test.invalid", spki: pin),
            "Keychain unavailable in this test environment"
        )
        defer { _ = store.remove(address) }

        let rejection = VeilRelayTrust.verify(
            relayAddress: address, spki: pin,
            capabilityB64: "not-a-capability", capabilityVersion: 1
        )
        switch rejection {
        case .invalidCapability:
            break // coordinates accepted, capability refused — exactly right
        default:
            XCTFail("learned coordinates should pass the address/SPKI gates, got \(String(describing: rejection))")
        }

        // And anti-redirection still holds for a learned address.
        let mismatch = VeilRelayTrust.verify(
            relayAddress: address, spki: String(repeating: "e", count: 64),
            capabilityB64: "not-a-capability", capabilityVersion: 1
        )
        guard case .spkiMismatch = mismatch else {
            return XCTFail("a different SPKI at a learned address must be refused, got \(String(describing: mismatch))")
        }
    }
}
