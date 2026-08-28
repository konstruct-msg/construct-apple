//
//  SessionAddressing.swift
//  Construct Messenger
//
//  The one place a user id becomes a crypto identity.
//

import Foundation
import CoreData

/// Who a Double Ratchet session is with, in the only terms the ratchet understands.
///
/// ## Why this exists
///
/// Two identifier spaces meet here, and until 2026-08-26 they met by accident. The app is
/// user-centric: a conversation, a transcript, a contact row are all keyed by `ServerUserId`.
/// The protocol is device-centric: a ratchet is between two *devices*, and the associated data it
/// binds must name the same pair on both sides.
///
/// While every account had one device the two spaces could be confused for free, and they were:
/// `local_user_id` and `contact_id` were both server UUIDs. The moment a second device appeared,
/// the send path started addressing it as `<userId>:<deviceId>` while the receiver's own
/// `local_user_id` stayed a bare UUID — and the AD stopped mirroring, permanently, on every
/// per-device message. See `decisions/identity-is-a-set-of-keys.md`.
///
/// The fix is not a better join between the two spaces. It is that **the crypto layer never sees
/// the account space at all**: everything below this seam is a `CryptoDeviceId`.
///
/// ## Why a device id is a safe identity
///
/// `deviceId == SHA256(identity_public)[0..16]`, derived by `deriveDeviceId` in the core. It is
/// not an allocation the server hands out and could hand out differently — it is a function of the
/// key the peer publishes, so two clients that hold the same key compute the same id and there is
/// nothing to keep in agreement. That is also why nothing here caches one: a cached derivation is
/// a second carrier of the value it was derived from.
enum SessionAddressing {

    /// This device's crypto identity.
    ///
    /// Read from the Keychain rather than derived, because it is needed to *construct* the core
    /// that would derive it. `CryptoManager.verifyLocalIdentity` closes that loop once the core
    /// exists: the stored value is a cache of `deriveDeviceId(our identity public)`, and a cache
    /// that disagrees with its source is repaired there, loudly.
    static func localIdentity() -> String {
        #if DEBUG
        if let override = localIdentityOverrideForTesting { return override }
        #endif
        return KeychainManager.shared.loadDeviceID() ?? ""
    }

    /// The crypto identity of the peer behind `userId`, or `nil` when we have no way to name them.
    ///
    /// Derived from the identity key we pinned for that contact, so it needs no network, no cache
    /// and no fresh bundle — and it answers during a locked-device background decrypt, which the
    /// key server cannot.
    ///
    /// `nil` means "we have never verified this contact's key", which is the same state in which
    /// no session could exist either. Callers treat it as "no session", never as an error.
    static func cryptoIdentity(ofUser userId: String) -> String? {
        guard !userId.isEmpty else { return nil }
        guard let identityKey = pinnedIdentityKey(ofUser: userId), !identityKey.isEmpty else {
            return nil
        }
        return deriveDeviceId(identityPublicKey: [UInt8](identityKey))
    }

    /// Translate an id from the account space into the crypto space.
    ///
    /// This is the seam. **Above it** — view models, routers, Core Data — an id names a person:
    /// a `ServerUserId`. **Below it** — the Rust core, the Keychain session accounts, the AD of
    /// every ratchet — an id names a device: a `CryptoDeviceId`. Everything that crosses passes
    /// through here, and nothing else in the app is allowed to know both spaces.
    ///
    /// An id that is already a device id passes through unchanged. This branch is an
    /// **optimisation, not a correctness rule**: removing it is behaviour-preserving, because a
    /// device id has no `User` row and the resolution below returns nil for it either way. It is
    /// here so the per-device paths — sender-sync, fan-out, candidate walking, all of which
    /// already hold a device id — do not take a Core Data fetch per call on the receive path.
    ///
    /// ## Why this returns nil rather than the id it was given
    ///
    /// It used to hand back the input when the peer's key had never been pinned, on the reasoning
    /// that the call which followed would fail as "no session" anyway. That made this function
    /// answer two different questions with the same type — here is the device, and here is what
    /// you gave me — which is the defect class the whole flip was undertaken to remove, left
    /// standing in the one function whose job is to remove it.
    ///
    /// It also cost the guard. With an account id able to leave here legitimately, nothing could
    /// assert that what reaches the core is a device id, and two of the four defects the
    /// three-simulator stand caught on 2026-08-26 were exactly an account id reaching the core.
    ///
    /// `nil` means "this peer cannot be named", which is the same state in which no session can
    /// exist. Callers treat it as "no session" — never as an error, and never by substituting the
    /// account id.
    static func contactId(forPeer id: String) -> String? {
        if SessionAddressing.isCryptoIdentity(id) { return id }
        guard let deviceId = SessionAddressing.cryptoIdentity(ofUser: id) else {
            Log.debug("No pinned identity key for \(id.prefix(8))… — cannot name a device", category: "Crypto")
            return nil
        }
        return deviceId
    }

    /// The crypto identity carried by an identity key we are holding right now.
    ///
    /// The authoritative source, and the only one that answers at **first contact**: a peer whose
    /// key we have not pinned yet has no `User` row to resolve through, and that is exactly the
    /// moment X3DH runs. Both init paths hold the peer's bundle when they are called, so they name
    /// the device from the key in hand rather than from what the contact list happens to know.
    ///
    /// Using the pinned row there instead is not a smaller version of this — it is wrong: the
    /// resolution fails, the seam hands back the account id, and the responder binds an account id
    /// into an AD whose initiator bound a device id. The symptom is `initReceivingSession` failing
    /// with "AEAD decryption failed" on a bundle that is entirely valid.
    static func cryptoIdentity(ofIdentityKey identityPublic: Data) -> String? {
        guard !identityPublic.isEmpty else { return nil }
        return deriveDeviceId(identityPublicKey: [UInt8](identityPublic))
    }

    /// The identity key whose device id is `deviceId` — the seam read **backwards**.
    ///
    /// Everything else here translates downward: account id → device id, because that is the
    /// direction the crypto layer needs. But some paths run the other way: they are handed a
    /// `contactId` by the core — a device id — and need something that lives in the account space.
    /// `StealthSenderService.recipientIdentityKey` is the one that mattered: it looks a peer up by
    /// `User.id`, which is an account id, so a device id found no row and the sealed send failed
    /// closed with `StealthDowngradeBlocked`.
    ///
    /// Devices 2026-08-27: the peer could not deliver END_SESSION to `b26a2cf8…` for that reason —
    /// `IK_MISS[no_row]` — while its Double Ratchet diverged once per incoming message. It had no
    /// way to say so, and nothing retried.
    ///
    /// A scan, not a cache. `deviceId == SHA256(identity_public)[0..16]`, so the pinned key *is*
    /// the answer and deriving it is exact; a stored reverse map would be a second carrier of a
    /// value the first one already determines. The list is the contact list, and this runs on a
    /// control path, not per message.
    ///
    /// Runs on `context`'s queue, like its caller.
    static func identityKey(ofDevice deviceId: String, in context: NSManagedObjectContext) -> Data? {
        guard isCryptoIdentity(deviceId) else { return nil }
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "knownIdentityKey != nil")
        guard let users = try? context.fetch(req) else { return nil }
        for user in users {
            guard let key = user.knownIdentityKey, !key.isEmpty else { continue }
            if deriveDeviceId(identityPublicKey: [UInt8](key)) == deviceId { return key }
        }
        return nil
    }

    /// True when `id` is already a crypto identity rather than an account id.
    ///
    /// Used only at the seam, to keep a caller that already holds a device id from being resolved
    /// a second time. Below the seam every id is a device id and this question does not arise.
    static func isCryptoIdentity(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy(\.isHexDigit)
    }

    // MARK: - Our own account

    /// Whether `userId` names the account this app is signed in as.
    ///
    /// Our own account is not a peer. It has no chat, no ratchet session and no delivery receipt —
    /// and it reaches all three anyway, because own-account traffic is addressed `from == to == us`
    /// (`MultiDeviceSendCoordinator` sends every SENDER_SYNC that way) while the receive path
    /// derives the peer as `from == me ? to : from`, which answers **me** when both halves are me.
    ///
    /// Asked of `AuthSessionManager`, which is where "who am I" is already resolved between the
    /// in-memory value and the Keychain fallback. Re-deriving it here would be a second carrier of
    /// the same fact, and this file exists because of what the last one cost.
    @MainActor
    static func isOurOwnAccount(_ userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        #if DEBUG
        if let override = ownAccountOverrideForTesting { return userId == override }
        #endif
        return userId == AuthSessionManager.shared.currentUserId
    }

    /// Whether an incoming delivery is one of our own sends handed back by the server's per-device
    /// fan-out, rather than a message from a contact.
    ///
    /// Own-account traffic is addressed `from == to == us`, and the server delivers every envelope
    /// to *all* of an account's device streams, so our own sends come back to us. SENDER_SYNC is
    /// the one carrier that legitimately looks like this, and the receive path branches on it
    /// first; anything still in this shape afterwards has no peer.
    ///
    /// This is deliberately a question about the **envelope**, not about the derived peer. The
    /// receive path computes `from == me ? to : from`, which quietly answers *me* when both halves
    /// are me — an expression that is correct for every pair except the one that matters. Asking
    /// the shape directly is what a test can pin.
    static func isOwnReflection(from: String, to: String, ourAccountId: String) -> Bool {
        guard !ourAccountId.isEmpty else { return false }
        return from == ourAccountId && to == ourAccountId
    }

    // MARK: - Who goes first

    /// Role in a concurrent-init tie-break.
    enum Role: Equatable { case initiator, responder }

    /// The tie-break rule, **asked of the core** rather than restated here.
    ///
    /// Both peers compute this independently, so any disagreement is not a retryable error: it is
    /// both-initiator or both-responder, permanently. Until 2026-08-26 the app carried its own copy
    /// of the comparison under a comment promising it matched the core byte-for-byte — and the flip
    /// to device addressing broke that promise without touching either line, because the core began
    /// ranking a pair of device ids while this side went on ranking a pair of account ids. Two
    /// correct implementations over two different pairs agree about half the time.
    ///
    /// A rule two sides must agree on has one implementation and the other side calls it.
    static func role(mine: String, theirs: String) -> Role {
        // The core answers with the same spelling it stamps on `SessionHealNeeded`, so the wire
        // name and the local decision cannot drift apart either.
        tieBreakRole(myId: mine, peerId: theirs) == "Initiator" ? .initiator : .responder
    }

    /// Whether we are the natural INITIATOR against `peerId`, or `nil` when the pair cannot be
    /// ranked because the peer has no name in the crypto space.
    ///
    /// This resolves **both** halves through the seam. That is the whole point: the core ranks
    /// (our device, their device), and a caller that ranks (our account, their account) has
    /// answered a different question with the same type.
    ///
    /// `nil` is not an error. It is the same state as "we have never pinned this contact's key",
    /// in which no session with them can exist and none can be built until a bundle fetch pins it.
    /// Callers decide what to do with it explicitly; none of them may substitute an account id.
    static func isNaturalInitiator(againstPeer peerId: String) -> Bool? {
        let mine = localIdentity()
        guard !mine.isEmpty, let theirs = contactId(forPeer: peerId) else { return nil }
        // Equal ids — self, or an echo of our own copy — need no special case here: the core
        // answers `Responder` for them and pins that in `test_an_id_does_not_win_against_itself`.
        // A guard restating it would be the same duplicate this function exists to remove; it was
        // written, found to have no observable effect, and dropped.
        return role(mine: mine, theirs: theirs) == .initiator
    }

    // MARK: - Internals

    #if DEBUG
    /// Test seam: lets a unit test answer without a Core Data stack.
    nonisolated(unsafe) static var pinnedIdentityKeyOverrideForTesting: ((String) -> Data?)?

    /// Test seam: lets a unit test answer without a Keychain entry.
    nonisolated(unsafe) static var localIdentityOverrideForTesting: String?

    /// Test seam: lets a unit test answer "which account is this" without an auth session.
    nonisolated(unsafe) static var ownAccountOverrideForTesting: String?
    #endif

    /// The identity key pinned for `userId`, read from whichever thread is asking.
    ///
    /// **Not `viewContext`.** The crypto path runs on background queues — the send queue, the
    /// stream's delivery queue, a push wake — and `viewContext` is main-queue confined. Reading it
    /// from another thread is undefined, and its most common outcome here is an empty result,
    /// which this function would report as "no pinned key" and the seam would then decline to name
    /// the peer's device. Nothing would look broken: the call that follows just says "no session".
    ///
    /// A private context with `performAndWait` is safe from any thread and reads the same store.
    private static func pinnedIdentityKey(ofUser userId: String) -> Data? {
        #if DEBUG
        if let override = pinnedIdentityKeyOverrideForTesting { return override(userId) }
        #endif
        let ctx = PersistenceController.shared.container.newBackgroundContext()
        var key: Data?
        ctx.performAndWait {
            let req = User.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", userId)
            req.fetchLimit = 1
            key = (try? ctx.fetch(req).first)?.knownIdentityKey
        }
        return key
    }
}
