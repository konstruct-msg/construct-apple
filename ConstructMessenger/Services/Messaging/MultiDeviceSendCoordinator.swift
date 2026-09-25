//
//  MultiDeviceSendCoordinator.swift
//  Construct Messenger
//
//  SenderSync — and the bookkeeping for copies the recipient's devices are still owed.
//
//  Overview
//  ────────
//  A message reaches the recipient's devices through `OutboundMessagePipeline.sendToRecipientDevices`,
//  one copy per device. This coordinator does what is left around that:
//  1. SenderSync — a copy to the sender's own other devices so conversation history stays in
//     sync. The server-side content type is SENDER_SYNC (= 23), which the receiving device
//     displays as an outgoing bubble in the same conversation.
//  2. The recipient bundle cache the pipeline opens sessions from, and the retry queue for
//     devices a send did not reach.
//
//  Until 2026-09-22 it also held the fan-out to the recipient's *other* devices — "other" than
//  the one the ordinary send reached — with its own session rule, seal key and failure handling.
//  There is no primary send now (`decisions/a-peer-is-a-set-of-devices.md`, item 1), so there is
//  no "other" and no fan-out; the loop is the pipeline's.
//
//  Session key convention
//  ──────────────────────
//  A session's contactId is a `CryptoDeviceId` — the 32-hex id derived from the peer device's
//  identity key. Every send below already holds one (`target.deviceId`) and passes it straight
//  down; nothing here composes a key out of two parts, and the account id travels separately as
//  `networkRecipientUserId` because it addresses the mailbox, not the ratchet.
//
//  It used to be a bare `userId` for the primary session and `userId:deviceId` for per-device
//  ones — two spellings of one thing, the first of which named an account to a layer that only
//  understands devices. `SessionAddressing` is the single seam now and everything below it is a
//  device id (`decisions/identity-is-a-set-of-keys.md`). The colon shape survives only as a
//  legacy Keychain account name the wipe must still recognise, in
//  `KeychainSessionAccounts.isIdentityShaped` — no code writes one.
//
//  Threading
//  ─────────
//  @MainActor — CryptoManager and SessionInitializationService both require main-actor
//  access. Fire-and-forget via a detached Task where callers are already on MainActor.
//

import Foundation
import CoreData
import CryptoKit

@MainActor
final class MultiDeviceSendCoordinator {

    static let shared = MultiDeviceSendCoordinator()
    private init() {}

    // MARK: - Own-device bundle cache

    private struct DeviceCache {
        var bundles: [DeviceBundleData]
        var fetchedAt: Date
    }
    private var ownDeviceCache: DeviceCache?
    private let cacheTTL: TimeInterval = 3600 // 1 hour

    /// A recipient's device bundles, keyed by their account id.
    ///
    /// Until 2026-09-03 there was none, and `fanOutToRecipientDevices` opened with a
    /// `getPreKeyBundles` before checking whether it needed one — so **every message** to a
    /// two-device peer cost a key-service round trip. The key service allows
    /// `BUNDLE_RATE_LIMIT_PER_MIN` requests a minute, and a conversation at ordinary typing pace
    /// goes past it: five fan-outs plus three session fetches in one minute on the stand, then
    ///
    ///     MultiDevice fan-out skipped for ffeeddc6… — reason=bundle_fetch_failed
    ///     believed=2: resourceExhausted: "Too many bundle requests"
    ///
    /// twice in a row. The peer's second device silently missed those messages. Type slowly and it
    /// works; type normally and it does not, which is what "the behaviour is unpredictable" was.
    private var recipientDeviceCache: [String: DeviceCache] = [:]

    /// **Derived, not chosen.** Three things bound it, and only one of them is about time.
    ///
    /// *It cannot be shorter than the conversation.* One fetch per message is what produced the
    /// rate-limit above. At five minutes a fan-out costs at most one fetch per five, which leaves
    /// the whole per-minute budget to session setup and healing, where it is actually needed.
    ///
    /// *Revocation does not bound it at all.* A stale entry cannot deliver anything to a device
    /// that has been revoked: the server routes by its own active set, and an envelope naming a
    /// device that is not in it falls back to every device rather than reaching the named one
    /// (`routing="unknown_device"`). The authority is the server's, and it is current. So the
    /// familiar worry — "we might still be talking to a device someone removed" — is not the
    /// constraint here.
    ///
    /// *What does bound it is a peer's **new** device.* It receives the envelope (the account
    /// stream is still written) but the copy inside is sealed to the devices we knew, so it sees
    /// nothing until we refetch. That is the window this number sets, and five minutes is short
    /// enough to pass unnoticed by someone still setting the device up — post-link history sync
    /// is off, so it starts empty regardless — and long enough to cost one request.
    ///
    /// The TTL is the backstop, not the mechanism: `recipientBundles(for:)` also drops an entry
    /// whose device set no longer matches what `PeerDevice` holds, and that store is rewritten by
    /// `SessionAddressing.reconcileDevices` from the `active_devices` of **every** bundles
    /// response, wherever in the app it was made.
    private let recipientCacheTTL: TimeInterval = 300

    /// When `refreshRecipientDevices` last asked, so a peer whose bundles are unavailable is asked
    /// at the TTL's pace rather than on every chat open.
    private var lastRefreshAttempt: [String: Date] = [:]

    /// True while `drainRetryQueue` is running, so a failing retry re-uses its entry instead of
    /// appending a second one. Safe as a plain `Bool` because the class is `@MainActor` and the
    /// drain never suspends between reading it and clearing it in a `defer`.
    private var isDraining = false

    /// Invalidate the own-device cache (call after linking or revoking a device).
    func invalidateOwnDeviceCache() {
        ownDeviceCache = nil
    }

    /// Cached bundles for a recipient, or `nil` when they must be fetched.
    ///
    /// Two ways to be stale, and the second is the one that matters. The TTL covers "nothing has
    /// told us anything for a while". The set comparison covers "something has": `PeerDevice` is
    /// rewritten by `SessionAddressing.reconcileDevices` from the `active_devices` of every
    /// bundles response the app makes, so a device linked or revoked since this entry was built
    /// shows up here without a fetch of our own.
    /// The recipient's device bundles, from the cache while it holds and fetched otherwise.
    ///
    /// The one place the key server is asked for a peer's bundles on the send path, so the cache
    /// above and `PeerDevice` (written by `KeyServiceClient` from every answer) see every fetch.
    /// Consumes a one-time pre-key only when a device we hold no session with will spend one.
    func recipientBundles(for recipientUserId: String) async throws -> [DeviceBundleData] {
        if let cached = cachedRecipientBundles(for: recipientUserId) { return cached }
        let fetched = try await KeyServiceClient.shared.getPreKeyBundles(
            userId: recipientUserId,
            consumeOneTimePrekey: fanOutNeedsOneTimePrekey(for: recipientUserId)
        )
        recipientDeviceCache[recipientUserId] = DeviceCache(bundles: fetched, fetchedAt: Date())
        return fetched
    }

    /// What the key server last said about this peer's devices, **without asking it again.**
    ///
    /// The send path merges this into the plan (`PlannedRecipientDevice.merge`) because it is free
    /// and carries bundles; it never reaches for the network to get it, which is the whole point
    /// of planning from `PeerDevice`.
    func knownRecipientDevices(for recipientUserId: String) -> [DeviceBundleData]? {
        cachedRecipientBundles(for: recipientUserId)
    }

    /// Ask the key server who this peer's devices are, when nothing recent has said.
    ///
    /// **A peer's new device is otherwise invisible.** `PeerDevice` is written from what arrives —
    /// an inbound message, a bundle response some other path made — and a device that has not
    /// written to us produces neither. The TTL on the cache above bounds the window only for a
    /// peer we are *already* fetching bundles for, which stops happening the moment we hold a
    /// session with every device we know: then nothing asks again, ever, and the five minutes that
    /// comment claims is unbounded in fact. This is the call that asks.
    ///
    /// Best-effort by construction: a failure leaves the plan on the set we hold, which is what a
    /// send would have used anyway. Driven by opening a conversation rather than by sending, so
    /// the key server sees one request per peer per TTL at most — the same request it already
    /// serves when a session is opened, and not a per-message signal of an active conversation.
    ///
    /// The refusal is throttled with the answer: a fetch that throws does not fill the cache, so
    /// without `lastRefreshAttempt` a peer whose bundles are unavailable would be asked again on
    /// every appearance of the chat.
    func refreshRecipientDevices(for recipientUserId: String) async {
        guard !recipientUserId.isEmpty else { return }
        guard cachedRecipientBundles(for: recipientUserId) == nil else { return }
        if let attempted = lastRefreshAttempt[recipientUserId],
           Date().timeIntervalSince(attempted) < recipientCacheTTL { return }
        lastRefreshAttempt[recipientUserId] = Date()

        do {
            let devices = try await recipientBundles(for: recipientUserId)
            Log.info(
                "MultiDevice: device set for \(recipientUserId.prefix(8))… refreshed — \(devices.count) device(s)",
                category: "MultiDevice"
            )
        } catch {
            Log.info(
                "MultiDevice: device set for \(recipientUserId.prefix(8))… not refreshed (\(error.localizedDescription)) — planning from what we hold",
                category: "MultiDevice"
            )
        }
    }

    private func cachedRecipientBundles(for recipientUserId: String) -> [DeviceBundleData]? {
        guard let cache = recipientDeviceCache[recipientUserId],
              Date().timeIntervalSince(cache.fetchedAt) < recipientCacheTTL
        else { return nil }

        let context = PersistenceController.shared.container.viewContext
        let known = SessionAddressing.devices(ofPeer: recipientUserId, in: context).map(\.deviceId)
        guard Self.cachedSetStillMatches(cached: cache.bundles.map(\.deviceId), known: known) else {
            Log.info(
                "MultiDevice: recipient bundle cache for \(recipientUserId.prefix(8))… dropped — device set changed",
                category: "MultiDevice"
            )
            recipientDeviceCache[recipientUserId] = nil
            return nil
        }
        return cache.bundles
    }

    /// Whether a bundle fetch for this recipient must consume a one-time pre-key.
    ///
    /// Only an X3DH consumes one, and X3DH happens for a device we have no session with. The call
    /// site passed `true` unconditionally while its own comment justified it with "a device we
    /// have no session with yet needs X3DH" — so every message to a two-device peer spent one of
    /// each device's pre-keys, and the hundred uploaded at link time lasted a hundred messages.
    ///
    /// Unknown counts as "yes": a recipient we hold no devices for is one we have certainly not
    /// established sessions with.
    private func fanOutNeedsOneTimePrekey(for recipientUserId: String) -> Bool {
        let context = PersistenceController.shared.container.viewContext
        let known = SessionAddressing.devices(ofPeer: recipientUserId, in: context).map(\.deviceId)
        return Self.needsOneTimePrekey(knownDeviceIds: known) {
            CryptoManager.shared.hasSession(for: $0)
        }
    }

    /// Whether a cached entry still describes the recipient's devices.
    ///
    /// **An empty `known` is not a match failure.** It means we hold no `PeerDevice` rows for that
    /// account — no evidence either way — and the TTL decides alone. Reading it as "they have no
    /// devices" would drop every entry on a peer we have never fetched devices for, which is
    /// exactly the peer the cache is for. Same shape as the empty own-device set in
    /// `StealthSenderService.classifyOtherDevice`, and the same trap.
    nonisolated static func cachedSetStillMatches(cached: [String], known: [String]) -> Bool {
        guard !known.isEmpty else { return true }
        return Set(known) == Set(cached)
    }

    /// Whether a bundle fetch must spend a one-time pre-key.
    ///
    /// Only an X3DH spends one, and that happens for a device we hold no session with. Unknown
    /// counts as yes: a recipient we hold no devices for is one we have certainly not established
    /// sessions with, and under-consuming would leave the fan-out unable to open a session at all.
    /// The two errors are not symmetrical — spending one we did not need costs a pre-key, not
    /// spending one we did costs the message.
    nonisolated static func needsOneTimePrekey(
        knownDeviceIds: [String],
        hasSession: (String) -> Bool
    ) -> Bool {
        guard !knownDeviceIds.isEmpty else { return true }
        return knownDeviceIds.contains { !hasSession($0) }
    }

    // MARK: - Public API

    /// Our own other devices, as far as this process currently knows — cache only, never a fetch.
    ///
    /// Used by the SENDER_SYNC receive path to decide which sessions to try and to derive the
    /// tag secrets. It must not go to the network: an incoming message is being routed, and the
    /// answer is needed now. An empty result simply means the primary session is the only
    /// candidate, which is the state a single-device account is in permanently. The cache fills on
    /// the first send that fans out.
    func knownOwnDevices(myUserId: String) -> [DeviceBundleData] {
        guard let cache = ownDeviceCache,
              Date().timeIntervalSince(cache.fetchedAt) < cacheTTL else { return [] }
        return cache.bundles
    }

    func knownOwnDeviceIds(myUserId: String) -> [String] {
        knownOwnDevices(myUserId: myUserId).map(\.deviceId)
    }

    /// Our siblings: the same set with **this** device removed.
    ///
    /// Separate accessor rather than a filter at each call site, because the set already had two
    /// consumers that filter (`senderSyncPeerIdentityKeys` here, `DeviceDeliveryPlan.targets` via
    /// its explicit `ourDeviceId`) and one that did not — the SENDER_SYNC candidate list. There it
    /// is not a wasted comparison: a candidate with no session sends the receive path to
    /// `initAndDecryptSenderSync`, which fetches a bundle over the network and runs X3DH, so this
    /// device listed as its own sibling costs one key-service request and one guaranteed AEAD
    /// failure per sync copy. 2026-09-03, Desktop's first minute after linking:
    ///
    ///     Rust core initReceivingSession failed: All 1 prekey(s) failed.
    ///     Last error: Decryption failed: AEAD decryption failed
    ///     SENDER_SYNC: initReceivingSession failed for f1a3d746f85c8f8ce226…
    ///
    /// `f1a3d746…` is that device's own id. It recovered on the next candidate, so nothing was
    /// lost — but the request was one of the ten that took it past the bundle rate limit, and past
    /// that point it could not rebuild any session at all.
    ///
    /// It cannot succeed, either: a copy a sibling sealed to us does not open against a session
    /// with ourselves. Relying on the AEAD failure to move the loop along is leaving a candidate in
    /// the list that is only ever wrong.
    func knownSiblingDeviceIds(myUserId: String) -> [String] {
        let myDeviceId = AuthSessionManager.shared.currentDeviceId
        return knownOwnDevices(myUserId: myUserId)
            .map(\.deviceId)
            .filter { $0 != myDeviceId }
    }

    /// Fill the own-device cache from the server, for the **receive** path.
    ///
    /// Until 2026-08-18 the cache had exactly one filler — the send path — so a device that had
    /// linked and not yet sent anything knew of no siblings at all. A SENDER_SYNC copy then had no
    /// candidate session to try, no device id to fetch a bundle for, and
    /// `handleUnopenedSenderSync` walked a list of one entry that carried no `:` and returned
    /// having done nothing and logged nothing. Observed on the two-simulator stand 2026-08-17: a
    /// freshly linked device received both copies and neither reached the transcript.
    ///
    /// Not a hot-path call: the receive side reaches for it only when it has no siblings on record
    /// **and** a copy from one has just arrived, which is once per device lifetime in the ordinary
    /// case. Never burns a one-time pre-key — these are our own devices.
    @discardableResult
    func refreshOwnDevices(myUserId: String) async -> [DeviceBundleData] {
        do {
            let all = try await KeyServiceClient.shared.getPreKeyBundles(
                userId: myUserId, consumeOneTimePrekey: false
            )
            ownDeviceCache = DeviceCache(bundles: all, fetchedAt: Date())
            Log.info(
                "MultiDevice: own-device list refreshed on the receive path — \(all.count) device(s)",
                category: "MultiDevice"
            )
            return all
        } catch {
            Log.error(
                "MultiDevice: own-device refresh failed for \(myUserId.prefix(8))…: \(error)",
                category: "MultiDevice"
            )
            return []
        }
    }

    /// Identity keys of our other devices, for reading the `-ss-<tag>` on an incoming copy.
    ///
    /// Public halves, not derived secrets: the pair secret is computed inside the core, one X25519
    /// per known device per message. Not cached there either — an account has units of devices, and
    /// a cache of derived key material is state that has to be invalidated when a device is
    /// revoked, a correctness risk out of proportion to ~50µs.
    func senderSyncPeerIdentityKeys(myUserId: String) -> [Data] {
        let myDeviceId = AuthSessionManager.shared.currentDeviceId
        return knownOwnDevices(myUserId: myUserId)
            .filter { $0.deviceId != myDeviceId }
            .map(\.bundle.identityPublic)
    }

    /// Our own identity private key — the other half of every pair secret above.
    ///
    /// Absent only before registration completes, and then there are no own devices to sync to.
    func ourIdentityPrivateKey() -> Data? {
        KeychainManager.shared.loadDeviceIdentityKey()
    }

    /// The tag for a copy addressed to `targetDeviceId`, or the legacy plain-hex prefix when the
    /// key material to compute one is missing.
    ///
    /// The fallback keeps a copy deliverable to a peer that would otherwise get an unreadable tag;
    /// it costs the same metadata the whole change removes, so it is logged rather than silent.
    static func senderSyncTag(
        baseMessageId: String,
        targetDeviceId: String,
        targetIdentityPublic: Data,
        ourIdentityPrivateKey: Data?
    ) -> String {
        guard let ourIdentityPrivateKey,
              let tag = SenderSyncDeviceTag.tag(
                  baseMessageId: baseMessageId,
                  targetDeviceId: targetDeviceId,
                  ourIdentityPrivateKey: ourIdentityPrivateKey,
                  peerIdentityPublicKey: targetIdentityPublic
              ) else {
            Log.error(
                "SenderSync: no pair secret for \(targetDeviceId.prefix(8))… — falling back to the plain device tag, which the relay can read",
                category: "MultiDevice"
            )
            return String(targetDeviceId.prefix(SenderSyncDeviceTag.legacyHexLength))
        }
        return tag
    }

    /// Our own other devices learn of an outgoing message.
    ///
    /// **The single answer to that question.** It had two callers and two answers until
    /// 2026-08-30: `ChatSendCoordinator` mirrored after a successful first attempt and
    /// `MessageRetryManager` did not. A message that failed its first send and succeeded on
    /// retry therefore reached exactly one device, permanently, while the sender's UI said sent.
    /// Measured on a three-device run that day: fifteen sends, two mirrored.
    ///
    /// Nothing reported it. The mirror is best-effort by design, so its absence and its failure
    /// look identical from the outside, and the devices that never learn of the message have
    /// nothing to notice.
    ///
    /// The recipient's devices are not this function's since 2026-09-22 — every one of them is
    /// reached by the send itself (`OutboundMessagePipeline.sendToRecipientDevices`).
    ///
    /// - Parameter wirePlaintext: pre-KNST `MessageContent` bytes — what SenderSync re-frames per
    ///   own device. Not display JSON (see local-message-payload-binary.md C1c).
    func mirrorOutgoing(
        wirePlaintext: Data,
        messageId: String,
        recipientUserId: String,
        senderUserId: String,
        senderDeviceId: String,
        timestamp: UInt64
    ) async {
        await sendSenderSync(
            plaintext: wirePlaintext,
            messageId: messageId,
            originalRecipientUserId: recipientUserId,
            senderUserId: senderUserId,
            senderDeviceId: senderDeviceId,
            timestamp: timestamp
        )
    }

    /// Send the copies earlier attempts owed, for entries whose backoff has elapsed.
    ///
    /// Called when the network comes back, beside `MessageRetryManager`'s drain — the two answer
    /// different questions ("is the message in their mailbox" versus "did every device of theirs
    /// get its copy") and a message can be complete by the first and owed by the second.
    ///
    /// The payload is rebuilt from the persisted row rather than stored, for the reason given on
    /// `FanoutRetryEntry`. That inherits `recoverWirePlaintext`'s limit: a media message cannot be
    /// rebuilt, so it is given up on rather than retried forever, and counted where the number can
    /// be read. Fixing that means retaining album protos, which is a change to what this app keeps
    /// on disk and is not §C's to make.
    ///
    /// Serial, not concurrent: each entry consumes a one-time pre-key per device from a fetch that
    /// is destructive by design, and a burst of parallel drains after a reconnect is how an account
    /// runs out of them. See `decisions/prekey-bundle-fetch-is-destructive.md`.
    func drainRetryQueue(currentUserId: String) async {
        guard !isDraining else { return }
        let due = FanoutRetryQueue.shared.due()
        guard !due.isEmpty else { return }

        isDraining = true
        defer { isDraining = false }

        guard let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty else {
            Log.info("Fan-out retry drain skipped — no device id", category: "MultiDevice")
            return
        }

        Log.info("Fan-out retry drain: \(due.count) entr\(due.count == 1 ? "y" : "ies") due", category: "MultiDevice")

        for entry in due {
            // The attempt is spent before it is made, not after. A drain that crashes or is
            // backgrounded mid-send would otherwise leave the count untouched and retry the same
            // entry on every reconnect for a day.
            guard FanoutRetryQueue.shared.recordAttempt(key: entry.key) != nil else {
                PerformanceMetrics.shared.record(.fanoutRetryGaveUp, label: "exhausted")
                Log.info(
                    "Fan-out retry gave up on \(entry.baseMessageId.prefix(8))… after \(FanoutRetryQueue.shared.maxAttempts) attempts",
                    category: "MultiDevice"
                )
                continue
            }

            // Both answers from one fetch. Asking twice — once for the plaintext, once to tell a
            // missing row from an unrebuildable one — would let the row be deleted in between and
            // label the outcome by a state that no longer holds.
            let context = PersistenceController.shared.container.newBackgroundContext()
            let recovered: (plaintext: Data?, rowExists: Bool) = await context.perform {
                let fr = Message.fetchRequest()
                fr.predicate = NSPredicate(format: "id == %@", entry.baseMessageId)
                fr.fetchLimit = 1
                guard let row = try? context.fetch(fr).first else { return (nil, false) }
                return (MessageRetryManager.recoverWirePlaintext(for: row), true)
            }

            guard let plaintext = recovered.plaintext else {
                // Two different endings sharing one shape, so they are labelled apart: a row that
                // is gone is benign, a row that cannot be rebuilt is a copy permanently lost.
                PerformanceMetrics.shared.record(
                    .fanoutRetryGaveUp,
                    label: recovered.rowExists ? "not_reconstructable" : "no_row"
                )
                FanoutRetryQueue.shared.remove(key: entry.key)
                continue
            }

            let plan = ChunkedMessageSender.shared.buildPlan(
                plaintext: plaintext,
                messageId: UUID(uuidString: entry.baseMessageId) ?? UUID()
            )
            guard !plan.payloads.isEmpty else {
                PerformanceMetrics.shared.record(.fanoutRetryGaveUp, label: "not_reconstructable")
                FanoutRetryQueue.shared.remove(key: entry.key)
                continue
            }

            do {
                let report = try await OutboundMessagePipeline.shared.sendToRecipientDevices(
                    plan: plan,
                    baseMessageId: entry.baseMessageId,
                    senderId: entry.senderUserId.isEmpty ? currentUserId : entry.senderUserId,
                    recipientId: entry.recipientUserId,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    spendUnit: TokenSpendUnitStore.paidUnit(
                        baseMessageId: entry.baseMessageId, recipientId: entry.recipientUserId
                    ),
                    // Empty means the previous attempt could not name anyone, so the retry sends
                    // to the whole set; a named set narrows to exactly the devices it lost.
                    onlyDevices: entry.owedDeviceIds.isEmpty ? nil : entry.owedDeviceIds
                )
                // The entry is updated from what this attempt actually lost, not left as it was.
                // A pass that reaches one device and loses another has to come out naming only
                // the one it lost: otherwise the next drain sends the first device a second
                // ciphertext of the same message, which is the defect this whole line of work
                // exists to remove, re-entered from the repair side.
                if report.owed.isEmpty {
                    FanoutRetryQueue.shared.remove(key: entry.key)
                } else {
                    FanoutRetryQueue.shared.replaceOwed(key: entry.key, owed: report.owed)
                }
            } catch {
                // The whole attempt failed before or across every device — the certificate, the
                // transport, no device known. The entry keeps its spent attempt and its shape;
                // the next pass tries again.
                await recordSkip("retry_send_failed", peer: entry.recipientUserId, error: error)
            }
        }
    }

    /// Record that a message still owes copies, unless this *is* the retry.
    ///
    /// A drain pass that fails must not enqueue a fresh entry beside the one it is working on —
    /// that would reset the attempt count and make the queue immortal. The drain owns the
    /// lifecycle of an entry it picked up; this only creates one for a first-time failure.
    func noteOwed(
        _ messageId: String,
        _ recipientUserId: String,
        _ senderUserId: String,
        owed: [String]
    ) {
        guard !isDraining else { return }
        FanoutRetryQueue.shared.enqueue(
            baseMessageId: messageId,
            recipientUserId: recipientUserId,
            senderUserId: senderUserId,
            owed: owed
        )
    }

    /// SenderSync: send a copy of an outgoing message to all of the sender's OWN
    /// other devices, encrypted with per-device sessions, content type = senderSync.
    ///
    /// `plaintext` MUST be the same **wire** bytes the recipient's copies were built from
    /// (`MessageContent` / pre-KNST payload), NOT display JSON or CTM1. This coordinator
    /// applies the same KNST chunking as `ChunkedMessageSender` so large albums and voice
    /// descriptors reassemble on the peer device. Receiving side stores CTM1 via the
    /// normal reassembler (`storagePayload`). See local-message-payload-binary.md C1c.
    ///
    /// Receiving devices show this as an outgoing bubble (sent by the local user)
    /// in the conversation with `originalRecipientUserId`.
    ///
    /// IMPORTANT: Multi-device internal traffic (SenderSync, broadcast resets) deliberately
    /// does NOT use Stealth/Sealed Sender.
    /// Server already knows this is the same user account. See stealth scope decisions.
    ///
    /// Errors are logged and swallowed — SenderSync is best-effort.
    func sendSenderSync(
        plaintext: Data,
        messageId: String,
        originalRecipientUserId: String,
        senderUserId: String,
        senderDeviceId: String,
        timestamp: UInt64
    ) async {
        guard !senderDeviceId.isEmpty else { return }
        guard !plaintext.isEmpty else {
            Log.info("SenderSync: empty wire plaintext — skip", category: "MultiDevice")
            return
        }
        do {
            let otherDevices = try await fetchOwnOtherDevices(
                myUserId: senderUserId,
                myDeviceId: senderDeviceId
            )
            guard !otherDevices.isEmpty else { return }

            // Same framing as the recipient copies so the sibling's reassembler can rebuild
            // MessageContent → CTM1. UUID from base messageId when well-formed.
            let planId = UUID(uuidString: messageId) ?? UUID()

            // The routing header goes on before chunking, so a multi-chunk sync carries it once
            // and the receiver strips it once, after reassembly. Without it the receiving device
            // cannot tell which conversation this copy belongs to: sender and recipient on the
            // wire are both us, and `conversation_id` is blanked by the server by design.
            //
            // A partner id that is not a UUID yields no header rather than a malformed one; that
            // send lands on the same unroutable path as a sender running an older build, which is
            // where all of them landed before this existed.
            let framedPlaintext: Data
            if let header = SenderSyncRouting(partnerUserId: originalRecipientUserId).encoded() {
                framedPlaintext = header + plaintext
            } else {
                Log.error(
                    "SenderSync: partner id '\(originalRecipientUserId.prefix(8))…' is not a UUID — sending without routing header, the copy will not be placeable",
                    category: "MultiDevice"
                )
                framedPlaintext = plaintext
            }

            let plan = ChunkedMessageSender.shared.buildPlan(
                plaintext: framedPlaintext,
                messageId: planId,
                // Byte 5 of the KNST header exists to carry the content type inside the ciphertext.
                // SENDER_SYNC was leaving it at the default 1, so the frame described itself as an
                // ordinary chat message while the envelope said 23.
                contentType: WireMessageKind.senderSync.canonicalContentType
            )
            guard !plan.payloads.isEmpty else {
                Log.info("SenderSync: chunk plan empty (payload too large?) — skip", category: "MultiDevice")
                return
            }

            // Our identity private key: the other half of the X25519 pair whose public half is in
            // every device's bundle. Absent only before registration completes, and then there are
            // no own devices to sync to either.
            let ourIdentityKey = KeychainManager.shared.loadDeviceIdentityKey()

            // Targets from the same plan the recipient copies come from, so "which devices, and
            // is this one of them" is answered once. `otherDevices` has already dropped this
            // device; the plan drops it again, which is deliberate — the filter belongs to the
            // decision, not to whichever caller remembered it.
            let targets = DeviceDeliveryPlan.targets(
                recipientDevices: [],
                ownDevices: otherDevices,
                ourDeviceId: senderDeviceId,
                recipientIsSelf: true
            )

            // Our own account is a DIFFERENT recipient from the peer, so this cannot join the
            // peer's unit — the server keys `token_spend_id` by `recipient_user_id` precisely so
            // one token cannot cover envelopes to two people. It gets its own unit instead, which
            // matters as soon as there is more than one sibling or the message is chunked; with a
            // single sibling and a single chunk it is one envelope and still one token, and that
            // one is irreducible.
            let syncSpendUnit = TokenSpendUnit.forEnvelopeCount(
                TokenSpendUnit.envelopeCount(
                    chunkCount: plan.payloads.count, recipientDeviceCount: targets.count
                )
            )

            for target in targets {
                // The tag names the device this copy is for, to that device only. It used to be
                // `deviceId.prefix(8)` — the id in plain hex, which the relay reads on every copy
                // it routes. See SenderSyncDeviceTag.
                let deviceTag = Self.senderSyncTag(
                    baseMessageId: messageId,
                    targetDeviceId: target.deviceId,
                    targetIdentityPublic: target.identityPublic,
                    ourIdentityPrivateKey: ourIdentityKey
                )
                for (index, payload) in plan.payloads.enumerated() {
                    // Discarded on purpose: SENDER_SYNC is a copy to one of *our* devices, and
                    // §C's queue retries copies owed to the **recipient**. A sibling that misses
                    // one heals on its next exchange, and re-sending here would need a second
                    // queue keyed by our own account. Counted (`sync_send_failed`), not retried —
                    // the number says whether that second queue is worth building.
                    _ = await sendToDevice(
                        plaintext: payload,
                        messageId: DeviceDeliveryPlan.wireId(
                            baseMessageId: messageId, tag: deviceTag,
                            audience: target.audience,
                            chunkIndex: index, chunkCount: plan.payloads.count
                        ),
                        networkRecipientUserId: senderUserId,
                        contactId: target.deviceId,
                        // Own devices come from a bundle fetch, so the plan always carries one.
                        bundle: target.bundle,
                        senderUserId: senderUserId,
                        recipientDeviceId: target.deviceId,
                        timestamp: timestamp,
                        spendUnit: syncSpendUnit
                    )
                }
            }
        } catch {
            Log.info(
                "SenderSync: own-device fetch failed for \(senderUserId.prefix(8))…: \(error)",
                category: "MultiDevice"
            )
        }
    }

    // MARK: - Private helpers

    /// One device did not get its copy — count it and say why.
    ///
    /// Every exit from the old fan-out used to be a `Log.info` and a `return`, which is why the
    /// release gate for §C could not be evaluated: nothing separated "this account has one device"
    /// from "the second device was never reached". See `MetricEvent.fanoutDeviceSkipped` for the
    /// closed set of reasons. The recipient copies count themselves in the pipeline now; what is
    /// left here is our own devices' sync and a retry attempt that failed whole.
    ///
    /// The `believed=` figure comes from `PeerDevice` — the durable account → devices directory
    /// filled at the same seam that fetches bundles — and is deliberately not folded into the
    /// counter. It is what we were last told, possibly hours ago. A belief in the log, a fact in
    /// the metric.
    private func recordSkip(
        _ reason: String,
        peer: String,
        error: Error? = nil,
        device: String? = nil
    ) async {
        PerformanceMetrics.shared.record(.fanoutDeviceSkipped, label: reason)

        let believed: Int
        if peer.isEmpty {
            believed = 0
        } else {
            let context = PersistenceController.shared.container.newBackgroundContext()
            believed = await context.perform {
                SessionAddressing.deviceIds(ofPeer: peer, in: context).count
            }
        }

        let target = device.map { " device=\($0.prefix(8))…" } ?? ""
        let why = error.map { ": \($0)" } ?? ""
        Log.info(
            "MultiDevice copy skipped for \(peer.prefix(8))… — reason=\(reason)" +
            "\(target) believed=\(believed)\(why)",
            category: "MultiDevice"
        )
    }


    private func fetchOwnOtherDevices(myUserId: String, myDeviceId: String) async throws -> [DeviceBundleData] {
        if let cache = ownDeviceCache,
           Date().timeIntervalSince(cache.fetchedAt) < cacheTTL {
            return cache.bundles.filter { $0.deviceId != myDeviceId }
        }
        // Enumerating OUR OWN devices — never burn our own one-time pre-keys just to
        // list them. (The server also refuses to consume on a self-fetch.)
        let all = try await KeyServiceClient.shared.getPreKeyBundles(userId: myUserId, consumeOneTimePrekey: false)
        ownDeviceCache = DeviceCache(bundles: all, fetchedAt: Date())
        // Sync our own SPK upload timestamp from the server-reported value.
        // This corrects stale local UserDefaults (e.g. set to Date.now during
        // account recovery while the server still holds an older key).
        if let own = all.first(where: { $0.deviceId == myDeviceId }),
           own.bundle.spkUploadedAt > 0 {
            PreKeyRotationService.shared.syncSpkUploadTimestamp(
                serverUploadedAt: TimeInterval(own.bundle.spkUploadedAt)
            )
        }
        return all.filter { $0.deviceId != myDeviceId }
    }

    /// One copy to one of **our own** devices: ensures a session exists, encrypts, sends.
    /// Swallows errors — counted as `sync_send_failed`, not retried.
    ///
    /// Unsealed, and that is the one legitimate exemption: the pair is (me, me), which the relay
    /// knows from the authenticated channel before it opens the envelope, and `conversation_id`
    /// is empty — so a seal would hide nothing. See `SealingExemption.ownDevices`. A copy to a
    /// **peer's** device is a different thing and does not come through here: the pair (me, them)
    /// is exactly what sealed sender hides, and `OutboundMessagePipeline.sendEncrypted` seals it.
    /// Until 2026-08-30 this function served both with the exemption hardcoded, and for the peer
    /// copies the claim was false — once per extra device of theirs, per message.
    private func sendToDevice(
        plaintext: Data,
        messageId: String,
        networkRecipientUserId: String,
        contactId: String,
        bundle: PublicKeyBundleData?,
        senderUserId: String,
        recipientDeviceId: String,
        timestamp: UInt64,
        spendUnit: TokenSpendUnit? = nil
    ) async -> Bool {
        do {
            // Ensure a session exists for this contactId; never clobber an existing one.
            if !CryptoManager.shared.hasSession(for: contactId) {
                guard let bundle else { throw CryptoManagerError.sessionNotFound }
                do {
                    _ = try SessionInitializationService.shared.initializeSession(
                        userId: contactId,
                        bundle: bundle
                    )
                } catch SessionError.peerSPKStale {
                    // Own replica has been offline too long to rotate its SPK — degrade rather
                    // than drop the sync. Flags the session at-risk (see stale-peer-reachability).
                    _ = try SessionInitializationService.shared.initializeSession(
                        userId: contactId,
                        bundle: bundle,
                        allowStale: true
                    )
                }
            }

            let encPayload = try OutboundSessionService.shared.encryptOutgoing(
                plaintext: plaintext,
                messageId: messageId,
                toDevice: contactId
            )

            // conversation_id stays empty on purpose. `direct:<me>:<partner>` names the person on
            // the other side, in the clear, once per extra device per message — for a multi-device
            // account it handed the server exactly the pairing sealed sender exists to hide.
            //
            // Nothing wanted it. `Envelope.conversation_id` has no reader anywhere on the server —
            // the only consumers of a field by that name are APNs payloads fed from group and
            // request ids, the message push path passes None, and it is in no migration — and the
            // server blanks it on delivery besides. The client stopped reading it from a received
            // envelope when SENDER_SYNC began routing from inside the ciphertext.
            _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: messageId,
                recipientId: networkRecipientUserId,
                senderId: senderUserId,
                conversationId: "",
                encryptedPayload: encPayload,
                timestamp: timestamp,
                // Written on the unsealed branch by `buildEnvelope`, because the outer field is
                // visible to the relay — and the relay already knows this pair.
                recipientDeviceId: recipientDeviceId,
                contentType: .senderSync,
                sealing: .identified(.ownDevices)
            )

            CryptoManager.shared.saveSessionToKeychain(forDevice: contactId)
            Log.info("MultiDevice[sync]: sent to \(contactId.prefix(20))…", category: "MultiDevice")
            return true
        } catch {
            // A device of *ours* that did not get its copy — labelled apart from a peer's device,
            // because "the peer never saw it" and "my iPad never saw it" are different failures
            // with the same shape.
            await recordSkip(
                "sync_send_failed",
                peer: networkRecipientUserId,
                error: error,
                device: contactId
            )
            return false
        }
    }

    // MARK: - Session Reset Broadcast (Изъян 8)

    /// Изъян 8: tell the user's other devices that the DR session with `contactId` was reset, so
    /// each can heal independently.
    ///
    /// **Not implemented — the send was removed on 2026-08-03 because it had no reader.**
    ///
    /// It used to encrypt `"__session_reset_notify__<contactId>__"` to every linked device with
    /// `content_type = SENDER_SYNC`. A repository-wide search finds zero consumers of that string:
    /// no device ever healed because of it. What it did do was arrive in `saveSenderSyncMessage`,
    /// fail every control-format check, fall through to the plain-text branch and get **saved as a
    /// visible message bubble containing that literal string** — so the feature's only observable
    /// effect was littering the transcript of multi-device accounts.
    ///
    /// Deleting the send loses nothing (no behaviour depended on it) and stops the litter. The
    /// metric below counts how often the notification *would* have gone out, which is the number
    /// worth having before deciding whether to build the real thing: a working version needs a
    /// routable content type plus a heal-trigger policy (when to heal, how not to loop two devices
    /// into healing each other), and that is a design decision, not a wiring fix. See TODO 32.
    func broadcastSessionReset(contactId: String) async {
        PerformanceMetrics.shared.record(
            .linkedDeviceResetNotifyUnimplemented,
            label: String(contactId.prefix(8))
        )
        Log.info(
            "Session reset with \(contactId.prefix(8))… — linked devices NOT notified (Изъян 8 unimplemented; they heal on their own next failed decrypt)",
            category: "MultiDevice"
        )
    }
}

