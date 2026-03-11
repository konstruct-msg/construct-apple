// Platform-independent device information.
// Replaces UIDevice.current usage with cross-platform equivalents.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum DeviceInfo {
    /// Human-readable device name (e.g. "Max's iPhone" / "Max's MacBook Pro")
    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    /// Hardware model string (e.g. "iPhone16,2" / "MacBookPro18,4")
    static var deviceModel: String {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        return UIDevice.current.model
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #endif
    }

    /// OS version string (e.g. "17.4" / "14.4")
    static var systemVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// Stable per-install identifier (UIDevice on iOS/Catalyst; nil on macOS — use Keychain)
    static var identifierForVendor: String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }
}
