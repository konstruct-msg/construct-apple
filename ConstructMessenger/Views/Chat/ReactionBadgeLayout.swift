//
//  ReactionBadgeLayout.swift
//  Construct Messenger
//

import CoreGraphics

/// A reaction badge hangs outside the bubble, but that visual overlap is still transcript
/// geometry. Reserve the same distance that the badge is offset so the next row cannot clip it.
enum ReactionBadgeLayout {
    /// How far the chip hangs below the content. `badgeOverlap` assumes a bubble's bottom pad
    /// under the last line. A caption under a photo has none — it is bare text at the edge — so
    /// the chip hangs that pad further, or it sits on the caption's last line (owner, 2026-10-19).
    static func hang(endsInBareText: Bool) -> CGFloat {
        ChatUIConstants.Reaction.badgeOverlap + (endsInBareText ? ChatUIConstants.Bubble.verticalPadding : 0)
    }

    static func reservedOverflow(hasBadges: Bool, endsInBareText: Bool = false) -> CGFloat {
        hasBadges ? hang(endsInBareText: endsInBareText) : 0
    }
}
