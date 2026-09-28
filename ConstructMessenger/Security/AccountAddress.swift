//
//  AccountAddress.swift
//  Construct Messenger
//
//  An account's address: its Ed25519 recovery public key. The server resolves it to the account
//  (`route_id = SHA-256(0x0001 || key)`), so a message can name its recipient by a key the
//  recipient chose instead of an id the server assigned.
//
//  Where each copy comes from, and why none comes from the server:
//  - our own: derived from the recovery phrase on this device — at setup, at recovery, or when the
//    phrase is entered to confirm it. A key the server handed us could name another account, and
//    every contact we invite would then write to it and lose the message without a word (an
//    unknown address is accepted and dropped by design).
//  - a peer's: from their signed invite (`InviteObject.addr`), verified against their device.
//
//  decisions/invite-carries-the-account-address.md
//

import CoreData
import Foundation

enum AccountAddress {

    /// An Ed25519 public key.
    static let length = 32

    /// How an address is written where a recipient is named (`SealedInner.recipient_user_id`).
    /// The server's `UserId::parse` reads exactly this form.
    static func wire(_ key: Data) -> String {
        "ed25519:" + InviteBinaryCodec.hex(key)
    }

    // MARK: - Our own

    /// This account's address as this device knows it, or nil when the device has never seen
    /// the recovery phrase — a linked device, or an account that set up recovery before the
    /// address existed. Nil means the device cannot mint or redeem invites until the phrase is
    /// entered (`RecoveryGate`).
    static func own() -> Data? {
        guard let key = KeychainManager.shared.loadOwnAccountAddress(), key.count == length else {
            return nil
        }
        return key
    }

    /// Keep our address. Only ever called with a key derived from the phrase on this device.
    static func rememberOwn(_ recoveryPublicKey: Data) {
        guard recoveryPublicKey.count == length else { return }
        KeychainManager.shared.saveOwnAccountAddress(recoveryPublicKey)
    }

    /// Whether a key derived here is the one the server holds for this account, judged by the
    /// fingerprint `GetRecoveryStatus` reports. The server formats it as the key's leading hex in
    /// spaced groups; the comparison ignores the formatting and demands a prefix of at least
    /// 16 bytes, so it neither depends on the grouping nor accepts a truncated fingerprint.
    ///
    /// The server can make this answer "no" (a refusal), never "yes" for a key the phrase did not
    /// produce — the key itself is always ours.
    static func matchesServerFingerprint(_ key: Data, fingerprint: String) -> Bool {
        let digits = fingerprint.filter { !$0.isWhitespace }.lowercased()
        guard digits.count >= 32 else { return false }
        return InviteBinaryCodec.hex(key).hasPrefix(digits)
    }

    // MARK: - Naming a recipient

    /// What `SealedInner.recipient_user_id` carries for `accountId`: the address when known, the
    /// account id otherwise. Pure, so the choice is testable apart from the store.
    static func recipientField(accountId: String, address: Data?) -> String {
        guard let address, address.count == length else { return accountId }
        return wire(address)
    }

    /// The address this device holds for `accountId` — ours from the Keychain, a contact's from
    /// their row — or nil. Call on `context`'s queue.
    static func of(accountId: String, context: NSManagedObjectContext) -> Data? {
        if accountId == KeychainManager.shared.loadUserID() {
            return own()
        }
        let request = User.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", accountId)
        request.fetchLimit = 1
        guard let address = (try? context.fetch(request))?.first?.accountAddress,
              address.count == length else { return nil }
        return address
    }
}
