//
//  SelfAddressedResidue.swift
//  Construct Messenger
//
//  What the self-addressed receive path left on disk before 2026-08-28.
//

import CoreData
import Foundation

/// One-shot removal of the rows and keys a delivery addressed `from == to == us` created.
///
/// The path that made them is closed — `SessionAddressing.isOwnReflection` drops such a delivery
/// before any peer is resolved, and the receipt that seeded it is suppressed at source — so nothing
/// here can recur. But nothing removes what already exists either, and on a multi-device account
/// that is a chat with yourself sitting in the list.
///
/// Exactly three things were created, and each is treated differently:
///
/// 1. **A `Chat` whose `otherUser` is our own account** — deleted. `Chat.findOrCreate` promises
///    "one chat per peer `User`" in its own header and never checked that the user is a peer.
/// 2. **A `knownIdentityKey` pinned on our own `User` row** — cleared, but the row is kept. That
///    row is the local profile (`AuthViewModel.loadUserFromCoreData` creates it deliberately); only
///    the pin is residue, written by the bundle fetch that ran once the receive path decided we
///    were a contact worth initialising a session with. It matters beyond tidiness:
///    `SessionAddressing.identityKey(ofDevice:in:)` scans every row holding a pin, so a stray one
///    can answer for a device it does not belong to.
/// 3. **A Double Ratchet session keyed by our account UUID** — deleted with the per-session
///    Keychain entries that hang off the same id. Wrong twice over: a session with ourselves, and
///    an id that names an account where everything below the seam must name a device. Nothing can
///    look it up again in any case — `contactId(forPeer:)` now answers with a device id.
///
/// Idempotent. The flag is set only after a run that actually reached Core Data, so a launch where
/// the store is not ready yet retries on the next one instead of recording the work as done — the
/// same discipline as the orchestrator-state accessibility migration.
enum SelfAddressedResidue {

    private static let clearedFlag = "construct.selfAddressedResidue.cleared.v1"

    /// What one run removed. Zero everywhere is the expected result on an account that never had a
    /// second device.
    struct Outcome: Equatable {
        var chatsRemoved = 0
        var pinCleared = false
        var sessionRemoved = false

        var isEmpty: Bool { chatsRemoved == 0 && !pinCleared && !sessionRemoved }
    }

    /// Run once per install. Safe to call on every launch.
    @MainActor
    static func clearIfNeeded(
        ourAccountId: String,
        in context: NSManagedObjectContext,
        defaults: UserDefaults = .standard
    ) {
        guard !ourAccountId.isEmpty else { return }
        guard !defaults.bool(forKey: clearedFlag) else { return }
        // Not ready is not the same as nothing to do: recording success here would retire the
        // cleanup on the one launch where it could not run.
        guard context.persistentStoreCoordinator != nil else { return }

        var outcome = clearStoredRows(ourAccountId: ourAccountId, in: context)
        outcome.sessionRemoved = CryptoManager.shared.removeSessionByStoredId(ourAccountId)

        defaults.set(true, forKey: clearedFlag)
        if outcome.isEmpty {
            Log.debug("Self-addressed residue: nothing to clear", category: "CryptoManager")
        } else {
            Log.info(
                "Self-addressed residue cleared: \(outcome.chatsRemoved) chat(s) with ourselves, "
                + "pin=\(outcome.pinCleared), session=\(outcome.sessionRemoved)",
                category: "CryptoManager"
            )
        }
    }

    /// The Core Data half, separated so it can be exercised against an in-memory store — the
    /// session half needs a live core and a Keychain, and the two failure modes are unrelated.
    @discardableResult
    static func clearStoredRows(
        ourAccountId: String,
        in context: NSManagedObjectContext
    ) -> Outcome {
        var outcome = Outcome()
        guard !ourAccountId.isEmpty else { return outcome }

        let chats = Chat.fetchRequest()
        chats.predicate = NSPredicate(format: "otherUser.id == %@", ourAccountId)
        for chat in (try? context.fetch(chats)) ?? [] {
            // `messages` cascades and `otherUser` nullifies, so this takes the transcript with it
            // and leaves the local profile row standing.
            context.delete(chat)
            outcome.chatsRemoved += 1
        }

        let users = User.fetchRequest()
        users.predicate = NSPredicate(format: "id == %@", ourAccountId)
        users.fetchLimit = 1
        if let me = try? context.fetch(users).first, let key = me.knownIdentityKey, !key.isEmpty {
            me.knownIdentityKey = nil
            outcome.pinCleared = true
        }

        if !outcome.isEmpty {
            context.saveAndLog()
        }
        return outcome
    }
}
