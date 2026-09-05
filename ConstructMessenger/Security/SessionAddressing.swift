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
        if let row = peerDeviceRow(deviceId, in: context) { return row.identityKey }
        // The pre-`PeerDevice` answer, kept as the fallback rather than deleted: `knownIdentityKey`
        // is still written by the bundle-verify path and is the only pin a device carries before
        // its first `recordDevices`. It answers for exactly one device per account — which is the
        // limitation `PeerDevice` exists to remove, so the set is asked first.
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "knownIdentityKey != nil")
        guard let users = try? context.fetch(req) else { return nil }
        for user in users {
            guard let key = user.knownIdentityKey, !key.isEmpty else { continue }
            if deriveDeviceId(identityPublicKey: [UInt8](key)) == deviceId { return key }
        }
        return nil
    }

    // MARK: - The peer's device set

    /// Every device of `accountId` this app has been told about, oldest first.
    ///
    /// **This is the replacement for `contactId(forPeer:)`.** That function answered "which device
    /// is this peer", and for an account with two devices there is no such answer — it returned the
    /// one derived from the single `User.knownIdentityKey` slot, and every caller below it then
    /// addressed that device as though it were the account. A Desktop linked 2026-08-30 failed to
    /// unseal 155 of 155 envelopes for exactly that reason. See
    /// `decisions/a-peer-is-a-set-of-devices.md`.
    ///
    /// Empty means "we have never recorded a bundle answer for this account", never "this account
    /// has no devices" — the same distinction `PeerDeviceRegistry.knownDevices` draws, and for the
    /// same reason: a transient fetch failure and an empty account are indistinguishable at the
    /// call site, and storing one as the other is an hour of confident wrong answers.
    ///
    /// Ordered by `firstSeenAt` so the walk order is stable across runs, and so the device a
    /// single-device peer has always had stays first — which is the order the pinned key produced
    /// before this entity existed.
    ///
    /// Runs on `context`'s queue, like its caller.
    static func devices(ofPeer accountId: String, in context: NSManagedObjectContext)
        -> [(deviceId: String, identityKey: Data)] {
        guard !accountId.isEmpty else { return [] }
        let req = PeerDevice.fetchRequest()
        req.predicate = NSPredicate(format: "accountId == %@", accountId)
        // `deviceId` breaks ties, and the tie is the ordinary case: devices first recorded from one
        // bundle answer are written microseconds apart, so `firstSeenAt` alone leaves the order of
        // a first fetch to whatever the store hands back. A walk whose order differs between runs
        // makes a failure reproduce on one launch and not the next.
        req.sortDescriptors = [
            NSSortDescriptor(key: "firstSeenAt", ascending: true),
            NSSortDescriptor(key: "deviceId", ascending: true)
        ]
        guard let rows = try? context.fetch(req) else { return [] }
        return rows.map { (deviceId: $0.deviceId, identityKey: $0.identityKey) }
    }

    /// Persist what the key server said about `accountId`'s devices.
    ///
    /// Called from the one place bundles are fetched, for the same reason
    /// `PeerDeviceRegistry.record` is: a store each caller has to remember to update is stale for
    /// whichever path was added last, and the staleness reads as a legal answer ("we do not know
    /// this account's devices") rather than as a fault.
    ///
    /// **Each pair is checked for self-consistency before it is stored.** `deviceId` is
    /// `SHA256(identityKey)[0..16]`, so the two halves of a row are one value and a row where they
    /// disagree is a row that would make the derivation and the store two carriers of it. A server
    /// answer that fails this is refused loudly rather than pinned — it is the same check
    /// `InviteVerifier` runs on an invite.
    ///
    /// **Nothing is removed here.** A device absent from `devices` may be deleted, or the answer
    /// may be narrowed, or the client may have dropped it locally on a failed hybrid-PQ check —
    /// three different states that look identical in this list. Pruning belongs to
    /// `reconcileDevices(_:activeSet:ofPeer:in:)`, which is given the set the server states
    /// separately for exactly that reason (§A.3).
    ///
    /// An empty `devices` is not recorded, for the reason stated on `devices(ofPeer:in:)`.
    ///
    /// Runs on `context`'s queue, like its caller.
    static func recordDevices(
        _ devices: [(deviceId: String, identityKey: Data)],
        ofPeer accountId: String,
        in context: NSManagedObjectContext
    ) {
        guard !accountId.isEmpty, !devices.isEmpty else { return }
        var touched = 0
        for device in devices {
            guard isCryptoIdentity(device.deviceId), !device.identityKey.isEmpty else { continue }
            guard deriveDeviceId(identityPublicKey: [UInt8](device.identityKey)) == device.deviceId else {
                Log.error(
                    "PEER_DEVICE_REJECTED: server named \(device.deviceId.prefix(8))… for \(accountId.prefix(8))… "
                    + "but its identity key derives to a different device — not pinning",
                    category: "Crypto"
                )
                continue
            }
            if let existing = peerDeviceRow(device.deviceId, in: context) {
                // `identityKey` cannot have changed: the id is a function of it, and a row is
                // found by that id. Only the account can move, and it moving is the server
                // reassigning a device — worth a line, not a silent overwrite.
                if existing.accountId != accountId {
                    Log.error(
                        "PEER_DEVICE_REHOMED: \(device.deviceId.prefix(8))… was \(existing.accountId.prefix(8))…, "
                        + "server now says \(accountId.prefix(8))… — keeping the first",
                        category: "Crypto"
                    )
                }
                continue
            }
            let row = PeerDevice(context: context)
            row.deviceId = device.deviceId
            row.accountId = accountId
            row.identityKey = device.identityKey
            row.firstSeenAt = Date()
            touched += 1
        }
        guard touched > 0 else { return }
        do {
            try context.saveOrThrow(category: "Crypto")
            Log.info(
                "PEER_DEVICE_PINNED: \(touched) new device(s) for \(accountId.prefix(8))… "
                + "(set is now \(Self.devices(ofPeer: accountId, in: context).count))",
                category: "Crypto"
            )
        } catch {
            Log.error("PEER_DEVICE_PERSIST_FAIL for \(accountId.prefix(8))…: \(error)", category: "Crypto")
        }
    }

    /// Record what the server said **and forget what it no longer names.**
    ///
    /// `activeSet` is `GetPreKeyBundlesResponse.active_devices`: the account's device set, stated
    /// by the server as its own answer rather than inferred from the bundles it happened to
    /// return. That distinction is the whole reason this function can exist and `recordDevices`
    /// cannot prune — `devices` is narrowed by the request, and narrowed again by this client,
    /// which drops any device whose hybrid-PQ bundle fails verification. Such a device is alive;
    /// only that bundle was unusable. Absence from `devices` means nothing; absence from
    /// `activeSet` means the device is gone.
    ///
    /// Why it matters: a Desktop signed out on 2026-09-01 was correctly deactivated server-side,
    /// and every peer went on holding its row. Nothing retires a device on this side, so the fan-out
    /// keeps sealing a copy to a key nobody holds and the teardown plan keeps naming it. The server
    /// stopped serving that device within seconds; the peers would have carried it forever.
    ///
    /// **An empty `activeSet` prunes nothing.** proto3 cannot distinguish an absent field from an
    /// empty one, so a server that predates `active_devices` answers exactly like an account whose
    /// every device was revoked. The two outcomes are not symmetric: not pruning costs a wasted
    /// copy to a device that is gone, pruning on empty deletes every peer's device set on the first
    /// fetch after launch. An account with no active devices has nothing to send to either way.
    ///
    /// A device the server just handed us a bundle for is kept even if `activeSet` omits it. That
    /// combination is the server contradicting itself inside one response, and the bundle is the
    /// half we can check: it carries a key whose derivation we verify. Trusting the list over the
    /// evidence would delete a device we are holding proof of.
    ///
    /// Runs on `context`'s queue, like its caller.
    static func reconcileDevices(
        _ devices: [(deviceId: String, identityKey: Data)],
        activeSet: [String],
        ofPeer accountId: String,
        in context: NSManagedObjectContext
    ) {
        recordDevices(devices, ofPeer: accountId, in: context)

        guard !accountId.isEmpty, !activeSet.isEmpty else { return }

        let keep = Set(activeSet).union(devices.map(\.deviceId))
        let stale = Self.devices(ofPeer: accountId, in: context)
            .map(\.deviceId)
            .filter { !keep.contains($0) }
        guard !stale.isEmpty else { return }

        for deviceId in stale {
            guard let row = peerDeviceRow(deviceId, in: context) else { continue }
            context.delete(row)
        }
        do {
            try context.saveOrThrow(category: "Crypto")
            Log.info(
                "PEER_DEVICE_RETIRED: \(stale.count) device(s) of \(accountId.prefix(8))… no longer "
                + "active — \(stale.map { $0.prefix(8) + "…" }.joined(separator: ",")) "
                + "(set is now \(Self.devices(ofPeer: accountId, in: context).count))",
                category: "Crypto"
            )
        } catch {
            Log.error("PEER_DEVICE_RETIRE_FAIL for \(accountId.prefix(8))…: \(error)", category: "Crypto")
        }
    }

    /// Every device of `peerId`, in the crypto space — the **translation only**.
    ///
    /// This is the half the core cannot do: it speaks `CryptoDeviceId` and has no notion of
    /// `ServerUserId`, so turning an account into a set of devices is this app's job and stays
    /// here. What must *not* stay here is the decision over that set — which of these devices an
    /// operation touches is a plan, and a plan is protocol
    /// (`AGENTS.md`, "The core decides, this app executes"). Callers hand the set to
    /// `OrchestratorCore.planTeardown` and act on what comes back.
    ///
    /// Renamed from `teardownTargets` when the decision moved into the core: the old name promised
    /// an answer this function is no longer entitled to give.
    ///
    /// A device id is its own set of one, unchanged. An account id expands to the devices we have
    /// pinned for it.
    ///
    /// The fallback is deliberate and narrow: an account we have never fetched a bundle for has no
    /// pinned set, and `contactId(forPeer:)` is then the only name we hold. That is the
    /// single-device case the pin was always right for, and it is the last place in this file
    /// allowed to call that function — everything else takes the set.
    ///
    /// Empty means we cannot name anyone, which is the same state in which no session exists.
    /// Callers skip; they must never fall back to addressing the account — that is what put a
    /// teardown in every device's queue and tore down siblings' healthy sessions.
    ///
    /// Runs on `context`'s queue, like its caller.
    static func deviceIds(ofPeer peerId: String, in context: NSManagedObjectContext) -> [String] {
        guard !peerId.isEmpty else { return [] }
        if isCryptoIdentity(peerId) { return [peerId] }
        let set = devices(ofPeer: peerId, in: context).map(\.deviceId)
        if !set.isEmpty { return set }
        return contactId(forPeer: peerId).map { [$0] } ?? []
    }

    /// One row by device id. Runs on `context`'s queue.
    private static func peerDeviceRow(_ deviceId: String, in context: NSManagedObjectContext) -> PeerDevice? {
        let req = PeerDevice.fetchRequest()
        req.predicate = NSPredicate(format: "deviceId == %@", deviceId)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    /// The account a device belongs to, and the identity key that names it — the seam read
    /// backwards, both halves at once.
    ///
    /// Returned together because they come from the same row and the same scan. A caller that
    /// asked for them separately would walk the contact list twice and, worse, could be handed a
    /// key and an account id that do not belong to each other if the two lookups were ever
    /// written against different predicates.
    ///
    /// Needed by paths the core hands a `contactId` — a device id — that must then address the
    /// **network**, which speaks account ids. `sendSessionHeartbeat` was doing that translation by
    /// not doing it: it put the device id straight into `Envelope.recipient`, where the server
    /// parses a UUID, gets nothing, and writes the envelope to a stream keyed by 32 hex characters
    /// that no reader subscribes to. Accepted, acknowledged, delivered nowhere.
    ///
    /// Runs on `context`'s queue, like its caller.
    static func peer(
        ofDevice deviceId: String, in context: NSManagedObjectContext
    ) -> (accountId: String, identityKey: Data)? {
        // An early exit, not the correctness rule: an account id fails the key comparison below
        // anyway, and a mutation replacing this guard with an emptiness check left every test
        // green. It is here so an obviously-wrong id does not walk the contact list, and that is
        // all it is worth claiming for it.
        guard isCryptoIdentity(deviceId) else { return nil }
        // The device set answers first, and it is the only source that can answer for a peer's
        // *second* device: the scan below reads `User.knownIdentityKey`, one slot per account, so
        // before `PeerDevice` this function returned nil for every device but the pinned one. A
        // caller that needed an account id for such a device — `sendEndSession` above all — had no
        // way to name it and sent to the account instead, which the server fans out to every
        // device of it. See `decisions/a-peer-is-a-set-of-devices.md`.
        if let row = peerDeviceRow(deviceId, in: context), !row.accountId.isEmpty {
            return (row.accountId, row.identityKey)
        }
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "knownIdentityKey != nil")
        guard let users = try? context.fetch(req) else { return nil }
        for user in users {
            guard let key = user.knownIdentityKey, !key.isEmpty, !user.id.isEmpty else { continue }
            if deriveDeviceId(identityPublicKey: [UInt8](key)) == deviceId {
                return (user.id, key)
            }
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
    /// The identity public key we pinned for `userId`, or `nil` when we hold none.
    ///
    /// Internal rather than private since 2026-09-05: `PrimarySendTag` needs the key itself, not
    /// the device id derived from it, to compute the pair secret that names our device to the
    /// recipient. Deriving the id and then looking the key back up would be the same read twice.
    static func pinnedIdentityKey(ofUser userId: String) -> Data? {
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
