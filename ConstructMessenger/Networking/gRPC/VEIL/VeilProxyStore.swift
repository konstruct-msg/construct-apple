//
//  VeilProxyStore.swift
//  Construct Messenger
//

import Foundation

/// Centralized persistence for VEIL mode, relay cache, and relay quality data.
enum VeilProxyStore {
    static let legacyEnabledKey = "veil_enabled"
    static let legacyAutoDetectedDPIKey = "veil_auto_detected_dpi"
    static let modeKey = "veil_mode"
    static let relayKey = "veilActiveRelay"
    static let modeMigrationVersion = 1

    private static let lastSuccessfulPathKey = "veil_last_successful_path"
    private static let qualityScoresKey = "veil_relay_quality_scores_v1"
    private static let qualityScoresMaxEntries = 20

    static func loadMode() -> VeilMode {
        if let raw = UserDefaults.standard.string(forKey: modeKey),
           let stored = VeilMode(rawValue: raw) {
            return stored
        }
        return VeilMode.platformDefault
    }

    static var hasStoredMode: Bool {
        UserDefaults.standard.string(forKey: modeKey) != nil
    }

    static func saveMode(_ mode: VeilMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        // Keep the legacy key in sync for older fast-path readers and migration safety.
        UserDefaults.standard.set(mode == .on, forKey: legacyEnabledKey)
    }

    static var modeMigrationKey: String {
        "veil_mode_migration_v\(modeMigrationVersion)"
    }

    static var needsModeMigration: Bool {
        !UserDefaults.standard.bool(forKey: modeMigrationKey)
    }

    static func markModeMigrationDone() {
        UserDefaults.standard.set(true, forKey: modeMigrationKey)
    }

    static func migrateModeFromLegacy() -> VeilMode {
        let wasEnabled = UserDefaults.standard.bool(forKey: legacyEnabledKey)
        let wasAutoDetected = UserDefaults.standard.bool(forKey: legacyAutoDetectedDPIKey)

        #if os(macOS)
        return wasEnabled ? .on : .auto
        #else
        if wasEnabled && !wasAutoDetected {
            return .on
        }
        return .auto
        #endif
    }

    static var lastSuccessfulPath: String? {
        get { UserDefaults.standard.string(forKey: lastSuccessfulPathKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: lastSuccessfulPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSuccessfulPathKey)
            }
        }
    }

    static func loadRelayQualityScores() -> [String: RelayQualityScore] {
        guard let data = UserDefaults.standard.data(forKey: qualityScoresKey),
              var scores = try? JSONDecoder().decode([String: RelayQualityScore].self, from: data)
        else { return [:] }
        // Decay old failures on every load — prevents permanent relay blacklisting from past outages.
        for (key, var score) in scores {
            score.decayOldFailures()
            scores[key] = score
        }
        return scores
    }

    static func pruneRelayQualityScores(_ scores: [String: RelayQualityScore]) -> [String: RelayQualityScore] {
        guard scores.count > qualityScoresMaxEntries else { return scores }
        let sorted = scores.sorted { $0.value.lastUsed > $1.value.lastUsed }
        return Dictionary(sorted.prefix(qualityScoresMaxEntries).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func saveRelayQualityScores(_ scores: [String: RelayQualityScore]) {
        guard let data = try? JSONEncoder().encode(scores) else { return }
        UserDefaults.standard.set(data, forKey: qualityScoresKey)
    }

    static func saveStoredRelay(_ relay: VeilRelay) {
        guard let data = try? JSONEncoder().encode(relay) else { return }
        UserDefaults.standard.set(data, forKey: relayKey)
    }

    static func loadStoredRelay() -> VeilRelay? {
        guard let data = UserDefaults.standard.data(forKey: relayKey),
              let relay = try? JSONDecoder().decode(VeilRelay.self, from: data)
        else { return nil }
        return relay
    }

    static func clearStoredRelay() {
        UserDefaults.standard.removeObject(forKey: relayKey)
    }

    static func cachedRelayList() -> [String] {
        UserDefaults.standard.stringArray(forKey: VEILConfig.cachedRelayListKey) ?? []
    }

    static func cachedRelayAddresses(fallback: [String]) -> [String] {
        let server = cachedRelayList()
        var seen = Set<String>()
        return (server + fallback).filter { seen.insert($0).inserted }
    }

    static func cachedRelayRegions(fallback: [VEILRelayRegion]) -> [VEILRelayRegion] {
        if let data = UserDefaults.standard.data(forKey: VEILConfig.cachedRelayRegionsKey),
           let regions = try? JSONDecoder().decode([VEILRelayRegion].self, from: data) {
            return regions
        }
        return fallback
    }
}
