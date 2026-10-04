//
//  ReactionQuickSetTests.swift
//  ConstructMessengerTests
//
//  The menu's reaction row becomes the user's own gradually, and without reshuffling.
//  Each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class ReactionQuickSetTests: XCTestCase {

    private func recording(_ emoji: [String], from start: ReactionQuickSet = .initial) -> ReactionQuickSet {
        emoji.reduce(start) { $0.recording($1) }
    }

    func testAFreshRowIsThePopularSet() {
        XCTAssertEqual(ReactionQuickSet.initial.slots, ReactionQuickSet.defaults)
        XCTAssertTrue(ReactionQuickSet.initial.isWellFormed)
    }

    /// A one-off reaction does not displace the popular set; three in a row do.
    ///
    /// Mutation: seed the defaults at 0, or let any score beat the weakest — the one-off enters.
    func testANewEmojiEntersOnlyAfterRepeatedUse() {
        XCTAssertFalse(recording(["👍"]).slots.contains("👍"), "one use is not a habit")
        XCTAssertFalse(recording(["👍", "👍"]).slots.contains("👍"))
        XCTAssertTrue(recording(["👍", "👍", "👍"]).slots.contains("👍"))
    }

    /// The newcomer takes the evicted emoji's slot and every other emoji keeps its position.
    ///
    /// Mutation: sort the row by score — positions move and this reddens.
    func testAnEntrantTakesTheEvictedSlotAndNothingElseMoves() {
        let before = ReactionQuickSet.initial.slots
        let after = recording(["👍", "👍", "👍"]).slots
        let changed = before.indices.filter { before[$0] != after[$0] }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(after[changed[0]], "👍")
    }

    /// The defaults give way last-first, so the like at the head of the row is the last to go.
    ///
    /// Mutation: seed every default equally — the first tie, ❤️, is evicted first.
    func testTheLeastPopularDefaultGivesWayFirst() {
        XCTAssertEqual(recording(["👍", "👍", "👍"]).slots.last, "👍")
        XCTAssertEqual(recording(["👍", "👍", "👍"]).slots.first, ReactionReducer.likeEmoji)
    }

    /// What the user keeps using stays, whatever else comes and goes.
    func testAnEmojiInUseIsNotEvicted() {
        var set = ReactionQuickSet.initial
        for _ in 0..<20 {
            set = set.recording("😂").recording("👍").recording("🙏").recording("👀")
        }
        for kept in ["😂", "👍", "🙏", "👀"] {
            XCTAssertTrue(set.slots.contains(kept), kept)
        }
        XCTAssertTrue(set.isWellFormed)
    }

    /// Emoji that fell out of use are forgotten, so the stored table stays small.
    ///
    /// Mutation: drop the `forgetBelow` filter — the table keeps every emoji ever sent.
    func testOldCountsAreForgotten() {
        var set = recording(["🦄"])
        for _ in 0..<60 { set = set.recording("❤️") }
        XCTAssertNil(set.scores["🦄"])
        XCTAssertLessThanOrEqual(set.scores.count, ReactionQuickSet.size)
    }

    @MainActor
    func testTheStoreKeepsTheRowAcrossLaunchesAndRefusesAMalformedOne() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReactionQuickSetTests"))
        defaults.removePersistentDomain(forName: "ReactionQuickSetTests")
        defer { defaults.removePersistentDomain(forName: "ReactionQuickSetTests") }

        let store = ReactionQuickSetStore(defaults: defaults)
        for _ in 0..<3 { store.record("👍") }
        XCTAssertEqual(ReactionQuickSetStore(defaults: defaults).slots, store.slots)

        defaults.set(Data("{\"slots\":[\"👍\",\"👍\"],\"scores\":{}}".utf8), forKey: ReactionQuickSetStore.defaultsKey)
        XCTAssertEqual(ReactionQuickSetStore(defaults: defaults).slots, ReactionQuickSet.defaults)
    }
}
