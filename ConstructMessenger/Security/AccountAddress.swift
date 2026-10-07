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
import SwiftProtobuf
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

    /// What the server's fingerprint says about the address this device holds.
    enum OwnVerdict: Equatable {
        /// Nothing stored.
        case absent
        /// Stored, and the server's key for the account is its prefix.
        case confirmed
        /// Stored, and the server names another key: it came from a different account's phrase.
        case foreign
        /// Stored, and the server reports no key to compare with.
        case unconfirmed
    }

    /// Pure, so the rule is testable apart from the keychain and the network.
    static func verdict(stored: Data?, serverFingerprint: String?) -> OwnVerdict {
        guard let stored, stored.count == length else { return .absent }
        guard let fingerprint = serverFingerprint else { return .unconfirmed }
        return matchesServerFingerprint(stored, fingerprint: fingerprint) ? .confirmed : .foreign
    }

    /// Our address, only when the server agrees it is this account's. A device can hold the
    /// address of an account it used to be: a Keychain item outlives a sign-out that was not a
    /// wipe. Handed to contacts in a card, that key is pinned there and every later message to
    /// us is addressed to the old account, accepted by the server and delivered to its mailbox
    /// (2026-10-03: a Mac that had been its own account before it joined another one).
    /// A foreign key is deleted here; an unreachable server or an unconfirmed one sends nothing,
    /// and the contact keeps writing to our account id, which is never wrong.
    static func confirmedOwn() async -> Data? {
        guard let stored = own() else { return nil }
        let fingerprint: String?
        do {
            fingerprint = try await AuthServiceClient.shared.getRecoveryStatus().fingerprint
        } catch {
            Log.info("Own address not confirmed (\(error.localizedDescription)) — left out", category: "ContactLink")
            return nil
        }
        switch verdict(stored: stored, serverFingerprint: fingerprint) {
        case .confirmed:
            return stored
        case .foreign:
            Log.error("ADDRESS: the stored own address is not this account's — deleted", category: "ContactLink")
            KeychainManager.shared.deleteOwnAccountAddress()
            return nil
        case .absent, .unconfirmed:
            return nil
        }
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
    /// their row — or nil. Reads saved state, from any thread.
    static func of(accountId: String) -> Data? {
        if accountId == KeychainManager.shared.loadUserID() {
            return own()
        }
        guard let address = (try? LocalRepositories.contacts.contact(accountId))?.accountAddress,
              address.count == length else { return nil }
        return address
    }
}

// MARK: - Contact card

/// The payload of content type 27: what an account hands each contact about itself.
///
/// A `ContactCard` proto, or — at exactly 32 bytes — a bare intake key from a build before the
/// card; any card with a field is longer, so the two cannot be confused. A field of the wrong
/// length is dropped rather than failing the card. Fixed for both clients by
/// `knst_contact_card.json`. decisions/contact-card-carries-the-address-back.md
struct ContactCardPayload: Equatable {
    var intakeKey: Data?
    var accountAddress: Data?

    static let legacyIntakeKeyLength = 32

    static func read(_ payload: Data) -> ContactCardPayload? {
        if payload.count == legacyIntakeKeyLength {
            return ContactCardPayload(intakeKey: payload, accountAddress: nil)
        }
        guard let card = try? Shared_Proto_Core_V1_ContactCard(serializedBytes: payload) else {
            return nil
        }
        return ContactCardPayload(
            intakeKey: card.intakeKey.count == legacyIntakeKeyLength ? card.intakeKey : nil,
            accountAddress: card.accountAddress.count == AccountAddress.length ? card.accountAddress : nil
        )
    }

    func encoded() throws -> Data {
        var card = Shared_Proto_Core_V1_ContactCard()
        if let intakeKey { card.intakeKey = intakeKey }
        if let accountAddress { card.accountAddress = accountAddress }
        return try card.serializedData()
    }
}

// MARK: - Pinning a contact's address

/// Where a contact's address came from. An invite is signed by their device and checked by the
/// server against the account's recovery key; a card is their device's word over our session.
enum AccountAddressSource {
    case invite
    case card
}

enum AccountAddressPin: Equatable {
    /// Nothing was pinned; this is now.
    case pinned
    /// Same as pinned.
    case unchanged
    /// Different from pinned, and the pinned one stands. A security event.
    case conflictKept
    /// Different from pinned, and the invite replaces it. A security event.
    case conflictReplaced

    /// An account's address never changes, so a different one is never an update: it is a peer
    /// naming someone else, or someone naming the peer. The invite outranks the card because the
    /// server checked it against the account's recovery key.
    static func decide(existing: Data?, incoming: Data, source: AccountAddressSource) -> AccountAddressPin {
        guard let existing else { return .pinned }
        if existing == incoming { return .unchanged }
        return source == .invite ? .conflictReplaced : .conflictKept
    }

    var isSecurityEvent: Bool { self == .conflictKept || self == .conflictReplaced }
}

extension AccountAddress {

    /// Apply `address` to a contact row by the rule in `AccountAddressPin.decide`, and raise the
    /// security event on a conflict. The caller saves the context.
    @MainActor
    @discardableResult
    static func pin(_ address: Data, on user: User, source: AccountAddressSource) -> AccountAddressPin {
        guard address.count == length else { return .unchanged }
        let outcome = AccountAddressPin.decide(existing: user.accountAddress, incoming: address, source: source)
        switch outcome {
        case .pinned, .conflictReplaced:
            user.accountAddress = address
        case .unchanged, .conflictKept:
            break
        }
        if outcome.isSecurityEvent {
            Log.error(
                "ADDRESS: \(user.id.prefix(8))… named a different account address (\(source)) — \(outcome == .conflictKept ? "kept the pinned one" : "replaced by the invite's")",
                category: "ContactLink"
            )
            KeyChangeUX.raise(.addressChanged, on: user)
        }
        return outcome
    }
}
