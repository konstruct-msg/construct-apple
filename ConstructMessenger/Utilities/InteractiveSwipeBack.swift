//
//  InteractiveSwipeBack.swift
//  Construct Messenger
//
//  Restores the native iOS edge-swipe-to-go-back gesture across the app.
//
//  Every pushed screen hides the system navigation bar
//  (`.toolbar(.hidden, for: .navigationBar)`) so we can render the terminal-styled
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

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    open override func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow the edge-swipe pop only when there's a screen to pop back to.
        viewControllers.count > 1
    }
}
#endif
