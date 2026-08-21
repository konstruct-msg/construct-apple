//
//  ReactionCapsulePlacement.swift
//  Construct Messenger
//
//  Where the quick-set capsule sits relative to the bubble. Prefer below when
//  it fits; otherwise the side with more room. Timestamp is not an input —
//  the badge (not the capsule) is what must avoid the time corner.
//

import CoreGraphics

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
}
