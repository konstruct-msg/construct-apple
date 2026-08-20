//
//  UserDefaultsFootprintTests.swift
//  ConstructMessengerTests
//
//  The report exists to answer "which of the 64 UserDefaults writers filled the domain past 4 MB".
//  Its one hard requirement is that it must not be blind to the leak that prompted it.
//

import XCTest
@testable import Construct_Messenger

final class UserDefaultsFootprintTests: XCTestCase {

    // MARK: - The blindness this report is built to avoid

    /// The actual leak: thousands of per-message keys, each individually unremarkable. A report
    /// ranked by single key would put a lone 200 KB setting on top and never mention the 3 MB
    /// spread across the family — which is how this went unnoticed long enough to hit the limit.
    func testManySmallPerMessageKeysOutrankOneLargeSetting() {
        var sizes: [String: Int] = ["construct.relayInfoCache": 200 * 1024]
        for index in 0..<3000 {
            sizes["construct.outgoingWirePayload.\(String(format: "%08x", index))-c0"] = 1024
        }

        let ranked = UserDefaultsFootprint.ranked(sizes: sizes, limit: 3)

        XCTAssertEqual(ranked.first?.name, "construct.outgoingWirePayload.*")
        XCTAssertEqual(ranked.first?.keys, 3000)
        XCTAssertEqual(ranked.first?.bytes, 3000 * 1024)
    }

    func testFamilyCollapsesUuidAndUnderscoreStyleIds() {
        XCTAssertEqual(
            UserDefaultsFootprint.family(of: "construct.outgoingWirePayload.5b1d7b0c-d529-4456"),
            "construct.outgoingWirePayload.*"
        )
        XCTAssertEqual(
            UserDefaultsFootprint.family(of: "session_last_activity_289b95ca-8260-4b99"),
            "session_last_activity_*"
        )
    }

    // MARK: - What must NOT be collapsed

    /// Without the digit-or-hyphen requirement, any eight-character run of a–f reads as an
    /// identifier, and two unrelated settings merge into one row that means nothing. `deadbeef`
    /// is the honest worst case: all hex, no digits.
    func testLetterOnlyRunsAreNotMistakenForIds() {
        XCTAssertEqual(UserDefaultsFootprint.family(of: "construct.deadbeef"), "construct.deadbeef")
        XCTAssertEqual(
            UserDefaultsFootprint.family(of: "construct.cryptoKeys.afu_migrated.v2"),
            "construct.cryptoKeys.afu_migrated.v2"
        )
    }

    /// Short ids stay put: collapsing `v1`/`v2` would merge migration flags that need to be told
    /// apart when one of them is the thing holding megabytes.
    func testShortSuffixesSurvive() {
        XCTAssertEqual(
            UserDefaultsFootprint.family(of: "construct.adMigration.serverUUID.v1.done"),
            "construct.adMigration.serverUUID.v1.done"
        )
    }

    // MARK: - Output stability

    /// Two runs of the same app state must produce the same rows in the same order, or logs from
    /// before and after a fix cannot be diffed.
    func testEqualSizedFamiliesOrderStably() {
        let sizes = ["alpha.key": 1024, "bravo.key": 1024, "charlie.key": 1024]
        let first = UserDefaultsFootprint.ranked(sizes: sizes, limit: 3)
        let second = UserDefaultsFootprint.ranked(sizes: sizes, limit: 3)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.name), ["alpha.key", "bravo.key", "charlie.key"])
    }

    func testLimitIsRespected() {
        let sizes = ["a": 5, "b": 4, "c": 3, "d": 2]
        XCTAssertEqual(UserDefaultsFootprint.ranked(sizes: sizes, limit: 2).map(\.name), ["a", "b"])
    }
}
