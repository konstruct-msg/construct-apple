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

struct ChatTranscriptScrollView<Content: View>: UIViewRepresentable {

    /// Room for the composer. Part of the scrollable range rather than something the content has
    /// to leave space for a second time.
    var bottomInset: CGFloat
    var mode: ChatViewport.Mode
    var layoutPrimed: Bool
    /// How far the held row moved since the last pass, measured by the row itself. Nil while
    /// following, or before the row has reported once.
    var anchorMinY: CGFloat?

    /// The tail landed. Closes `layoutPrimed`, which is what stops the landing rule re-firing.
    var onLanded: () -> Void
    var onGeometry: (ChatScrollGeometry) -> Void
    /// A finger is on the list. The only signal that outranks every heuristic upstream.
    var onUserInteraction: () -> Void

    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
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

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.mode = mode
        coordinator.layoutPrimed = layoutPrimed
        coordinator.anchorMinY = anchorMinY
        coordinator.onLanded = onLanded
        coordinator.onGeometry = onGeometry
        coordinator.onUserInteraction = onUserInteraction

        if scrollView.contentInset.bottom != bottomInset {
            scrollView.contentInset.bottom = bottomInset
            scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
        }

        coordinator.host.rootView = AnyView(content())
        // The hosting view reports its new height on the next layout pass, so the offset decision
        // has to happen after that pass rather than here — see `Coordinator.applyPendingLayout`.
        coordinator.host.view.setNeedsLayout()
        coordinator.scheduleLayoutCheck()
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
        var anchorMinY: CGFloat?
        var onLanded: () -> Void = {}
        var onGeometry: (ChatScrollGeometry) -> Void = { _ in }
        var onUserInteraction: () -> Void = {}

        private var previousContentHeight: CGFloat = 0
        private var previousAnchorMinY: CGFloat?
        /// True while we are the ones moving the offset. Without it our own correction arrives at
        /// `scrollViewDidScroll` and is indistinguishable from a finger — which would flip the mode
        /// to `readingHistory` on the very landing that put the tail on screen.
        private var isAdjusting = false
        private var layoutCheckScheduled = false

        init(rootView: AnyView) {
            host = UIHostingController(rootView: rootView)
            // Intrinsic size only: the hosting view measures itself from the SwiftUI content, and
            // nothing else constrains its height.
            host.sizingOptions = [.intrinsicContentSize]
            host.view.backgroundColor = .clear
            super.init()
        }

        /// The offset decision runs after the layout pass that produced the new content height.
        func scheduleLayoutCheck() {
            guard !layoutCheckScheduled else { return }
            layoutCheckScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.layoutCheckScheduled = false
                self?.applyPendingLayout()
            }
        }

        private func applyPendingLayout() {
            guard let scrollView else { return }
            scrollView.layoutIfNeeded()

            let contentHeight = host.view.bounds.height
            let viewportHeight = scrollView.bounds.height
            let shift = zip2(previousAnchorMinY, anchorMinY).map { $1 - $0 }

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
            previousAnchorMinY = anchorMinY

            switch action {
            case .none:
                break
            case .land(let y), .hold(let y):
                isAdjusting = true
                scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                isAdjusting = false
                if case .land = action, !layoutPrimed, contentHeight > 0 {
                    onLanded()
                }
            }

            report(scrollView, contentHeight: contentHeight)
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
                    containerHeight: scrollView.bounds.height
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

/// `zip` over two optionals: a value only when both are present.
private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
#endif
