// Platform-independent app lifecycle notifications.
// Use these instead of UIApplication.willResignActiveNotification directly.

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Notification.Name {
    /// Posted when the app is about to resign active (go to background).
    /// NOTE: This fires for many transient events (alerts, Control Center, brief app switches).
    /// For stream management prefer `appDidEnterBackground` to avoid unnecessary disconnects.
    static var appWillResignActive: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.willResignActiveNotification
        #else
        return NSApplication.willResignActiveNotification
        #endif
    }

    /// Posted when the app has become active (returned to foreground).
    static var appDidBecomeActive: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #else
        return NSApplication.didBecomeActiveNotification
        #endif
    }

    /// Posted when the app is about to terminate.
    static var appWillTerminate: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.willTerminateNotification
        #else
        return NSApplication.willTerminateNotification
        #endif
    }

    /// Posted when the app has fully entered the background (user switched away and the
    /// system suspended execution).  Use this — not `appWillResignActive` — to pause the
    /// messaging stream, so brief app-switches (copying a link, opening Control Center,
    /// system alerts) do NOT kill the connection.
    static var appDidEnterBackground: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didEnterBackgroundNotification
        #else
        return NSApplication.didResignActiveNotification
        #endif
    }

    /// Posted just before the app returns to the foreground from the background.
    static var appWillEnterForeground: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.willEnterForegroundNotification
        #else
        return NSApplication.willBecomeActiveNotification
        #endif
    }
}
