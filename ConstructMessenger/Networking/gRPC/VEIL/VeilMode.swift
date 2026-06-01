//
//  VeilMode.swift
//  Construct Messenger
//

import Foundation

/// VEIL operation mode: controls when and how the obfs4 proxy is used.
enum VeilMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case on

    var id: String { rawValue }

    /// UserDefaults key for storing the mode. Kept for existing callers.
    static var defaultsKey: String { VeilProxyStore.modeKey }

    /// Platform default: macOS -> .on, iOS -> .auto.
    static var platformDefault: VeilMode {
        #if os(macOS)
        return .on
        #else
        return .auto
        #endif
    }

    /// Migrate from the old boolean `veil_enabled` + `veil_auto_detected_dpi` to `VeilMode`.
    static func migrateFromLegacy() -> VeilMode {
        VeilProxyStore.migrateModeFromLegacy()
    }
}
