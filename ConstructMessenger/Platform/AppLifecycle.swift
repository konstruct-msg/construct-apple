// Platform-independent app lifecycle notifications.
// Use these instead of UIApplication.willResignActiveNotification directly.

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Notification.Name {
    /// Posted when the app is about to resign active (go to background).
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
}
