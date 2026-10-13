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

    /// Whether anything may connect to our servers outside the tunnel.
    ///
    /// Not under `on` (owner, 2026-10-13, `decisions/veil-on-never-goes-direct.md`): the person
    /// asked not to be seen, so with no tunnel up the client is offline rather than direct. Until
    /// then `on` meant "prefer VEIL" — every gap in the tunnel put the signed-in connection on the
    /// API domain while the settings said "all traffic routed through VEIL".
    var allowsDirectPath: Bool { self != .on }
}

/// A connection was refused because VEIL is `on` and the tunnel is not up.
struct VeilTunnelNotUp: Error {}
