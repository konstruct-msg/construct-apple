//
//  QuicSuppressionLedgerTests.swift
//  ConstructMessengerTests
//
//  2026-08-11, one phone moving between Wi-Fi and cellular on a censored network:
//
//      06:27:34  Fast-UDP open failure #1/1 [accept_timeout] (network rung 1)
//      06:27:34  Fast-UDP (QUIC/H3) suppressed 3600s on this network — using H2 (rung 2)
//      06:31:48  Network reachability changed: ONLINE (cellular)     ← ladder cleared
//      06:38:02  Network reachability changed: ONLINE (wifi)         ← back where we started
//      06:38:35  Fast-UDP open failure #1/2 [stream_failure] (network rung 0)
//      06:38:44  Fast-UDP open failure #2/2 [stream_failure] (network rung 0)
//      06:38:44  Fast-UDP (QUIC/H3) suppressed 300s on this network — using H2 (rung 1)
//
//  Eleven minutes after deciding this Wi-Fi deserved an hour of suppression, the device returned
//  to it at rung 0 and re-learned the same thing from scratch — two failed opens plus two more
//  stream-open timeouts, all of it visible to the user as the stream dropping. The ladder was
//  cleared on every path change (correct: a new network deserves a probe) and there was only one
//  persisted slot, so leaving a network erased what had been learned about it.
//

import XCTest
@testable import Construct_Messenger

final class QuicSuppressionLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_430_000)
    private let homeWifi = "wifi-home"
    private let cellular = "cellular"

    private func record(strikes: Int, secondsLeft: TimeInterval?, age: TimeInterval = 0)
        -> QuicSuppressionLedger.Record {
        QuicSuppressionLedger.Record(
            strikes: strikes,
            suppressedUntil: secondsLeft.map { now.addingTimeInterval($0) },
            updatedAt: now.addingTimeInterval(-age)
        )
    }

    // MARK: - The incident

    func testReturningToAJudgedNetworkKeepsItsRung() {
        // The whole bug. The Wi-Fi had been suppressed for an hour at rung 2; after a trip to
        // cellular and back it must not be rung 0 again.
        let store = [homeWifi: record(strikes: 2, secondsLeft: 3600)]
        let state = QuicSuppressionLedger.stateOnArrival(at: homeWifi, store: store, now: now)
        XCTAssertEqual(state.strikes, 2)
        XCTAssertNotNil(state.suppressedUntil, "an hour of suppression survived a walk to the kitchen")
    }

    func testALapsedWindowKeepsTheRungAndDropsTheWindow() {
        // The two facts expire differently: the window says "don't try yet", the rung says "how
        // badly this went last time". Losing the rung is how the ladder fails to converge.
        let store = [homeWifi: record(strikes: 2, secondsLeft: -1)]
        let state = QuicSuppressionLedger.stateOnArrival(at: homeWifi, store: store, now: now)
        XCTAssertEqual(state.strikes, 2, "an expired window is permission to probe, not to forget")
        XCTAssertNil(state.suppressedUntil)
    }

    func testLeavingANetworkDoesNotEraseItsRecord() {
        // The v2 shape: one slot, cleared on the way out. Recording what cellular taught us must
        // leave the Wi-Fi entry alone.
        var store = [homeWifi: record(strikes: 2, secondsLeft: 3600)]
        store = QuicSuppressionLedger.remembering(
            store, network: cellular, strikes: 1, suppressedUntil: now.addingTimeInterval(300), now: now
        )
        XCTAssertEqual(store[homeWifi]?.strikes, 2, "the network we left was forgotten")
        XCTAssertEqual(store[cellular]?.strikes, 1)
    }

    // MARK: - What must NOT happen

    func testAnUnknownNetworkIsProbedNotSuppressed() {
        // The behaviour the network-change reset exists for, and the one this must not break: a
        // network we have never judged gets a clean run at QUIC. Inheriting the previous network's
        // rung would make a working network look broken.
        let store = [homeWifi: record(strikes: 3, secondsLeft: 86_400)]
        let state = QuicSuppressionLedger.stateOnArrival(at: "cafe-wifi", store: store, now: now)
        XCTAssertEqual(state.strikes, 0)
        XCTAssertNil(state.suppressedUntil)
    }

    func testAnUnknownNetworkIdentityIsNeverStoredOrRead() {
        // The monitor has not reported yet. An unattributed record is worse than none — it would be
        // applied to whatever network happens to come next.
        let state = QuicSuppressionLedger.stateOnArrival(at: "", store: [homeWifi: record(strikes: 2, secondsLeft: 60)], now: now)
        XCTAssertEqual(state.strikes, 0)
        let store = QuicSuppressionLedger.remembering([:], network: "", strikes: 3, suppressedUntil: now, now: now)
        XCTAssertTrue(store.isEmpty)
    }

    func testANetworkThatWorksReleasesItsSlot() {
        // QUIC proved healthy → nothing to remember. Holding the slot would evict a network we do
        // have an opinion about.
        var store = [homeWifi: record(strikes: 2, secondsLeft: 3600)]
        store = QuicSuppressionLedger.remembering(store, network: homeWifi, strikes: 0, suppressedUntil: nil, now: now)
        XCTAssertNil(store[homeWifi])
    }

    // MARK: - Bounded storage

    func testTheLedgerStaysBoundedAndEvictsTheStalest() {
        var store: [String: QuicSuppressionLedger.Record] = [:]
        // Oldest first, so "net0" is the stalest.
        for i in 0..<QuicSuppressionLedger.maxNetworks {
            let age = TimeInterval(QuicSuppressionLedger.maxNetworks - i) * 3600
            store["net\(i)"] = record(strikes: 1, secondsLeft: 600, age: age)
        }
        XCTAssertEqual(store.count, QuicSuppressionLedger.maxNetworks)

        store = QuicSuppressionLedger.remembering(store, network: "new", strikes: 1, suppressedUntil: now.addingTimeInterval(600), now: now)

        XCTAssertEqual(store.count, QuicSuppressionLedger.maxNetworks, "a travel diary is not a transport preference")
        XCTAssertNotNil(store["new"], "the entry we just wrote must never be the one evicted")
        XCTAssertNil(store["net0"], "eviction must take the least-recently-updated")
        XCTAssertNotNil(store["net\(QuicSuppressionLedger.maxNetworks - 1)"])
    }

    // MARK: - Keying

    func testTheStoredKeyDoesNotContainTheNetworkIdentity() {
        // A list of networks the device has been on is movement history. We only need equality, so
        // the identity itself is never written down.
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = QuicSuppressionLedger.key(for: "MyHomeSSID|192.168.1.1", salt: salt)
        XCTAssertFalse(key.contains("MyHomeSSID"))
        XCTAssertFalse(key.contains("192.168.1.1"))
        XCTAssertEqual(key.count, 64, "SHA256 hex")
    }

    func testTheSameNetworkKeysStablyAndDifferentNetworksDoNotCollide() {
        let salt = Data(repeating: 7, count: 16)
        XCTAssertEqual(
            QuicSuppressionLedger.key(for: "net-a", salt: salt),
            QuicSuppressionLedger.key(for: "net-a", salt: salt),
            "an unstable key means the ladder never finds its own record"
        )
        XCTAssertNotEqual(
            QuicSuppressionLedger.key(for: "net-a", salt: salt),
            QuicSuppressionLedger.key(for: "net-b", salt: salt)
        )
    }

    func testADifferentInstallSaltProducesADifferentKey() {
        // What stops stored digests being checked against a list of known SSIDs.
        XCTAssertNotEqual(
            QuicSuppressionLedger.key(for: "net-a", salt: Data(repeating: 1, count: 16)),
            QuicSuppressionLedger.key(for: "net-a", salt: Data(repeating: 2, count: 16))
        )
    }

    func testAnEmptyIdentityHasNoKey() {
        XCTAssertEqual(QuicSuppressionLedger.key(for: "", salt: Data(repeating: 1, count: 16)), "")
    }
}
