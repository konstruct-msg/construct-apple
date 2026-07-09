//
//  VeilCapabilityV2Store.swift
//  Construct Messenger
//
//  Keychain store for the key-bound CapabilityV2 blob (ticket B1, AUTH v3). Kept
//  separate from `VeilTicketStore` (the B2 bearer-capability store) since B1/B2
//  coexist per-relay with independent lifetimes — no flag-day, per
//  decisions/veil-ticket-provisioning-system.md.
//

import Foundation

enum VeilCapabilityV2Store {
    private static func key(for address: String) -> String { "veil_front_capability_v2.\(address)" }

    /// The stored key-bound capability (base64) for `address`, or nil if none.
    static func capability(for address: String) -> String? {
        guard let data = KeychainManager.shared.loadData(forKey: key(for: address)),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func store(capability: String, for address: String) -> Bool {
        guard let data = capability.data(using: .utf8) else { return false }
        // AfterFirstUnlockThisDeviceOnly — same reasoning as VeilTicketStore: the veil
        // proxy may start on a push-driven background wake before the user unlocks.
        return KeychainManager.shared.saveData(
            data, forKey: key(for: address),
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func clear(for address: String) {
        KeychainManager.shared.deleteData(forKey: key(for: address))
    }
}
