//
//  ChatTranscriptScrollView.swift
//  Construct Messenger
//
//  The transcript's scroll container, owned by us. PR-A2 of
//  `decisions/chat-transcript-uikit-scroll-container.md`.
//
//  One `UIScrollView`, one `UIHostingController`, and the same SwiftUI rows as before. Nothing
//  about `MessageBubble` changes: this is not a collection view, there are no cells, no reuse and
//  no self-sizing — those were the expensive parts of the rejected variant A, and none of them is
//  what we were missing.
//
//  What we were missing is one sentence SwiftUI cannot say: *keep the offset while the content
//  changes*. `TranscriptOffsetPolicy` says it; this file is the plumbing that applies it.
//

#if os(iOS)
import SwiftUI
import UIKit

/// A scroll view that says when it has laid out.
///
/// The offset decision has to run in the same layout pass as the content it reacts to. It used to
/// run one runloop turn later, from `DispatchQueue.main.async`, and that turn is a **presented
/// frame**: a fresh `UIScrollView` sits at offset 0, so opening a chat drew the oldest message and
/// then cut to the newest. Reported from device on 2026-08-21 as "you see the middle or the
/// beginning first, then a hard jump to the current messages".
final class TranscriptScrollView: UIScrollView {
    var onDidLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onDidLayout?()
    }
}

struct ChatTranscriptScrollView<Content: View>: UIViewRepresentable {

    /// Room for the composer. Part of the scrollable range rather than something the content has
    /// to leave space for a second time.
    var bottomInset: CGFloat
    var mode: ChatViewport.Mode
    var layoutPrimed: Bool
    /// Where the anchor row sits, tagged with which row it is. Nil while following, before the row
    /// has reported once, or when the tag no longer matches the bound anchor.
    var anchor: TranscriptAnchorSample?
    /// Monotonic token for "take me to the newest message".
    ///
    /// The owned path has no `ScrollViewProxy` — `ChatTranscriptContainer` creates one and calls
    /// `onProxyReady`, this file does neither — so `ChatViewport.followExplicitly`'s
    /// `proxy?.scrollTo("bottom")` was a no-op from the day the flag went on. The jump control
    /// appeared, cleared its own flag, slid out on its `.move(edge: .trailing)` transition, and slid
    /// back when the next geometry tick recomputed the same distance. A token rather than a `Bool`
    /// so two taps in a row are two lands.
    var landRequest: Int

    /// The tail landed. Closes `layoutPrimed`, which is what stops the landing rule re-firing.
    var onLanded: () -> Void
    var onGeometry: (ChatScrollGeometry) -> Void
    /// A finger is on the list. The only signal that outranks every heuristic upstream.
    var onUserInteraction: () -> Void

    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> TranscriptScrollView {
        let scrollView = TranscriptScrollView()
        scrollView.delegate = context.coordinator
        scrollView.onDidLayout = { [weak coordinator = context.coordinator] in
            coordinator?.applyPendingLayout()
        }
        scrollView.backgroundColor = UIColor(Color.CT.bg)
        // We own every inset on this view. The system's adjustment would add the safe area on top
        // of the composer inset and put the tail under the glass again.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true

        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            // Width comes from the frame guide, height from the content. Constraining height too
            // is how a hosting controller ends up in an autolayout loop with the media player
            // already nested inside these bubbles.
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: TranscriptScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.mode = mode
        coordinator.layoutPrimed = layoutPrimed
        coordinator.anchor = anchor
        coordinator.landRequest = landRequest
        coordinator.onLanded = onLanded
        coordinator.onGeometry = onGeometry
        coordinator.onUserInteraction = onUserInteraction

        if scrollView.contentInset.bottom != bottomInset {
            scrollView.contentInset.bottom = bottomInset
            scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
        }

        coordinator.host.rootView = AnyView(content())
        // The offset decision belongs to the layout pass that produces the new content height, so
        // it is requested rather than performed: `TranscriptScrollView.layoutSubviews` runs it in
        // the same transaction. Doing it from `DispatchQueue.main.async` instead put a whole
        // presented frame between the content arriving and the offset moving to meet it.
        coordinator.host.view.setNeedsLayout()
        scrollView.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: AnyView(content()))
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {

        let host: UIHostingController<AnyView>
        weak var scrollView: UIScrollView?

        var mode: ChatViewport.Mode = .following
        var layoutPrimed = false
        var anchor: TranscriptAnchorSample?
        var landRequest = 0
        var onLanded: () -> Void = {}
        var onGeometry: (ChatScrollGeometry) -> Void = { _ in }
        var onUserInteraction: () -> Void = {}

        private var previousContentHeight: CGFloat = 0
        private var previousAnchor: TranscriptAnchorSample?
        /// True while we are the ones moving the offset. Without it our own correction arrives at
        /// `scrollViewDidScroll` and is indistinguishable from a finger — which would flip the mode
        /// to `readingHistory` on the very landing that put the tail on screen.
        private var isAdjusting = false
        /// `setContentOffset` inside a layout pass provokes another one. The work is idempotent —
        /// the second pass sees an unchanged content height and decides `.none` — but re-entering
        /// it costs a wasted policy evaluation and reads like a loop to anyone stepping through.
        private var isApplyingLayout = false
        private var lastLandRequest = 0

        init(rootView: AnyView) {
            host = UIHostingController(rootView: rootView)
            // Intrinsic size only: the hosting view measures itself from the SwiftUI content, and
            // nothing else constrains its height.
            host.sizingOptions = [.intrinsicContentSize]
            host.view.backgroundColor = .clear
            super.init()
        }

        /// The offset decision, run from the scroll view's own `layoutSubviews` so it lands in the
        /// same transaction as the content it reacts to.
        func applyPendingLayout() {
            guard !isApplyingLayout, let scrollView else { return }
            isApplyingLayout = true
            defer { isApplyingLayout = false }

            let contentHeight = host.view.bounds.height
            let viewportHeight = scrollView.bounds.height
            // Two samples of the same row, or nothing. Comparing across rows produced a shift
            // that measured the distance between two unrelated messages.
            let shift: CGFloat? = {
                guard let anchor, let previous = previousAnchor,
                      previous.messageId == anchor.messageId else { return nil }
                return anchor.minY - previous.minY
            }()

            // An explicit "take me to the newest" outranks the policy: the policy answers
            // "the content changed, now what", and this did not come from the content.
            if landRequest != lastLandRequest {
                lastLandRequest = landRequest
                previousContentHeight = contentHeight
                previousAnchor = anchor
                guard contentHeight > 0, viewportHeight > 0 else { return }
                // Not animated, for the same reason `.land` is not: an interpolating offset while
                // an inset may still be moving is the window the old delay series chased. It also
                // keeps the control honest — the next geometry report reads distance ≈ 0, so the
                // button hides because the tail is there rather than because it was told to.
                setOffset(scrollView, to: TranscriptOffsetPolicy.bottomOffset(
                    contentHeight: contentHeight,
                    viewportHeight: viewportHeight,
                    bottomInset: scrollView.contentInset.bottom
                ))
                if !layoutPrimed { onLanded() }
                report(scrollView, contentHeight: contentHeight)
                return
            }

            let action = TranscriptOffsetPolicy.action(
                mode: mode,
                layoutPrimed: layoutPrimed,
                contentHeight: contentHeight,
                previousContentHeight: previousContentHeight,
                viewportHeight: viewportHeight,
                bottomInset: scrollView.contentInset.bottom,
                currentOffsetY: scrollView.contentOffset.y,
                anchorShift: shift
            )

            previousContentHeight = contentHeight
            previousAnchor = anchor

            switch action {
            case .none:
                break
            case .land(let y), .hold(let y):
                setOffset(scrollView, to: y)
                if case .land = action, !layoutPrimed, contentHeight > 0 {
                    onLanded()
                }
            }

            report(scrollView, contentHeight: contentHeight)
        }

        /// Move the offset as us, not as a finger. `isAdjusting` is what keeps
        /// `scrollViewDidScroll` from reporting our own correction back as a reading position.
        private func setOffset(_ scrollView: UIScrollView, to y: CGFloat) {
            isAdjusting = true
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            isAdjusting = false
        }

        private func report(_ scrollView: UIScrollView, contentHeight: CGFloat) {
            let visibleMinY = scrollView.contentOffset.y
            let visibleMaxY = visibleMinY + scrollView.bounds.height - scrollView.contentInset.bottom
            onGeometry(
                ChatScrollGeometry(
                    distanceFromBottom: contentHeight - visibleMaxY,
                    width: scrollView.bounds.width,
                    contentFits: contentHeight <= scrollView.bounds.height + 8,
                    contentHeight: contentHeight,
                    visibleMinY: visibleMinY,
                    containerHeight: scrollView.bounds.height,
                    safeAreaBottom: scrollView.safeAreaInsets.bottom
                )
            )
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isAdjusting else { return }
            report(scrollView, contentHeight: host.view.bounds.height)
        }

        /// A finger, and only a finger. Deceleration is content in motion — including our own
        /// corrections — and reading it as intent is the mistake that produced the flicker on the
        /// old path.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onUserInteraction()
        }
    }
}
#endif
