//
//  VeilRelayHealth.swift
//  Construct Messenger
//

import Foundation
import SwiftUI

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
    /// Timestamp of the most recent failure — used for time-based decay.
    var lastFailureAt: Date = .distantPast

    var totalRPCs: Int { successfulRPCs + failedRPCs }

    /// True if the latency measurement is fresh enough to skip TCP probing.
    var hasRecentLatency: Bool {
        ewmaLatencyMs > 0
            && Date().timeIntervalSince(latencyMeasuredAt) < NetworkTiming.VEIL.latencyCacheValidity
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

    /// Halve `failedRPCs` for every full 24-hour period since the last failure.
    /// Prevents a single bad day from permanently blacklisting a relay.
    /// Call this once on load (and optionally before reading `quality`).
    mutating func decayOldFailures(now: Date = Date()) {
        guard lastFailureAt != .distantPast, failedRPCs > 0 else { return }
        let hoursSinceFailure = now.timeIntervalSince(lastFailureAt) / 3600
        guard hoursSinceFailure >= 24 else { return }
        let halvings = Int(hoursSinceFailure / 24)
        failedRPCs = max(0, failedRPCs >> halvings)  // bit-shift = divide by 2^n
        // Reset lastFailureAt if all failures decayed
        if failedRPCs == 0 { lastFailureAt = .distantPast }
    }

    mutating func applyLatencySample(_ sample: TimeInterval) {
        let ms = sample * 1000
        let alpha = NetworkTiming.VEIL.latencyCacheEWMAAlpha
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
        lastFailureAt = Date()
        lastUsed = Date()
    }
}
