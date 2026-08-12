//
//  ThumbnailBudgetTests.swift
//  ConstructMessengerTests
//
//  Device, 2026-08-12 10:53:18 — two photos from a 3024×4032 camera roll, against a cap the code
//  described as "a byte count rather than a hope":
//
//      Thumbnail generated: 31872 bytes
//      Thumbnail generated: 30803 bytes
//
//  `binarySearchQuality` floors quality at 0.35 and returns nil when even that overflows the
//  budget, and the caller then returned the q=0.70 rendering it had made first — shipping the
//  largest candidate it had produced on the path that exists to produce a smaller one.
//
//  Photos no longer send a thumbnail on the wire, so that only cost local disk. Two paths still do
//  send one and were sized by this: a video poster, always, and a photo whose BlurHash failed to
//  build. At 31 KB a video poster is eight wire messages.
//

import XCTest
import CoreGraphics
@testable import Construct_Messenger

final class ThumbnailBudgetTests: XCTestCase {

    private let budget = ThumbnailBudget.maxBytes

    // MARK: - The normal case

    /// Largest dimension that fits, not merely any that fits — a preview should be as good as the
    /// budget allows.
    func testItTakesTheLargestRenderingThatFits() throws {
        let index = try XCTUnwrap(ThumbnailBudget.choose(candidates: [
            (dimension: 320, bytes: budget - 1),
            (dimension: 240, bytes: 4_000),
            (dimension: 180, bytes: 2_000),
        ]))
        XCTAssertEqual(index, 0)
    }

    func testItWalksDownUntilSomethingFits() throws {
        let index = try XCTUnwrap(ThumbnailBudget.choose(candidates: [
            (dimension: 320, bytes: 31_872),   // the device number
            (dimension: 240, bytes: 18_000),
            (dimension: 180, bytes: 9_000),
        ]))
        XCTAssertEqual(index, 2)
    }

    /// Exactly-at-budget fits. A second, smaller candidate is required for this to mean anything:
    /// with one candidate the "nothing fits, ship the smallest" branch also returns index 0, so a
    /// `<` instead of `<=` passed the test while changing the behaviour. It cost a surviving
    /// mutation to notice.
    func testTheBudgetIsInclusive() throws {
        let index = try XCTUnwrap(ThumbnailBudget.choose(candidates: [
            (dimension: 320, bytes: budget),
            (dimension: 240, bytes: budget - 5_000),
        ]))
        XCTAssertEqual(index, 0, "an exact fit is a fit; index 1 means the comparison lost its equals")
    }

    // MARK: - The incident

    /// Nothing fits. The old code returned the first rendering — the biggest. It must return the
    /// smallest, which is the whole point of having walked the ladder.
    func testWhenNothingFitsItShipsTheSmallestNotTheFirst() throws {
        let index = try XCTUnwrap(ThumbnailBudget.choose(candidates: [
            (dimension: 320, bytes: 31_872),
            (dimension: 240, bytes: 22_000),
            (dimension: 180, bytes: 16_000),
            (dimension: 128, bytes: 13_000),
        ]))
        XCTAssertEqual(index, 3, "shipping index 0 here is the bug this replaces")
    }

    /// The ladder is ordered by dimension, but nothing guarantees bytes fall monotonically with it
    /// — a smaller rendering of a noisy image can encode larger. The choice is by bytes.
    func testItPicksBySizeNotByPositionWhenNothingFits() throws {
        let index = try XCTUnwrap(ThumbnailBudget.choose(candidates: [
            (dimension: 320, bytes: 30_000),
            (dimension: 240, bytes: 14_000),
            (dimension: 180, bytes: 15_000),
        ]))
        XCTAssertEqual(index, 1)
    }

    // MARK: - Degenerate

    func testNoCandidatesMeansNoChoice() {
        XCTAssertNil(ThumbnailBudget.choose(candidates: []))
    }

    /// The ladder must stay ordered largest-first, or "the first that fits" silently becomes "the
    /// smallest that fits" and every preview is worse than it needs to be.
    func testTheLadderDescends() {
        XCTAssertEqual(ThumbnailBudget.dimensionLadder, ThumbnailBudget.dimensionLadder.sorted(by: >))
        XCTAssertEqual(ThumbnailBudget.dimensionLadder.first, 320)
    }
}
