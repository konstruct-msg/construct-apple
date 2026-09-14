//
//  TranscriptViewportOwning+Conformances.swift
//  Construct Messenger
//
//  Both owners answering the same calls. Deleted with the protocol in PR-4.
//
//  Kept out of the two owners' own files on purpose: neither type should grow a member because the
//  other one has it. What is here is translation, and where a translation is lossy the comment says
//  so rather than inventing a value.
//

import SwiftUI

// MARK: - The owned-inset path

extension ChatViewport: TranscriptViewportOwning {

    var isFollowing: Bool { mode == .following }

    var heldMessageId: String? {
        get { positionId }
        set { positionId = newValue }
    }

    var stateDescription: String {
        "mode=\(mode) primed=\(layoutPrimed) settling=\(insetSettling)"
    }

    /// Nothing to arm. The container's `.defaultScrollAnchor(.bottom)` puts the first layout at the
    /// tail, and `layoutPrimed` closes when the geometry says it landed — measured in PR-0, where
    /// the anchor held the bottom through a growing pad with no `scrollTo` at all.
    func noteTranscriptAppeared(messageCount: Int) {}

    func updateGeometry(_ geometry: ChatScrollGeometry, messageCount: Int) {
        updateScrollOffset(
            distanceFromBottom: geometry.distanceFromBottom,
            contentFits: geometry.contentFits,
            contentHeight: geometry.contentHeight,
            visibleMinY: geometry.visibleMinY,
            messageCount: messageCount
        )
    }

    func noteScrollPhase(_ phase: ScrollPhase) {
        // A finger on the list outranks every heuristic here. Deceleration is content in motion —
        // including this path's own guest scrolls — so it is not a touch.
        switch phase {
        case .tracking, .interacting:
            noteUserInteraction()
        case .decelerating, .idle, .animating:
            break
        @unknown default:
            break
        }
    }

    /// The newest row's visibility drove the stranded recovery, and the recovery is gone: it
    /// corrected an offset, and what was wrong was that the rows were not drawn. On an eager stack
    /// they are. Left unimplemented rather than quietly forwarded somewhere, so nobody reads a
    /// forward as evidence the signal still does something.
    func noteLastMessageVisible(_ visible: Bool, searchActive: Bool) {}

    func noteComposerGeometry(composerHeight: CGFloat, safeAreaBottom: CGFloat, containerHeight: CGFloat) {
        noteInsetDelta(
            composer: composerHeight,
            safeAreaBottom: safeAreaBottom,
            containerHeight: containerHeight
        )
    }

    func shouldLoadOlderHistory(
        isSearchActive: Bool,
        isLoadingMore: Bool,
        hasMoreMessages: Bool
    ) -> Bool {
        Self.shouldLoadOlderHistory(
            layoutPrimed: layoutPrimed,
            contentFits: contentFits,
            visibleMinY: visibleMinY,
            isSearchActive: isSearchActive,
            isLoadingMore: isLoadingMore,
            hasMoreMessages: hasMoreMessages
        )
    }
}

// MARK: - The legacy path

extension ChatScrollManager: TranscriptViewportOwning {

    var isFollowing: Bool { shouldScrollToBottom }

    var showJumpButton: Bool { shouldShowScrollToBottomButton }

    /// Inverted deliberately: `isOpening` is "the layout is still in flight", which is the
    /// complement of the fact the new owner tracks. The two are not the same measurement — one is
    /// a 600 ms timer and the other is the tail being on screen — but they gate the same call site,
    /// and this is the seam where that difference is allowed to exist.
    var layoutPrimed: Bool { !isOpening }

    /// No such concept on this path; the pin series is what holds a position, badly.
    var heldMessageId: String? {
        get { nil }
        set {}
    }

    /// Nothing to bind it to. The pin series re-derives a target on each attempt rather than
    /// holding one, which is why it cannot survive a prepend at all.
    func bindAnchorRow(_ messageId: String?) {}

    var stateDescription: String {
        "mode=\(viewportMode) autoScroll=\(shouldScrollToBottom)"
    }

    func noteTranscriptAppeared(messageCount: Int) {
        guard messageCount > 0 else { return }
        beginOpening()
    }

    func updateGeometry(_ geometry: ChatScrollGeometry, messageCount: Int) {
        updateScrollOffset(
            distanceFromBottom: geometry.distanceFromBottom,
            contentFits: geometry.contentFits,
            contentHeight: geometry.contentHeight,
            visibleMinY: geometry.visibleMinY
        )
    }

    /// This path latches on the composer alone, because that is all it ever watched. The keyboard
    /// arrives through its NotificationCenter observers instead.
    func noteComposerGeometry(composerHeight: CGFloat, safeAreaBottom: CGFloat, containerHeight: CGFloat) {
        noteComposerHeightChanged()
    }

    func followExplicitly() {
        shouldScrollToBottom = true
        scrollToBottom()
    }

    /// The owner's own method takes an injectable `now:` for its duration tests, so its signature
    /// is not the protocol's. Named explicitly rather than defaulted into place, because a
    /// same-name-different-arity near miss is how a conformance silently picks the wrong overload.
    func noteLastMessageVisible(_ visible: Bool, searchActive: Bool) {
        noteLastMessageVisible(visible, searchActive: searchActive, now: Date())
    }
}
