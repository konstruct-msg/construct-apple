//
//  ReactionBadgeLayoutTests.swift
//  ConstructMessengerTests
//
//  The like badge must not sit on the timestamp corner — that stacking is what testers called
//  out — and the room it hangs into belongs to the transcript.
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

final class ReactionBadgeLayoutTests: XCTestCase {

    func testBadgeOverflowIsPartOfTranscriptGeometry() {
        XCTAssertEqual(ReactionBadgeLayout.reservedOverflow(hasBadges: false), 0)
        XCTAssertEqual(
            ReactionBadgeLayout.reservedOverflow(hasBadges: true),
            ChatUIConstants.Reaction.badgeOverlap
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
