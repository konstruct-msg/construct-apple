//
//  ChatViewportConfiguration.swift
//  Construct Messenger
//
//  The one switch between the two transcript paths. PR-3; deleted in PR-4 after the soak.
//

import Foundation

enum ChatViewportConfiguration {

    private static let key = "chat.ownedInsetStack"

    /// Whether the transcript runs on the eager stack owned by `ChatViewport`, or the lazy stack
    /// owned by `ChatScrollManager`.
    ///
    /// DEBUG defaults on so the new path is what we use daily; Release defaults off until the soak
    /// in `decisions/chat-viewport-owned-inset.md` passes. Plain `UserDefaults`, not iCloud — this
    /// is a property of a build under test, not of a person.
    ///
    /// **Read exactly once, in a view's `init`.** Sampling it in `body` would let a mid-session
    /// flip put two owners on screen at once, which is build 586: two `ChatScrollManager`s on one
    /// NotificationCenter, each arming its own pin series against the other. The Diagnostics toggle
    /// therefore takes effect on the next push of a chat, not immediately.
    static var ownedInsetStackEnabled: Bool {
        get {
            if let stored = UserDefaults.standard.object(forKey: key) as? Bool {
                return stored
            }
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
