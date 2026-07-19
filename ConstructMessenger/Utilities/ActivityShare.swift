//
//  ActivityShare.swift
//  Construct Messenger
//
//  Safe UIActivityViewController presentation for iPhone + iPad.
//  On iPad the system presents the share sheet as a popover and aborts
//  (SIGABRT in UIPopoverPresentationController) if sourceView/sourceRect
//  (or barButtonItem) is missing — classic Diagnostics "Share logs" crash.
//

import Foundation

#if canImport(UIKit)
import UIKit

enum ActivityShare {
    /// Present a system share sheet for `items` from the topmost view controller.
    /// - Parameter sourceView: preferred popover anchor (e.g. the tapped button).
    ///   When nil, anchors to the center of the presenting view (no arrow).
    @MainActor
    static func present(
        items: [Any],
        applicationActivities: [UIActivity]? = nil,
        sourceView: UIView? = nil,
        sourceRect: CGRect? = nil
    ) {
        guard let presenter = topViewController() else {
            Log.error("No view controller available to present share sheet", category: "ActivityShare")
            return
        }

        let activity = UIActivityViewController(
            activityItems: items,
            applicationActivities: applicationActivities
        )

        // iPad (and regular-width multitasking) uses a popover — must configure anchor.
        if let popover = activity.popoverPresentationController {
            if let sourceView {
                popover.sourceView = sourceView
                popover.sourceRect = sourceRect ?? sourceView.bounds
            } else if let host = presenter.view {
                popover.sourceView = host
                let mid = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
                popover.sourceRect = sourceRect ?? CGRect(x: mid.x, y: mid.y, width: 1, height: 1)
                // No arrow when we only have a synthetic center anchor.
                popover.permittedArrowDirections = []
            }
        }

        presenter.present(activity, animated: true)
    }

    @MainActor
    private static func topViewController(
        base: UIViewController? = nil
    ) -> UIViewController? {
        let root: UIViewController? = base ?? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
                ?? scenes.flatMap(\.windows).first
            return window?.rootViewController
        }()

        guard let root else { return nil }

        if let nav = root as? UINavigationController {
            return topViewController(base: nav.visibleViewController ?? nav)
        }
        if let tab = root as? UITabBarController {
            return topViewController(base: tab.selectedViewController ?? tab)
        }
        if let presented = root.presentedViewController {
            return topViewController(base: presented)
        }
        return root
    }
}
#endif
