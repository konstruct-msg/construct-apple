// Platform-independent device information.
// Replaces UIDevice.current usage with cross-platform equivalents.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum DeviceInfo {
    /// Human-readable device name (e.g. "Max's iPhone" / "Max's MacBook Pro"). Main actor: it is
    /// `UIDevice`'s.
    @MainActor
    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    /// Hardware model string (e.g. "iPhone16,2" / "MacBookPro18,4"). Read with `sysctl`, which
    /// any thread may call — the log writer asks from its own queue. Until 2026-10-25 iOS read
    /// `UIDevice.model`, a main-actor property that says only "iPhone".
    static var deviceModel: String {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        return sysctlString("hw.machine")
        #else
        return sysctlString("hw.model")
        #endif
    }

    /// OS version string (e.g. "17.4" / "14.4"), from `ProcessInfo` (thread-safe); a zero patch
    /// is left out, as `UIDevice.systemVersion` writes it.
    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(v.majorVersion).\(v.minorVersion)"
        return v.patchVersion == 0 ? base : "\(base).\(v.patchVersion)"
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &value, &size, nil, 0)
        return String(decoding: value.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// Stable per-install identifier (UIDevice on iOS/Catalyst; nil on macOS — use Keychain).
    /// Main actor: it is `UIDevice`'s.
    @MainActor
    static var identifierForVendor: String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }
}
