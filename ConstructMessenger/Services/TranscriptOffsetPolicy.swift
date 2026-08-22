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

    /// The offset that brings one row to `anchor` inside the visible area.
    ///
    /// The fourth rule, and the one the migration shipped without: going to an arbitrary row.
    /// `followExplicitly` could be computed from the content height alone, so it was — and every
    /// other destination (a search hit, the parent of a reply, the voice message that just started
    /// playing) had no arithmetic at all and did nothing. `bottomOffset` answers "where is the end";
    /// this answers "where is that row".
    ///
    /// `bottomInset` is subtracted rather than ignored: it is the composer's height, so centring in
    /// `viewportHeight` would centre the row behind the glass and leave it visually low. What the
    /// reader sees is `viewportHeight - bottomInset`, and that is what the row is placed within.
    ///
    /// Clamped at both ends for the reason `.hold` is: an offset is a place scrolling could have
    /// reached, and past the end is not one. That bound was missing from `.hold` until device
    /// 2026-08-21 landed beyond the content and stayed there, with nothing downstream to bring it
    /// back — a jump to the newest message in a chat would land in exactly the same place.
    ///
    /// - Parameters:
    ///   - anchor: 0 puts the row's top at the top of the visible area, 0.5 centres it, 1 puts its
    ///     bottom at the bottom. Only the vertical component is used; the transcript does not scroll
    ///     horizontally.
    static func rowOffset(
        rowMinY: CGFloat,
        rowHeight: CGFloat,
        anchor: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let visibleHeight = max(0, viewportHeight - bottomInset)
        let target = rowMinY - (visibleHeight - rowHeight) * anchor
        let bottom = bottomOffset(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            bottomInset: bottomInset
        )
        return min(bottom, max(0, target))
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
            // Clamped at both ends, because a shift is a *correction* and a correction cannot take
            // the viewport somewhere scrolling could not. Only the lower bound was here, and the
            // upper one is what device 2026-08-21 landed past: the transcript sat with its last
            // message near the top of the screen and a screenful of void beneath it, and stayed
            // there — offset beyond the end is not a place `bottomOffset` can produce, so nothing
            // downstream brings it back.
            //
            // It went unnoticed until the day `anchorShift` was first delivered at all: this branch
            // could only return `.none` while `bindHistoryPosition` had no callers, so the missing
            // bound had nothing to be missing from.
            return .hold(offsetY: min(bottom, max(0, currentOffsetY + shift)))
        }
    }
}
