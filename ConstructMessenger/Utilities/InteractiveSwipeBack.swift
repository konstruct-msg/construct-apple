//
//  InteractiveSwipeBack.swift
//  Construct Messenger
//
//  Restores the native iOS edge-swipe-to-go-back gesture across the app, and widens the
//  reachable area for it.
//
//  Every pushed screen hides the system navigation bar
//  (`.hideSystemNavBar()`) so we can render the terminal-styled
//  `CTNavBar` instead. Hiding the bar makes UIKit suppress the
//  `interactivePopGestureRecognizer` (it normally drives the swipe from the back
//  button), so the edge swipe stops working. This is unrelated to CTNavBar itself —
//  the same thing happens with a hidden system bar regardless of what's drawn.
//
//  SwiftUI's `NavigationStack` is backed by a `UINavigationController`. We take over
//  the pop gesture's delegate so the swipe is allowed whenever there's more than one
//  view controller on the stack, independent of bar visibility. Returning false at the
//  root avoids the classic "swipe at root freezes navigation" bug.
//
//  Global by design: fixes the gesture for every NavigationStack (chats, settings,
//  onboarding) with zero per-screen wiring and no visual change.
//

#if os(iOS)
import UIKit

/// Where a back swipe may start and what commits it.
///
/// Reaching the screen edge one-handed is the whole problem: on a large phone the left edge is
/// the far corner from the thumb. `UIScreenEdgePanGestureRecognizer` cannot be widened — its
/// edge zone is fixed — so a plain pan recognizer covers the rest of the leading half.
///
/// This is only possible because swipe-to-reply moved left (see `MessageBubbleRegularView`).
/// While both gestures travelled right they were separated by a 44pt strip, and widening the back
/// swipe to half the screen would have swallowed the reply gesture whole.
enum BackSwipeZone {
    /// Fraction of the width, measured from the leading edge, where a back swipe may start.
    static let startZoneFraction: CGFloat = 0.5
    /// Horizontal travel must beat vertical by this factor — the list scrolls vertically.
    static let directionRatio: CGFloat = 1.5
    /// Travel that commits the pop on release.
    static let commitTranslation: CGFloat = 80
    /// …or this much flick, for a fast short swipe.
    static let commitVelocity: CGFloat = 500

    static func canBegin(startX: CGFloat, viewWidth: CGFloat, canPop: Bool, insideHorizontalScroll: Bool) -> Bool {
        guard canPop, !insideHorizontalScroll, viewWidth > 0 else { return false }
        return startX < viewWidth * startZoneFraction
    }

    /// Rightward and horizontal enough to be a back swipe rather than a scroll or a reply.
    static func isBackDirection(translation: CGPoint) -> Bool {
        let h = translation.x
        guard h > 0 else { return false }          // leftward belongs to swipe-to-reply
        return h > abs(translation.y) * directionRatio
    }

    static func shouldCommit(translation: CGPoint, velocity: CGPoint) -> Bool {
        guard isBackDirection(translation: translation) else { return false }
        return translation.x >= commitTranslation || velocity.x >= commitVelocity
    }
}

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    private static var wideBackPanKey: UInt8 = 0

    open override func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        installWideBackPan()
    }

    /// A pan over the leading half that pops on release.
    ///
    /// Deliberately **not** interactive: driving the real interactive transition from a foreign
    /// recognizer means reassigning the system recognizer's private `targets`, and this app ships
    /// to the App Store. So the drag does not rubber-band the screen — it commits on release, with
    /// the standard push animation. The system edge recognizer is untouched and still gives the
    /// interactive feel to anyone who starts at the edge.
    private func installWideBackPan() {
        guard objc_getAssociatedObject(self, &Self.wideBackPanKey) == nil else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleWideBackPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        // Never take a drag the scroll view or the edge recognizer wants.
        interactivePopGestureRecognizer.map { pan.require(toFail: $0) }
        view.addGestureRecognizer(pan)
        objc_setAssociatedObject(self, &Self.wideBackPanKey, pan, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc private func handleWideBackPan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended else { return }
        guard viewControllers.count > 1 else { return }
        guard BackSwipeZone.shouldCommit(
            translation: pan.translation(in: view),
            velocity: pan.velocity(in: view)
        ) else { return }
        popViewController(animated: true)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow the edge-swipe pop only when there's a screen to pop back to.
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan === objc_getAssociatedObject(self, &Self.wideBackPanKey) as? UIPanGestureRecognizer
        else { return viewControllers.count > 1 }

        let start = pan.location(in: view)
        guard BackSwipeZone.canBegin(
            startX: start.x,
            viewWidth: view.bounds.width,
            canPop: viewControllers.count > 1,
            insideHorizontalScroll: Self.isInsideHorizontalScrollView(view.hitTest(start, with: nil))
        ) else { return false }
        return BackSwipeZone.isBackDirection(translation: pan.translation(in: view))
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Run alongside the transcript's vertical scrolling; the direction check decides which of
        // the two actually acts, so neither has to be cancelled to let the other work.
        gestureRecognizer is UIPanGestureRecognizer && other is UIPanGestureRecognizer
    }

    /// Media strips and carousels pan horizontally too. Leave their drags alone.
    private static func isInsideHorizontalScrollView(_ hit: UIView?) -> Bool {
        var node = hit
        while let current = node {
            if let scroll = current as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + 1 {
                return true
            }
            node = current.superview
        }
        return false
    }
}
#endif
