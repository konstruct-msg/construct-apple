//
//  ChatTranscriptContainer.swift
//  Construct Messenger
//
//  The scrolling transcript, shared by iOS `ChatView` and macOS `DesktopChatView`.
//
//  PR-2 of the chat viewport migration (client/ios/CHAT_VIEWPORT_MIGRATION.md). Behaviour is
//  deliberately the same as before the extraction: still `LazyVStack`, still bottom-anchored,
//  still driven by `ChatScrollManager` in each parent. The point is that PR-3 forks *this file*
//  — roughly a hundred lines with one job — instead of four hundred lines inside a `body` that
//  also owns nav, composer, search, calls and the media gallery.
//
//  Deliberately NOT in this file: `ChatScrollManager`, the composer, and any `proxy.scrollTo`.
//  The container reports geometry and hands the proxy out; who decides what to do with either is
//  the parent's business, and after PR-3 it is `ChatViewport`'s. There is also no `import UIKit`
//  and no iOS-only API — this compiles into the macOS target unchanged.
//

import SwiftUI

/// One geometry sample of the transcript scroll view.
///
/// Was a `private struct` declared **twice** — `ChatView.swift:75` and `DesktopChatView.swift:46`
/// — with identical fields and identical derivation. Two carriers of one meaning, kept in step by
/// nothing, in a file whose whole subject is that defect class. One declaration now.
struct ChatScrollGeometry: Equatable {
    /// Points of content below the visible rect (0 ≈ at bottom).
    var distanceFromBottom: CGFloat
    var width: CGFloat
    /// Content shorter than the viewport ⇒ nothing to jump to — the FAB must never show.
    var contentFits: Bool
    /// Stored for stranded-recovery geometry (not a re-pin trigger — see `ChatScrollManager`).
    var contentHeight: CGFloat
    var visibleMinY: CGFloat
    /// Height of the scroll view itself. Reported because the keyboard changes it without
    /// touching the composer, and an inset latch that cannot see that reads the keyboard as a
    /// settled layout.
    var containerHeight: CGFloat
    /// Bottom safe area under the transcript.
    ///
    /// The third input of that latch, and until 2026-08-21 it did not exist: `ChatView` held a
    /// `bottomSafeAreaInset` and passed it to `noteComposerGeometry`, and nothing ever assigned it.
    /// Taken from the scroll view rather than from a SwiftUI proxy because the composer is an
    /// overlay *inside* the safe area on the owned path, so its own proxy reports zero — a second
    /// constant dressed as a measurement.
    var safeAreaBottom: CGFloat
}

/// The previous geometry sample, held outside SwiftUI's invalidation.
///
/// Its only consumer is the `old` argument of `logScrollGeometryIfChanged`, which is gated by
/// `ChatScrollManager.verboseGeometryLogging` and off by default. As `@State` in `ChatView` it was
/// rewritten on every scroll delegate callback, so a value that usually goes nowhere was
/// re-rendering the whole transcript at frame rate.
@MainActor
final class TranscriptGeometryHistory {
    var last = ChatScrollGeometry(
        distanceFromBottom: 0, width: 0, contentFits: false,
        contentHeight: 0, visibleMinY: 0, containerHeight: 0, safeAreaBottom: 0
    )
}

/// The transcript scroll view: sentinel, rows, bottom clearance, bottom anchor.
///
/// `bottomContentPad` is a parameter rather than a constant because the two hosts disagree today
/// and will keep disagreeing until PR-3b: iOS passes `Shell.messageBottomClearance`, Desktop
/// passes its `130`. In PR-3 it becomes the measured composer height on iOS.
///
/// The pad is rendered **inside** the stack, before `id("bottom")` — the ordering invariant from
/// 2026-06-20. A follow that targets the anchor must land above the composer glass, not flush
/// with the viewport bottom.
struct ChatTranscriptContainer<Sentinel: View, Rows: View>: View {

    var rowSpacing: CGFloat
    var topContentPad: CGFloat
    var bottomContentPad: CGFloat
    var accessibilityIdentifier: String?

    /// Build every row up front instead of materialising them as they scroll into view.
    ///
    /// This is the fix, and everything else in the migration is arrangement around it. The blank
    /// chat is not a wrong offset — device log 2026-08-19 has `fromBottom=-83` and 90 % coverage
    /// over an empty screen, which is the viewport correctly at the end of a list whose rows were
    /// never drawn. `LazyVStack` also reports height for those rows, so the geometry agrees the
    /// layout is fine while nothing is on it. An eager stack has no such state: there is nothing
    /// left to not-materialise, and `contentSize` becomes an honest witness again.
    ///
    /// The cost is real and bounded: 30 rows built on open instead of the handful on screen.
    /// Measured at 30 / 90 / 230 in the PR-3 merge gate; if it hitches, the flag goes off — that is
    /// what the flag is for.
    ///
    /// Desktop passes `false` and keeps the lazy stack until its own step (PR-3b).
    var usesEagerStack: Bool = false

    /// Called once the `ScrollViewProxy` exists. The parent registers it with whoever owns scroll.
    var onProxyReady: (ScrollViewProxy) -> Void
    /// `(old, new)` so the parent can log only meaningful moves.
    var onGeometryChange: (ChatScrollGeometry, ChatScrollGeometry) -> Void
    var onScrollPhaseChange: (ScrollPhase) -> Void
    var onTapBackground: () -> Void
    /// Bottom-anchor visibility. Its appearance separates the two readings of a blank chat that no
    /// log could tell apart: if it fires while the screen is empty, the viewport IS at the end of
    /// the list and the cells are not drawing; if it never fires, the offset is somewhere else.
    var onBottomAnchorVisible: (Bool) -> Void

    /// Infinite-scroll sentinel at the oldest edge. Both hosts pass one; it stays a slot because
    /// its contents (ProgressView vs 1pt spacer, and its paddings) belong to the host's design.
    @ViewBuilder var sentinel: () -> Sentinel
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if usesEagerStack {
                        VStack(spacing: rowSpacing) { stackContent }
                    } else {
                        LazyVStack(spacing: rowSpacing) { stackContent }
                    }
                }
                .padding(.top, topContentPad)
                .padding(.horizontal)
            }
            .background(Color.CT.bg) // base under the glass panels
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
            .defaultScrollAnchor(.bottom)
            // The initial-offset anchor lands on the *first* layout, and on that layout the
            // transcript is empty: the store publishes from `onViewAppear`, after the first body
            // pass. Thirty rows then arrive and nothing takes the view back down — measured on the
            // stand 2026-08-19, where the eager path opened on the oldest message with zero pins.
            // This role is what keeps the bottom as the content grows, and it is why following
            // needs no `scrollTo` at all.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { onTapBackground() }
            .onScrollGeometryChange(for: ChatScrollGeometry.self) { geo in
                // visibleRect is in content coordinates and already reflects the composer inset.
                // Subtracting maxY from content height is the true "how far up".
                ChatScrollGeometry(
                    distanceFromBottom: geo.contentSize.height - geo.visibleRect.maxY,
                    width: geo.containerSize.width,
                    contentFits: geo.contentSize.height <= geo.visibleRect.height + 8,
                    contentHeight: geo.contentSize.height,
                    visibleMinY: geo.visibleRect.minY,
                    containerHeight: geo.containerSize.height,
                    safeAreaBottom: geo.contentInsets.bottom
                )
            } action: { old, new in
                onGeometryChange(old, new)
            }
            .onScrollPhaseChange { _, phase in
                onScrollPhaseChange(phase)
            }
            .onAppear { onProxyReady(proxy) }
        }
    }

    /// The stack's contents, written once so the two containers cannot drift.
    ///
    /// The order is the invariant from 2026-06-20 and is not negotiable:
    /// `sentinel → rows → clearance → id("bottom")`. The pad is rendered **inside** the stack and
    /// **before** the anchor, so a follow that targets the anchor lands above the composer glass
    /// rather than flush with the viewport bottom.
    @ViewBuilder
    private var stackContent: some View {
        sentinel()
        rows()
        // Breathing room below the last message, above the composer.
        Color.clear
            .frame(height: bottomContentPad)
        Color.clear
            .frame(height: 1)
            .id("bottom")
            .onAppear { onBottomAnchorVisible(true) }
            .onDisappear { onBottomAnchorVisible(false) }
    }
}
