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

    /// Auto on every platform. macOS defaulted to `.on` until 2026-10-13, when `on` stopped
    /// falling back to the direct path (`allowsDirectPath`): a Mac with no front would have gone
    /// offline without anyone having chosen to hide. `on` is a choice the person makes; a stored
    /// choice is kept.
    static var platformDefault: VeilMode { .auto }

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
struct VeilTunnelNotUp: LocalizedError {
    // Shown where the last connection error is shown (Settings → Network). Until 2026-10-14
    // it read "Construct_Messenger.VeilTunnelNotUp error 1." there.
    var errorDescription: String? { NSLocalizedString("veil_tunnel_not_up", comment: "") }
}

/// VEIL `on` and the tunnel still coming up: a send waits for it rather than failing. On
/// 2026-10-14 a file dropped into a chat in those seconds turned red at once.
enum VeilTunnelWait {
    /// Longer than one cooldown after every front failed (29 s) and the next round of tries.
    static let limit: TimeInterval = 120
    private static let pollNs: UInt64 = 500_000_000

    /// True as soon as a route is allowed — the tunnel up, or a mode that may go direct; false
    /// at the limit or on cancellation.
    static func untilRouted(
        limit: TimeInterval = limit,
        isRouted: @Sendable () -> Bool = {
            GRPCChannelManager.shared.veilProxyPort() != nil || VeilProxyStore.loadMode().allowsDirectPath
        }
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while !isRouted() {
            guard Date() < deadline, (try? await Task.sleep(nanoseconds: pollNs)) != nil else { return false }
        }
        return true
    }
}
