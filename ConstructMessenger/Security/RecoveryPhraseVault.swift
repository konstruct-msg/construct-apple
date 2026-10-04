//
//  RecoveryPhraseVault.swift
//  Construct Messenger
//
//  Where the recovery phrase waits between being made and being written down.
//
//  The key is created at registration without asking (`RecoveryKeyProvisioner`), and the person
//  makes their copy later, from Settings. Until then the phrase has to be somewhere, and this is
//  the only place it ever is (`decisions/recovery-key-backup-is-deferred-not-skipped.md` §2).
//  Whoever reads it can recover the account — revoke every device and take the address — so it
//  is held as briefly and as tightly as the flow allows, in two stages:
//
//  - **Pending:** generated, not yet accepted by the server. Readable while the device is unlocked,
//    with no prompt, because the upload may have to be retried from a background launch. This lasts
//    the length of one `SetRecoveryKey` round trip in the ordinary case.
//  - **Held:** accepted by the server, copy not yet made. Stored only when the device has a passcode,
//    and reading it asks for Face ID / Touch ID / the passcode — it is shown to a person looking at
//    the screen and to nothing else. Deleted the moment the copy is confirmed.
//
//  Both are `ThisDeviceOnly`: never in a backup, never in iCloud Keychain. The account the phrase
//  belongs to rides in `kSecAttrGeneric`, which can be read without the prompt.
//

import Foundation
import LocalAuthentication
import Security

/// What the provisioner and the backup screen need from the vault. A protocol so tests can run
/// the flow on a simulator, which has no passcode and so cannot hold anything.
protocol RecoveryPhraseStore: AnyObject {
    /// Whether a phrase can be held behind user authentication on this device — false without a
    /// passcode, and then the phrase is shown at once instead (owner's decision, 2026-10-04).
    var canHold: Bool { get }
    func storePending(_ phrase: String, account: String) -> Bool
    func pendingPhrase(account: String) -> String?
    /// Pending → held. False leaves the pending item where it is.
    func promotePending(account: String) -> Bool
    func hasHeld(account: String) -> Bool
    /// Asks for authentication. Nil when the person cancelled or nothing is held.
    func readHeld(account: String, reason: String) async -> String?
    func forgetPending()
    func forgetHeld()
}

final class RecoveryPhraseVault: RecoveryPhraseStore {
    static let shared = RecoveryPhraseVault()

    static let pendingItem = "construct.recovery.phrase.pending"
    static let heldItem = "construct.recovery.phrase.held"

    var canHold: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func storePending(_ phrase: String, account: String) -> Bool {
        forgetPending()
        var query = base(Self.pendingItem)
        query[kSecAttrGeneric as String] = Data(account.utf8)
        query[kSecValueData as String] = Data(phrase.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func pendingPhrase(account: String) -> String? {
        var query = base(Self.pendingItem)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              Self.account(of: item) == account,
              let data = item[kSecValueData as String] as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func promotePending(account: String) -> Bool {
        guard let phrase = pendingPhrase(account: account),
              let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil
              )
        else { return false }
        forgetHeld()
        var query = base(Self.heldItem)
        query[kSecAttrGeneric as String] = Data(account.utf8)
        query[kSecValueData as String] = Data(phrase.utf8)
        query[kSecAttrAccessControl as String] = access
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { return false }
        forgetPending()
        return true
    }

    func hasHeld(account: String) -> Bool {
        var query = base(Self.heldItem)
        query[kSecReturnAttributes as String] = true
        // Attributes only: this must never put up the Face ID prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let item = result as? [String: Any] else { return false }
        return Self.account(of: item) == account
    }

    func readHeld(account: String, reason: String) async -> String? {
        guard hasHeld(account: account) else { return nil }
        let context = LAContext()
        context.localizedReason = reason
        var query = base(Self.heldItem)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        let request = query
        // SecItemCopyMatching blocks while the prompt is up.
        return await Task.detached {
            var result: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    func forgetPending() {
        SecItemDelete(base(Self.pendingItem) as CFDictionary)
    }

    func forgetHeld() {
        SecItemDelete(base(Self.heldItem) as CFDictionary)
    }

    /// Generic-password items here carry no service, like every other item this app writes
    /// (`KeychainManager.save` — adding one would orphan them).
    private func base(_ item: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: item
        ]
    }

    private static func account(of item: [String: Any]) -> String? {
        (item[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
}
