//
//  LocalStoreOwnership.swift
//  Construct Messenger
//
//  Who the local Core Data store belongs to, and whether an arriving identity may have it.
//
//  INCIDENT (2026-08-09, build 593): after an unwanted reset the user registered a new account
//  and it came up holding the previous identity's twelve contacts — visible in the log two
//  seconds after registration ("subscribed to 12 contacts", "Session prewarm: 9 contact(s)").
//  They had to prune them by hand.
//
//  Core Data was wiped in exactly one place, `deleteAccount()`. Neither `performLocalSignOut()`
//  nor registration touched it, and `wipeAndReregister()` said so on purpose:
//  "Core Data (message history, contacts) is intentionally preserved." That is right for
//  seed-phrase recovery, which keeps the same `userId` — and wrong for "Create New Account",
//  which does not. One comment covered both, and the leak lived in the gap.
//
//  So the gate is not "wipe on sign-out" (that would destroy history for anyone who later
//  recovers with their seed). It is: data belongs to a `userId`, and nobody else may see it.
//

import Foundation

enum LocalStoreOwnership {
    /// UserDefaults is the right home for this: it must survive a Keychain wipe, since every
    /// path that loses the identity clears the Keychain and this marker is what tells the *next*
    /// identity that the store is not theirs.
    static let ownerKey = "construct.localStore.ownerUserId"

    enum Disposition: Equatable {
        /// The arriving identity owns this data.
        case keep
        /// Wipe before the identity is allowed to see anything.
        case wipe
    }

    /// - Parameters:
    ///   - storedOwner: `userId` recorded the last time an identity claimed this store.
    ///   - incomingUser: the identity now finishing authentication or registration.
    ///   - storeHasData: whether the store holds any contacts/chats/messages at all.
    static func disposition(
        storedOwner: String?,
        incomingUser: String,
        storeHasData: Bool
    ) -> Disposition {
        guard storeHasData else { return .keep }          // nothing to leak, nothing to lose
        guard let storedOwner, !storedOwner.isEmpty else {
            // Unlabelled data of unknown provenance. Exactly what must not be handed to an
            // identity that cannot prove it owns it.
            //
            // ⚠️ THIS IS ONLY SAFE BECAUSE OF `claimIfUnowned`. Every device installed before
            // this marker existed has unlabelled data AND a perfectly valid identity; without
            // the claim step at launch, this line deletes the history of every upgrading user —
            // far worse than the leak it is here to close. The claim runs while the existing
            // identity is still authenticated, so by the time anyone can reach registration the
            // marker is already set. Do not remove one without the other.
            return .wipe
        }
        return storedOwner == incomingUser ? .keep : .wipe
    }

    static func storedOwner(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: ownerKey)
    }

    /// Record `userId` as the owner of the local store.
    static func claim(_ userId: String, defaults: UserDefaults = .standard) {
        defaults.set(userId, forKey: ownerKey)
    }

    /// Upgrade path: label the store for the identity already using this device.
    ///
    /// Called at launch for an authenticated user, before registration is reachable. Returns
    /// true when it actually claimed, so the caller can log it once.
    @discardableResult
    static func claimIfUnowned(_ userId: String, defaults: UserDefaults = .standard) -> Bool {
        guard storedOwner(defaults: defaults) == nil else { return false }
        claim(userId, defaults: defaults)
        return true
    }
}
