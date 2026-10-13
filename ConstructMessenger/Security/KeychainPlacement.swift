//
//  KeychainPlacement.swift
//  Construct Messenger
//
//  Which keychain this app's items live in, and the move out of the old one on macOS.
//
//  iOS has one keychain. macOS has two: the data protection keychain (the iOS one) and the
//  file-based login keychain, which a query reaches unless it says
//  `kSecUseDataProtectionKeychain`. Until 2026-10-13 nothing said it, so the Mac kept every
//  key, token and session in the login keychain. There an item trusts the code signature that
//  created it and asks for the login password from any other: items written by a build run from
//  Xcode put up a password prompt per item in the notarized DMG, and sending a message waited on
//  it. The login keychain also ignores `kSecAttrAccessible`, so the `AfterFirstUnlock` rule in
//  AGENTS.md was never in force on the Mac.
//
//  The data protection keychain trusts the access group the build is entitled to
//  (`keychain-access-groups`, which on macOS needs a provisioning profile — Debug and the
//  Developer ID export both get one by automatic signing), not one signature, so every build of
//  the team reads the same items without a prompt.
//

import Foundation
import Security

enum KeychainPlacement {

    /// Whether the platform has a second, older keychain to read through to.
    #if os(macOS)
    static let hasLegacyKeychain = true
    #else
    static let hasLegacyKeychain = false
    #endif

    /// `query` aimed at the data protection keychain. On iOS that is the only keychain and the
    /// query is returned as is.
    static func current(_ query: [String: Any]) -> [String: Any] {
        guard hasLegacyKeychain else { return query }
        var scoped = query
        scoped[kSecUseDataProtectionKeychain as String] = true
        return scoped
    }

    /// `query` aimed at the login keychain. Only meaningful where `hasLegacyKeychain`.
    static func legacy(_ query: [String: Any]) -> [String: Any] {
        var scoped = query
        scoped[kSecUseDataProtectionKeychain as String] = false
        return scoped
    }

    /// Whether this build can use the data protection keychain at all.
    ///
    /// A build without the access-group entitlement is refused every write
    /// (`errSecMissingEntitlement`), but its reads answer `errSecItemNotFound` — measured on
    /// 2026-10-13, not documented. A missing entitlement would therefore read as an empty
    /// keychain, which is what makes a device look unregistered (`KeychainRead`, the
    /// 2026-08-09 incident). Asked once, by a write that is removed at once.
    static let isCurrentUsable: Bool = {
        guard hasLegacyKeychain else { return true }
        let probe = current([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "construct.keychain.placement_probe"
        ])
        var add = probe
        add[kSecValueData as String] = Data([1])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        if status == errSecMissingEntitlement {
            Log.error("Data protection keychain refused: the build has no keychain access group",
                      category: "Keychain")
            return false
        }
        return true
    }()

    /// What one read answers, and whether the value it found must move out of the login keychain.
    struct ReadOutcome: Equatable {
        let answer: KeychainRead
        let moveFromLegacy: Bool
    }

    /// The read decision. `legacy` is called only when the data protection keychain has nothing,
    /// because reading the login keychain is what may put up the prompt.
    ///
    /// - Anything the data protection keychain answers other than "absent" is the answer: an
    ///   unreadable item there is not overruled by an older copy.
    /// - A copy found in the login keychain is the answer and moves, if the move can land.
    /// - "Absent" from both is absent only when the data protection keychain can be trusted to
    ///   say so; otherwise it is unreadable, never a reason to start over.
    static func read(current: KeychainRead,
                     currentUsable: Bool,
                     hasLegacy: Bool,
                     legacy: () -> KeychainRead) -> ReadOutcome {
        guard hasLegacy, current.isAbsent else {
            return ReadOutcome(answer: current, moveFromLegacy: false)
        }
        let old = legacy()
        switch old {
        case .found:
            return ReadOutcome(answer: old, moveFromLegacy: currentUsable)
        case .unreadable:
            return ReadOutcome(answer: old, moveFromLegacy: false)
        case .absent:
            return ReadOutcome(answer: currentUsable ? .absent : .unreadable(errSecMissingEntitlement),
                               moveFromLegacy: false)
        }
    }
}
