//
//  RelayManifestFreshnessTests.swift
//  Construct MessengerTests
//
//  The rule that makes a second manifest mirror safe rather than merely faster.
//

import XCTest
@testable import Construct_Messenger

final class RelayManifestFreshnessTests: XCTestCase {

    // MARK: - Reading signed_at

    func testReadsIso8601() {
        XCTAssertNotNil(RelayManifestFreshness.instant(from: "2026-07-13T10:29:26Z"))
    }

    func testReadsIso8601WithFractionalSeconds() {
        XCTAssertNotNil(RelayManifestFreshness.instant(from: "2026-07-13T10:29:26.512Z"))
    }

    /// `sign_relay_manifest.py` emits epoch seconds; the live manifest emits ISO-8601. Both forms
    /// are in the field, which is why the decoder in VeilCertFetcher accepts String and Int alike.
    func testReadsEpochSeconds() {
        let parsed = RelayManifestFreshness.instant(from: "1768300166")
        XCTAssertEqual(parsed?.timeIntervalSince1970, 1_768_300_166)
    }

    /// A bare year is a number, and reading it as an epoch would place the manifest half an hour
    /// into 1970 — below every real value, so it would lose every comparison and never be stored.
    func testBareYearIsNotAnEpoch() {
        XCTAssertNil(RelayManifestFreshness.instant(from: "2026"))
    }

    func testGarbageIsUnreadable() {
        XCTAssertNil(RelayManifestFreshness.instant(from: "soon"))
        XCTAssertNil(RelayManifestFreshness.instant(from: ""))
        XCTAssertNil(RelayManifestFreshness.instant(from: nil))
    }

    // MARK: - The verdict

    func testFirstManifestIsAccepted() {
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: "2026-07-13T10:29:26Z",
                                           cachedSignedAt: nil),
            .accept
        )
    }

    func testNewerIsAccepted() {
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: "2026-08-18T09:00:00Z",
                                           cachedSignedAt: "2026-07-13T10:29:26Z"),
            .accept
        )
    }

    /// The reason this type exists. Both hosts serve manifests we signed, so both verify; the one
    /// that wins the race is the one that answered first. An attacker who can slow the fresh host
    /// picks which configuration the client runs — including `bundle_signing_key`.
    func testOlderIsRejected() {
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: "2026-06-01T00:00:00Z",
                                           cachedSignedAt: "2026-07-13T10:29:26Z"),
            .rejectOlder
        )
    }

    /// Two mirrors serving the same manifest is the ordinary case, not an attack. Rejecting an
    /// identical copy would make the second fetch of the day undo the first.
    func testIdenticalTimestampIsAccepted() {
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: "2026-07-13T10:29:26Z",
                                           cachedSignedAt: "2026-07-13T10:29:26Z"),
            .accept
        )
    }

    /// Otherwise the rollback costs one deleted field.
    func testStrippedTimestampIsRejectedOnceWeHoldOne() {
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: nil,
                                           cachedSignedAt: "2026-07-13T10:29:26Z"),
            .rejectUndatable
        )
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: "not-a-date",
                                           cachedSignedAt: "2026-07-13T10:29:26Z"),
            .rejectUndatable
        )
    }

    /// A device that has never fetched has nothing to compare against, and refusing it there would
    /// mean an undated manifest could never bootstrap anyone.
    func testUndatedIsAcceptedWhenNothingIsCached() {
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: nil, cachedSignedAt: nil),
            .accept
        )
    }

    /// The two forms are compared as instants, not as strings — "1768300166" sorts below
    /// "2026-07-13…" lexicographically while being the later moment by four days.
    func testEpochAndIso8601CompareAsInstants() {
        let iso = "2026-07-13T10:29:26Z"
        let laterEpoch = String(Int(RelayManifestFreshness.instant(from: iso)!
            .addingTimeInterval(4 * 86_400).timeIntervalSince1970))
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: laterEpoch, cachedSignedAt: iso),
            .accept
        )
        XCTAssertEqual(
            RelayManifestFreshness.verdict(candidateSignedAt: iso, cachedSignedAt: laterEpoch),
            .rejectOlder
        )
    }
}
