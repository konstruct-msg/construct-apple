//
//  IntakeCredentialService.swift
//  Construct Messenger
//
//  The credential a sealed envelope carries instead of a Privacy Pass token.
//
//  Measured 2026-09-11 across two devices in one ordinary conversation: delivery receipts alone
//  were 36–38% of all token spend, and they are spent by the person who was *written to*. A token
//  per sealed envelope charges the same for a stranger's first contact and for the four-hundredth
//  message between two people who have been talking for a year.
//
//  The server cannot be told which envelopes to exempt — `content_type` lives inside the seal on
//  purpose — so an envelope that owes nothing says so by carrying a credential the recipient
//  issued. Design: `construct-docs/decisions/contact-traffic-is-vouched-not-purchased.md`.
//
//  Three facts hold this together and each has a place it must not drift to:
//
//  • The derivation is `construct-core`'s (`intakeTag`), including the normalisation of the
//    account id. Two clients disagreeing about case produce different tags, the envelope is
//    silently charged, and nothing reports a mismatch — this project already paid that bill on
//    2026-07-22, when recovery hashed the raw username and registration hashed the lowercased one.
//  • The tag is per *recipient*, identical for every sender holding the key. A pair-wise value
//    would be a stable pseudonymous handle for the sender inside each epoch, which is precisely
//    what sealed sender exists to destroy.
//  • Our own key is per *account*, not per device. A device that minted its own would leave half
//    our contacts presenting a credential the server does not recognise.
//

import Foundation

/// Why an envelope is carrying no intake credential, and therefore paying a token.
///
/// Split out because the four causes need different reactions and used to be one silent `nil`.
/// `noKeyForPeer` is the ordinary state during rollout and for anyone who has not written to us
/// yet — it is the answer to "why did this pay", not an error. The other three are malfunctions:
/// a stored key of the wrong size is corruption, and a derivation or seal that fails means the
/// core or the server key is not where it should be.
enum IntakeTagAbsence: String {
    /// We hold no key for this account. Their key arrives the first time they write to us.
    case noKeyForPeer = "no_key_for_peer"
    /// A key is stored, but not 32 bytes. `recordPeerIntakeKey` refuses to write one, so this
    /// means the stored item was damaged rather than badly received.
    case storedKeyWrongSize = "stored_key_wrong_size"
    /// `construct-core` could not derive the tag from a key that passed the size check.
    case derivationFailed = "derivation_failed"
    /// The server's X25519 key was unavailable, so the tag could not be sealed. Sending it in the
    /// clear is not an option — any relay on the path could harvest and spend it.
    case sealingFailed = "sealing_failed"

    /// Classify what the Keychain gave us, or nil when the key is usable.
    ///
    /// Pure, and separate from the Keychain read, so the classification can be argued with in a
    /// test without one (`decisions/testing-by-pure-decision.md`).
    static func forStoredKey(_ key: Data?) -> IntakeTagAbsence? {
        guard let key else { return .noKeyForPeer }
        guard key.count == intakeKeyLength else { return .storedKeyWrongSize }
        return nil
    }

    func log(peer accountId: String) {
        let peer = accountId.prefix(8)
        switch self {
        case .noKeyForPeer:
            // Debug, not info: this fires on every send to every peer who has not written to us,
            // and at info it would drown the category it is meant to make readable.
            Log.debug("Intake: no credential for \(peer)… (\(rawValue)) — this envelope pays a token", category: "Intake")
        case .storedKeyWrongSize, .derivationFailed, .sealingFailed:
            Log.error("Intake: cannot build a credential for \(peer)… (\(rawValue)) — this envelope pays a token", category: "Intake")
        }
    }
}

/// Length of an intake key, matching `construct-core::intake::INTAKE_KEY_LEN`. The core does not
/// export it, so this is the one place the number is written on this side.
private let intakeKeyLength = 32

/// Pure decisions about publishing and expiry, kept out of the actor so a test can argue with them
/// without a Keychain, a clock or a network (`decisions/testing-by-pure-decision.md`).
enum IntakePublishing {

    /// How many epochs ahead to publish.
    ///
    /// Not a round number for its own sake: a device that has been offline for a week must not
    /// break its *own* incoming traffic, because the tags its contacts present are the ones this
    /// device published. Seven days of silence is ordinary for a second device. The server caps
    /// one call at 14, so this stays inside a single publish.
    static let windowEpochs = 7

    /// The epochs a publish should cover, starting at `currentEpoch`.
    ///
    /// Includes the current one: a fresh install has published nothing, and its first incoming
    /// message is due today rather than tomorrow.
    static func epochsToPublish(currentEpoch: UInt64) -> [UInt64] {
        (0..<UInt64(windowEpochs)).map { currentEpoch + $0 }
    }

    /// Should we publish again, given when we last did and what epoch it is now?
    ///
    /// Re-publishing every launch would be a needless authenticated RPC on a hot path; never
    /// re-publishing would let the window drain silently until incoming traffic started paying
    /// again, with nothing visible on this device to say why. Once per epoch is the smallest
    /// cadence that keeps the window full.
    static func shouldPublish(lastPublishedEpoch: UInt64?, currentEpoch: UInt64) -> Bool {
        guard let last = lastPublishedEpoch else { return true }
        // A clock that moved backwards is not a reason to skip: `last > current` means we cannot
        // reason about the window at all, and publishing is cheap where being wrong is not.
        return last != currentEpoch
    }
}

@MainActor
final class IntakeCredentialService {

    static let shared = IntakeCredentialService()

    private let keychain = KeychainManager.shared
    private let defaults = UserDefaults.standard

    /// Accounts we have already handed our key to. Not secret — it is a list of who we talk to,
    /// which Core Data holds anyway — and deliberately not in the Keychain, where a per-contact
    /// item would be a second copy of the contact graph in a store that has no reason to carry one.
    private static let sentToKey = "construct.intake.sentTo.v1"
    private static let lastPublishedEpochKey = "construct.intake.lastPublishedEpoch.v1"

    private init() {}

    // MARK: - Our own key

    /// This account's intake key, minted on first use.
    ///
    /// Minting here rather than at registration is deliberate: an account created before this
    /// shipped has no key either, so the two cases are one, and there is no migration that has to
    /// find every existing install.
    func ownIntakeKey() -> Data {
        if let existing = keychain.loadOwnIntakeKey(), existing.count == intakeKeyLength {
            return existing
        }
        let fresh = Data(generateIntakeKey())
        keychain.saveOwnIntakeKey(fresh)
        Log.info("Intake: minted this account's intake key", category: "Intake")
        return fresh
    }

    // MARK: - Publishing

    /// Publish a window of tags so envelopes from vouched contacts owe no token.
    ///
    /// Silent on failure by design. A publish that did not land costs tokens, not delivery: our
    /// contacts' envelopes fall back to paying, exactly as they did before this existed.
    func publishTagWindowIfNeeded(now: Date = Date()) async {
        guard let accountId = AuthSessionManager.shared.currentUserId, !accountId.isEmpty else { return }

        let currentEpoch = intakeEpoch(unixSeconds: UInt64(now.timeIntervalSince1970))
        let last = defaults.object(forKey: Self.lastPublishedEpochKey) as? NSNumber
        guard IntakePublishing.shouldPublish(
            lastPublishedEpoch: last?.uint64Value, currentEpoch: currentEpoch
        ) else { return }

        let key = ownIntakeKey()
        var entries: [(epoch: UInt64, tag: Data)] = []
        for epoch in IntakePublishing.epochsToPublish(currentEpoch: currentEpoch) {
            guard let tag = try? intakeTag(
                intakeKey: [UInt8](key), recipientAccountId: accountId, epoch: epoch
            ) else { continue }
            entries.append((epoch, Data(tag)))
        }
        guard !entries.isEmpty else { return }

        do {
            let accepted = try await MessagingServiceClient.shared.publishIntakeTags(entries)
            // Recorded only on success. Recording the attempt would mean one failed publish costs
            // a whole epoch of tokens, because nothing would try again until tomorrow.
            defaults.set(NSNumber(value: currentEpoch), forKey: Self.lastPublishedEpochKey)
            Log.info("Intake: published \(accepted)/\(entries.count) tag(s) for epoch \(currentEpoch)+", category: "Intake")
        } catch {
            Log.info("Intake: tag publish failed (\(error.localizedDescription)) — contacts keep paying tokens until it lands", category: "Intake")
        }
    }

    // MARK: - Peer keys

    /// A peer handed us the key their account accepts.
    func recordPeerIntakeKey(_ key: Data, from accountId: String) {
        guard key.count == intakeKeyLength else {
            Log.error("Intake: peer \(accountId.prefix(8))… sent a \(key.count)-byte key — ignored", category: "Intake")
            return
        }
        keychain.savePeerIntakeKey(key, forAccount: accountId)
        Log.info("Intake: stored intake key from \(accountId.prefix(8))…", category: "Intake")
    }

    /// The sealed tag to attach to an envelope for `accountId`, or nil when we hold no key for
    /// them, cannot derive, or cannot seal.
    ///
    /// Nil is not a failure: the envelope pays with a token, which is what every envelope did
    /// before this existed. But it is the reason it paid, and until 2026-09-14 every one of the
    /// four ways to get here returned the same silent nil. The device log then said
    /// "sealed send WITH token" and nothing else, so "why did this envelope pay?" had no answer
    /// on the device that paid — which is exactly the question asked of the 09-13 stretch where
    /// the server counted 8 envelopes as `absent` and nobody could say which cause it was.
    func sealedTag(forRecipient accountId: String, now: Date = Date()) async -> Data? {
        let stored = keychain.loadPeerIntakeKey(forAccount: accountId)
        if let reason = IntakeTagAbsence.forStoredKey(stored) {
            reason.log(peer: accountId)
            return nil
        }
        // `forStoredKey` returning nil is exactly the statement that this is a usable 32-byte key.
        guard let key = stored else { return nil }

        let epoch = intakeEpoch(unixSeconds: UInt64(now.timeIntervalSince1970))
        guard let tag = try? intakeTag(
            intakeKey: [UInt8](key), recipientAccountId: accountId, epoch: epoch
        ) else {
            IntakeTagAbsence.derivationFailed.log(peer: accountId)
            return nil
        }
        // Sealed to the server's X25519 key with the same box `token_bytes` uses. SealedInner is a
        // plaintext proto the relay parses: a tag in the clear is one any relay can harvest and
        // then spend on this recipient until the epoch rolls.
        guard let sealed = await ServerKeyManager.shared.sealTokenBytes(Data(tag)) else {
            IntakeTagAbsence.sealingFailed.log(peer: accountId)
            return nil
        }
        return sealed
    }

    // MARK: - Lazy distribution

    /// Does this peer still need our key?
    ///
    /// Grandfathering is lazy by decision: sweeping the contact graph on upgrade would mean a
    /// hundred sealed control envelopes at once, each of which must itself be paid for, and would
    /// pay that for contacts the user may never write to again. The graph migrates in the order it
    /// is actually used.
    func peerNeedsOurKey(_ accountId: String) -> Bool {
        !sentTo().contains(normalise(accountId))
    }

    func markOurKeySent(to accountId: String) {
        var set = sentTo()
        set.insert(normalise(accountId))
        defaults.set(Array(set), forKey: Self.sentToKey)
    }

    /// We rotated, so every contact's copy is stale and must be re-sent lazily.
    ///
    /// Rotation *is* revocation — there is no server-side deny entry for one contact, by design.
    func forgetWhoHasOurKey() {
        defaults.removeObject(forKey: Self.sentToKey)
    }

    private func sentTo() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.sentToKey) ?? [])
    }

    private func normalise(_ accountId: String) -> String {
        accountId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
