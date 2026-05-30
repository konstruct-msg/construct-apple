//
//  NetworkFingerprint.swift
//  Construct Messenger
//
//  Caller-computed scoring key passed into the Rust VEIL coordinator.
//
//  iOS 16+ blocks SSID/BSSID reads without `wifi-info` entitlement + location
//  permission, and CTCarrier returns dummy values. The MVP fingerprint is
//  therefore intentionally coarse — just the active interface type ("wifi" /
//  "cellular" / "wired" / "other"). This yields 3-4 scoring buckets across the
//  user base, which is good enough to remember "obfs4 worked on cellular here,
//  WebTunnel won on wifi". When a richer fingerprint is needed in the future
//  (without asking for permissions) the natural next step is gateway-IP subnet.
//

import Foundation

enum NetworkFingerprint {
    /// Returns the current scoring key bytes. Length is small (≤16 bytes).
    /// Pass empty bytes to the FFI to fall back to the Rust default fingerprint.
    @MainActor
    static func current() -> Data {
        let label: String
        switch NetworkReachabilityManager.shared.connectionType {
        case .wifi:        label = "wifi"
        case .cellular:    label = "cellular"
        case .ethernet:    label = "wired"
        case .other:       label = "other"
        case .unavailable: label = "unavailable"
        case .unknown:     label = "unknown"
        }
        return Data(label.utf8)
    }

    /// Path on disk for the persistent scores SQLite database. Caches dir is fine —
    /// scoring state is rebuildable from observed behaviour if lost.
    static var scoresDatabasePath: String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("veil-scores.sqlite").path
    }
}
