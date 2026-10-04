//
//  ReactionBadgeLayout.swift
//  Construct Messenger
//

import CoreGraphics

/// A reaction badge hangs outside the bubble, but that visual overlap is still transcript
/// geometry. Reserve the same distance that the badge is offset so the next row cannot clip it.
enum ReactionBadgeLayout {
    static func reservedOverflow(hasBadges: Bool) -> CGFloat {
        hasBadges ? ChatUIConstants.Reaction.badgeOverlap : 0
    }
}
