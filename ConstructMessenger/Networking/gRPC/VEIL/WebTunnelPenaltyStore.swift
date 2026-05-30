//
//  WebTunnelPenaltyStore.swift
//  Construct Messenger
//
//  Persists carrier-level WebTunnel block penalties across app launches.
//  Keyed by relay address; values are the accumulated penalty scores.
//

import Foundation

enum WebTunnelPenaltyStore {

    private static let key = "com.construct.ice.webTunnelBlockedPenalty"

    static func load() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func save(_ penalty: [String: Int]) {
        UserDefaults.standard.set(penalty, forKey: key)
    }
}
