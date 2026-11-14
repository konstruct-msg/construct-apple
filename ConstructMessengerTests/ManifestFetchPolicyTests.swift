//
//  ManifestFetchPolicyTests.swift
//  ConstructMessengerTests
//
//  Each manifest fetch is a connection to the project's domain host; a routine one is answered
//  from a recent cache (TODO 162 C, 2026-10-18).
//

import XCTest
@testable import Construct_Messenger

final class ManifestFetchPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    private func fetch(urgent: Bool = false, accepted: Date? = nil, urgentAt: Date? = nil, cache: Bool = true) -> Bool {
        ManifestFetchPolicy.shouldFetch(urgent: urgent, now: now, lastAccepted: accepted, lastUrgent: urgentAt, hasCache: cache)
    }

    /// Mutation: always fetch — the routine refresh within six hours reddens.
    func testARoutineRefreshIsAnsweredFromARecentCache() {
        XCTAssertFalse(fetch(accepted: ago(3600)))
        XCTAssertTrue(fetch(accepted: ago(ManifestFetchPolicy.routineInterval)))
        XCTAssertTrue(fetch(accepted: nil))
    }

    /// Mutation: drop the `hasCache` guard — a first launch with nothing cached reddens.
    func testNothingCachedAlwaysFetches() {
        XCTAssertTrue(fetch(accepted: ago(60), cache: false))
        XCTAssertTrue(fetch(urgent: true, urgentAt: ago(60), cache: false))
    }

    /// Mutation: treat urgent as routine — the urgent fetch a minute after a routine one reddens.
    func testAnUrgentFetchSkipsTheRoutineWaitButNotItsOwn() {
        XCTAssertTrue(fetch(urgent: true, accepted: ago(60), urgentAt: nil))
        XCTAssertFalse(fetch(urgent: true, accepted: ago(60), urgentAt: ago(120)))
        XCTAssertTrue(fetch(urgent: true, accepted: ago(60), urgentAt: ago(ManifestFetchPolicy.urgentInterval)))
    }

    private let https = [URL(string: "https://example.invalid/.well-known/construct-server")!]

    private func source(urgent: Bool = false, accepted: Date? = nil, urgentAt: Date? = nil,
                        cache: Bool = true, sources: [URL]) -> ManifestFetchPolicy.Source {
        ManifestFetchPolicy.source(urgent: urgent, now: now, lastAccepted: accepted, lastUrgent: urgentAt,
                                   hasCache: cache, httpsSources: sources)
    }

    /// Todo 315: under `on` (no HTTPS source) the refresh skipped the cache — an RPC on every
    /// return to the app, which the stream waited for. Mutation: check for HTTPS sources before
    /// the cache rule — the first assertion reddens.
    func testUnderOnARecentCacheAnswersWithoutAskingTheServer() {
        XCTAssertEqual(source(accepted: ago(3600), sources: []), .cache)
        XCTAssertEqual(source(accepted: ago(ManifestFetchPolicy.routineInterval), sources: []), .serverTrust)
        XCTAssertEqual(source(urgent: true, accepted: ago(60), sources: []), .serverTrust)
    }

    /// Mutation: swap the two sources — either assertion reddens.
    func testAFetchGoesOverHTTPSWhenThereIsASourceAndThroughTheTunnelWhenNot() {
        XCTAssertEqual(source(cache: false, sources: https), .https(https))
        XCTAssertEqual(source(cache: false, sources: []), .serverTrust)
        XCTAssertEqual(source(accepted: ago(60), sources: https), .cache)
    }
}
