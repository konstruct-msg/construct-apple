//
//  ReactionCapsulePlacement.swift
//  Construct Messenger
//
//  Where the quick-set capsule sits relative to the bubble. Prefer below when
//  it fits; otherwise the side with more room. Timestamp is not an input —
//  the badge (not the capsule) is what must avoid the time corner.
//
//  **The space this measures is screen room, not free room**, and since 2026-08-22 that is all it
//  claims. The capsule is a row of the bubble's stack rather than an overlay on it, so it cannot
//  cover a neighbouring message whichever side it lands on; what is left to decide is only whether
//  the reader would have to scroll to see it. While the capsule *was* an overlay this same
//  measurement was doing duty as an answer to "will it cover anything", which it never was — below
//  always fits on screen for a message in the middle of a transcript, and below always covered the
//  message after it.
//

import CoreGraphics
import SwiftUI

/// The native context menu is still dismissing when its React action runs. Its transaction can
/// otherwise animate the newly inserted row from zero height even when the caller supplies
/// `animation = nil`, leaving only a clipped strip until the dismissal settles.
enum ReactionCapsulePresentation {
    static var immediateInsertion: Transaction {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return transaction
    }
}

enum ReactionCapsulePlacement: Equatable {
    case above
    case below

    static func decide(
        spaceAbove: CGFloat,
        spaceBelow: CGFloat,
        capsuleHeight: CGFloat
    ) -> Self {
        if spaceBelow >= capsuleHeight { return .below }
        if spaceAbove >= capsuleHeight { return .above }
        return spaceBelow >= spaceAbove ? .below : .above
    }

    /// Room under the bubble before the composer (which sits on the keyboard when it is up).
    ///
    /// `visibleBottom` is the top of the keyboard, or the window bottom when there is none.
    /// Subtracting `composerHeight` is what the old `UIScreen.bounds - 54` skipped: with the
    /// keyboard open that overstated the gap, the capsule went `.below`, and it rendered in
    /// the sliver between the photo and the glass — clipped for a beat until layout settled.
    static func spaceBelow(
        bubbleMaxY: CGFloat,
        visibleBottom: CGFloat,
        composerHeight: CGFloat
    ) -> CGFloat {
        visibleBottom - composerHeight - bubbleMaxY
    }
}
