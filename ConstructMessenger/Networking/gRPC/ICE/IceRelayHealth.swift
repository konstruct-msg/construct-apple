//
//  IceRelayHealth.swift
//  Construct Messenger
//

import Foundation
import SwiftUI

/// The reason a relay was blacklisted. Determines how long it stays deprioritized.
enum RelayFailureType: CustomStringConvertible {
    /// obfs4 / TLS handshake could not be completed, likely DPI or cert mismatch.
    case tlsHandshake
    /// Tunnel was established but an RPC / stream timed out.
    case streamTimeout
    /// WebTunnel HTTP upgrade was rejected and the obfs4 companion also failed.
    case webTunnelBlocked
    /// Explicit DPI pattern detected in auto mode.
    case dpiDetected
    /// TLS alert 40, indicating relay fingerprint is blocked by DPI.
    case fingerprintBlocked

    var ttl: TimeInterval {
        switch self {
        case .tlsHandshake, .dpiDetected: return 300
        case .streamTimeout:              return 60
        case .webTunnelBlocked:           return 180
        case .fingerprintBlocked:         return 120
        }
    }

    var description: String {
        switch self {
        case .tlsHandshake:       return "tlsHandshake"
        case .streamTimeout:      return "streamTimeout"
        case .webTunnelBlocked:   return "webTunnelBlocked"
        case .dpiDetected:        return "dpiDetected"
        case .fingerprintBlocked: return "fingerprintBlocked"
        }
    }
}

struct RelayBlacklistEntry {
    let type: RelayFailureType
    let timestamp: Date

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) >= type.ttl
    }
}

/// Four-level quality classification derived from historical success/failure counts.
enum RelayQuality: Int, Codable, CaseIterable {
    /// No history yet (< 3 RPCs observed).
    case unknown   = -1
    /// < 40% success rate.
    case poor      =  0
    /// 40-69% success rate.
    case fair      =  1
    /// 70-89% success rate.
    case good      =  2
    /// >= 90% success rate.
    case excellent =  3

    /// Whether to trust the relay with the full RPC timeout.
    var useFullTimeout: Bool { self == .excellent || self == .good }

    /// Whether to use the short fetch-missed-messages wall-clock cap.
    var useFastFetchCap: Bool { self == .excellent || self == .good }

    /// Consecutive stream timeouts on the same relay before blacklisting it.
    var blacklistThreshold: Int { (self == .excellent || self == .good) ? 1 : 2 }

    var logLabel: String {
        switch self {
        case .excellent: return "excellent"
        case .good:      return "good"
        case .fair:      return "fair"
        case .poor:      return "poor"
        case .unknown:   return "unknown"
        }
    }

    /// Short badge string shown in Network Settings next to the relay address.
    var badge: String {
        switch self {
        case .excellent: return "★★★★"
        case .good:      return "★★★☆"
        case .fair:      return "★★☆☆"
        case .poor:      return "★☆☆☆"
        case .unknown:   return "----"
        }
    }

    var badgeColor: Color {
        switch self {
        case .excellent: return Color.CT.accent
        case .good:      return Color.CT.accent
        case .fair:      return Color.CT.accentDim
        case .poor:      return Color.CT.danger
        case .unknown:   return Color.CT.textDim
        }
    }
}

/// Persisted quality record for a single relay address.
struct RelayQualityScore: Codable {
    var successfulRPCs: Int = 0
    var failedRPCs: Int = 0
    /// EWMA-smoothed TCP connect latency in milliseconds. 0 means never measured.
    var ewmaLatencyMs: Double = 0
    /// Last latency measurement time, used for cache freshness.
    var latencyMeasuredAt: Date = .distantPast
    var lastUsed: Date = .distantPast

    var totalRPCs: Int { successfulRPCs + failedRPCs }

    /// True if the latency measurement is fresh enough to skip TCP probing.
    var hasRecentLatency: Bool {
        ewmaLatencyMs > 0
            && Date().timeIntervalSince(latencyMeasuredAt) < NetworkTiming.ICE.latencyCacheValidity
    }

    var quality: RelayQuality {
        guard totalRPCs >= 3 else { return .unknown }
        let rate = Double(successfulRPCs) / Double(totalRPCs)
        switch rate {
        case 0.9...: return .excellent
        case 0.7...: return .good
        case 0.4...: return .fair
        default:     return .poor
        }
    }

    mutating func applyLatencySample(_ sample: TimeInterval) {
        let ms = sample * 1000
        let alpha = NetworkTiming.ICE.latencyCacheEWMAAlpha
        ewmaLatencyMs = ewmaLatencyMs > 0 ? alpha * ms + (1 - alpha) * ewmaLatencyMs : ms
        latencyMeasuredAt = Date()
        lastUsed = Date()
    }

    mutating func recordSuccess() {
        successfulRPCs += 1
        lastUsed = Date()
    }

    mutating func recordFailure() {
        failedRPCs += 1
        lastUsed = Date()
    }
}
