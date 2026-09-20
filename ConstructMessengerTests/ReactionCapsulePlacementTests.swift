//
//  ReactionCapsulePlacementTests.swift
//  ConstructMessengerTests
//
//  Capsule prefers below when it fits. The like badge must not sit on the
//  timestamp corner — that stacking is what testers called out.
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

final class ReactionCapsulePlacementTests: XCTestCase {

    private let height: CGFloat = 44

    func testBothFit_PrefersBelow() {
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 200, spaceBelow: 200, capsuleHeight: height),
            .below
        )
    }

    func testOnlyAboveFits_GoesAbove() {
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 80, spaceBelow: 10, capsuleHeight: height),
            .above
        )
    }

    func testOnlyBelowFits_GoesBelow() {
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 10, spaceBelow: 80, capsuleHeight: height),
            .below
        )
    }

    func testNeitherFits_PicksTheLargerGap() {
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 30, spaceBelow: 20, capsuleHeight: height),
            .above
        )
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 20, spaceBelow: 30, capsuleHeight: height),
            .below
        )
    }

    func testEqualShortGaps_PreferBelow() {
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 20, spaceBelow: 20, capsuleHeight: height),
            .below
        )
    }

    /// Keyboard + composer sit in `visibleBottom`; if we only subtracted 54pt from the
    /// screen, a photo just above the keyboard looked like it had room below.
    func testKeyboardEatingTheBelowGap_GoesAbove() {
        let bubbleMaxY: CGFloat = 520
        let keyboardTop: CGFloat = 560
        let composer: CGFloat = 54
        let below = ReactionCapsulePlacement.spaceBelow(
            bubbleMaxY: bubbleMaxY,
            visibleBottom: keyboardTop,
            composerHeight: composer
        )
        XCTAssertLessThan(below, height)
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 200, spaceBelow: below, capsuleHeight: height),
            .above
        )
    }

    func testNoKeyboardLeavesRoomBelow() {
        let below = ReactionCapsulePlacement.spaceBelow(
            bubbleMaxY: 400,
            visibleBottom: 800,
            composerHeight: 54
        )
        XCTAssertGreaterThan(below, height)
        XCTAssertEqual(
            ReactionCapsulePlacement.decide(spaceAbove: 200, spaceBelow: below, capsuleHeight: height),
            .below
        )
    }

    func testBadgeHangClearsTheLastLineOfText() {
        XCTAssertGreaterThan(
            ChatUIConstants.Reaction.badgeOverlap,
            ChatUIConstants.Bubble.verticalPadding,
            "an offset no larger than the bubble's bottom pad still covers the glyphs"
        )
        XCTAssertGreaterThanOrEqual(
            ChatUIConstants.Reaction.badgeOverlap,
            ChatUIConstants.Reaction.badgeFontSize,
            "the chip is taller than the last line; hang at least that far or it sits on the letters"
        )
    }

    func testSentLikeIsNotOnTheTimestampCorner() {
        XCTAssertEqual(
            ChatUIConstants.Reaction.badgeAlignment(isSentByMe: true),
            .bottomLeading,
            "sent time is trailing; the like belongs on the other corner"
        )
        XCTAssertEqual(
            ChatUIConstants.Reaction.badgeAlignment(isSentByMe: false),
            .bottomTrailing,
            "received time is leading; the like belongs on the other corner"
        )
    }
}
