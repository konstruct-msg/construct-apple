//
//  IceMode.swift
//  Construct Messenger
//

import Foundation

/// ICE operation mode: controls when and how the obfs4 proxy is used.
enum IceMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case on

    var id: String { rawValue }

    /// UserDefaults key for storing the mode. Kept for existing callers.
    static var defaultsKey: String { IceProxyStore.modeKey }

    /// Platform default: macOS -> .on, iOS -> .auto.
    static var platformDefault: IceMode {
        #if os(macOS)
        return .on
        #else
        return .auto
        #endif
    }

    /// Migrate from the old boolean `ice_enabled` + `ice_auto_detected_dpi` to `IceMode`.
    static func migrateFromLegacy() -> IceMode {
        IceProxyStore.migrateModeFromLegacy()
    }
}
