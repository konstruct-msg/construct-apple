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
    /// **Off by default on both configurations**, and that is a finding, not caution.
    ///
    /// The plan had DEBUG default on. The first live run of the eager path (stand, 2026-08-19)
    /// opened a 40-message chat on the *oldest* message: `.defaultScrollAnchor(.bottom)` lands on
    /// the first layout, and on that layout the transcript is empty, because the store publishes
    /// after the first body pass. Adding `.defaultScrollAnchor(.bottom, for: .sizeChanges)` did not
    /// change it. The plan's own rule for this outcome is the flag off, a note, and an analysis —
    /// explicitly not a nudge — so leaving DEBUG on would ship a worse daily build than the lazy
    /// path it replaces.
    ///
    /// Plain `UserDefaults`, not iCloud: this is a property of a build under test, not of a person.
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
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
