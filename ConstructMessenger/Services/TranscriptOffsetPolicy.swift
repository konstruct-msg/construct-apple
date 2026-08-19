//
//  TranscriptOffsetPolicy.swift
//  Construct Messenger
//
//  Where the transcript's content offset goes when the content changes size.
//
//  This is the primitive SwiftUI does not have, and the only reason the scroll container moves to
//  UIKit — see `decisions/chat-transcript-uikit-scroll-container.md`. Both defects the migration
//  measured are the same missing sentence: *keep the offset while the content changes*.
//
//    - `.scrollPosition(id:)` moved a bound row by the full inserted height on a prepend
//      (PR-0 spike, 2026-08-19: 2859pt).
//    - `.defaultScrollAnchor(.bottom)` lands on the first layout, and on that layout the
//      transcript is empty — so a 40-message chat opened on its oldest message.
//
//  Three rules replace both. They are pure so a test can reach them without a scroll view, and so
//  the arithmetic can be argued about separately from the plumbing that applies it.
//

import CoreGraphics

enum TranscriptOffsetPolicy {

    /// What to do with the content offset after a layout pass changed the content.
    enum Action: Equatable {
        case none
        /// Put the newest message at the bottom edge. Never animated: an animated offset
        /// interpolates while an inset may still be moving, which is the window the old delay
        /// series existed to chase.
        case land(offsetY: CGFloat)
        /// Keep the reader exactly where they were, by moving the offset the same distance the
        /// content above them moved.
        case hold(offsetY: CGFloat)
    }

    /// The offset at which the last row sits against the bottom edge.
    ///
    /// `bottomInset` is the composer's measured height. It is part of the scrollable range rather
    /// than something the content has to leave room for twice.
    static func bottomOffset(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(0, contentHeight + bottomInset - viewportHeight)
    }

    /// - Parameters:
    ///   - anchorShift: how far the held row moved in content coordinates during this pass, or nil
    ///     when there is no held row or its frame is not known yet. This is the exact measurement
    ///     and the reason the rule needs no guess about *where* the growth happened: a prepend and
    ///     a photo finishing its decode above the reader are the same event, and the anchor sees
    ///     both. Comparing content heights cannot — growth above and growth below produce the same
    ///     number.
    static func action(
        mode: ChatViewport.Mode,
        layoutPrimed: Bool,
        contentHeight: CGFloat,
        previousContentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat,
        currentOffsetY: CGFloat,
        anchorShift: CGFloat?
    ) -> Action {
        // Nothing is laid out. Acting here is what made an unmeasured stack read as a landed tail.
        guard contentHeight > 0, viewportHeight > 0 else { return .none }

        let bottom = bottomOffset(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            bottomInset: bottomInset
        )

        // 1. The tail has never landed. This is the one that `.defaultScrollAnchor(.bottom)` could
        //    not do, because it fires on the first layout and the transcript arrives after it.
        //    Deterministic, once, and it does not care when the content showed up.
        if !layoutPrimed { return .land(offsetY: bottom) }

        switch mode {
        case .following:
            // 2. Following means the newest message is visible. The content grew, so the bottom
            //    moved, so the offset follows it. No timer, no series, no animation.
            guard contentHeight != previousContentHeight else { return .none }
            return .land(offsetY: bottom)

        case .readingHistory:
            // 3. Somebody is reading. Whatever grew above them must not move them.
            guard let shift = anchorShift, shift != 0 else { return .none }
            return .hold(offsetY: max(0, currentOffsetY + shift))
        }
    }
}
