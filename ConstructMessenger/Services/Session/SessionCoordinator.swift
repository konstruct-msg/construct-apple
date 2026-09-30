//
//  SessionCoordinator.swift
//  Construct Messenger
//
//  Owns the entire session lifecycle for all peers:
//  – Receiving open (a message carrying the handshake header, from its sender certificate)
//  – Answering the peer's decryption error (retire, resend) — the core decides, this executes
//  – KEY_SYNC handling (re-key sending session on server request)
//  – OTPK replenishment after session init
//
//  Sessions renew by sending (decisions/sessions-renew-by-sending.md): nothing is announced,
//  confirmed or ranked. The first message of a new session carries the handshake header, and a
//  record keeps the states a new one replaced.
//
//  ChatsViewModel owns stream lifecycle; SessionCoordinator owns session lifecycle.
//

import Foundation
import CoreData

@MainActor
final class SessionCoordinator: MessageRouterDelegate {

    // MARK: - Owned services

    private let messageRouter = MessageRouter()
    private let publicKeyBundleHandler = PublicKeyBundleHandler()
    private let sessionInitService = SessionInitializationService.shared

    // MARK: - State

    /// Forwarded to ChatsViewModel — fires when an E2E-encrypted delivery receipt is decrypted.
    var onE2EDeliveryReceiptDecrypted: (([String]) -> Void)?


    /// Formal session state machine for each peer **device**, backed by the pure `SessionReducer`.
    /// Phase entries: `.initializing` / `.active(establishedAt:)`; absence (`nil`) == no session.
    ///
    /// Keyed by `SessionScope`, not by account. A ratchet is between two devices, so its phase and
    /// its init lock are per device — see `SessionScope` for the mismatch this keying replaced.
    private var sessionPhases: [SessionScope: SessionReducer.Phase] = [:]

    /// Run one reducer transition for `scope` and commit the new phase.
    private func apply(_ event: SessionReducer.Event, for scope: SessionScope) {
        assertMainThread()
        let newPhase = SessionReducer.reduce(sessionPhases[scope], on: event)
        sessionPhases[scope] = newPhase
        // The establishment time used to be mirrored into the Keychain here, for the END_SESSION
        // stale-check. Both went on 2026-09-27: a decryption error names its state and needs no
        // dating (`decisions/sessions-renew-by-sending.md`).
    }

    private func assertMainThread(file: StaticString = #fileID, line: UInt = #line) {
        precondition(Thread.isMainThread, "SessionCoordinator state must be accessed on the main thread", file: file, line: line)
    }

    /// Returns true if a session init is currently in progress for `scope`.
    ///
    /// Per device: an init with one of a peer's devices must not report the others as busy. That
    /// is the whole point of the scope — the account-keyed version of this predicate is what made
    /// a peer's second device deaf while the first was initialising.
    private func isInitializing(_ scope: SessionScope) -> Bool {
        assertMainThread()
        if case .initializing = sessionPhases[scope] { return true }
        // A peer-wide lock (the RESPONDER walk, first contact) covers every device of that
        // account, so a device-scoped caller must see it. Splitting one coarse lock into per-device
        // locks without this would let a walk and a prewarm run at once and collide on the ratchet
        // the walk opens — a race the account-keyed version prevented by being too broad.
        let context = viewContext ?? PersistenceController.shared.container.viewContext
        let resolve: (String) -> String? = { PeerAddress.resolving(device: $0, in: context)?.account }
        for (held, phase) in sessionPhases {
            guard case .initializing = phase else { continue }
            if held.contains(scope, resolveAccount: resolve) { return true }
        }
        return false
    }

    /// Mark `scope` as initializing and return a `defer` block that clears the state.
    @discardableResult
    private func beginInit(_ scope: SessionScope) -> () -> Void {
        apply(.initStarted, for: scope)
        return { [weak self] in
            // `.initEnded` only clears the marker if still .initializing — it never clobbers
            // an .active set by a success path that ran inside the same init scope.
            self?.apply(.initEnded, for: scope)
        }
    }

    /// Mark `scope` as having an active session established right now.
    private func markActive(_ scope: SessionScope) {
        apply(.markActive(at: UInt64(Date().timeIntervalSince1970)), for: scope)
    }

    // MARK: - Injected references

    private var viewContext: NSManagedObjectContext?
    private weak var streamManager: MessageStreamManager?

    // MARK: - Setup

    func setContext(_ context: NSManagedObjectContext) {
        viewContext = context
        messageRouter.setContext(context)
        publicKeyBundleHandler.setContext(context)
    }

    /// Call once after init to wire MessageRouter delegate and the stream manager reference.
    func configure(streamManager: MessageStreamManager) {
        self.streamManager = streamManager
        messageRouter.delegate = self
        // The core's initiation plan needs to know whether the peer's own init is already in our
        // hands. The evidence is in the pending queue and `SessionInitializationService` does not
        // own it, so it is supplied from here — the one place that owns both.
        sessionInitService.peerInitInFlight = { [weak self] userId in
            self?.peerHandshakeIsHeld(for: userId) ?? false
        }
        // The core's ask to open a new session over the one held (the PQXDH v2 upgrade sweep).
        // The core names a device and the bundle fetch addresses an account, so the seam is read
        // backwards.
        SessionActionExecutor.shared.onOpenSession = { [weak self] deviceId in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else {
                Log.info(
                    "Requested reopen unanswerable: device \(deviceId.prefix(8))… belongs to no known contact",
                    category: "SessionCoordinator"
                )
                // Said, so the core stops waiting for the open now rather than at its time-out.
                if let answer = try? CryptoManager.shared.handleOrchestratorEvent(
                    .sessionBundleUnavailable(contactId: deviceId), tag: "open_session"
                ) {
                    SessionActionExecutor.shared.executeOffRouter(answer, site: "open_session_unknown_device")
                }
                return
            }
            Log.info("SESSION_STATE[reopen_requested]: opening a new session with \(peer)", category: "SessionInit")
            Task { @MainActor [weak self] in
                let answer = await self?.sessionInitService.answerOpenSession(device: deviceId, account: peer.account) ?? []
                guard let self else { return }
                // The save, what waited behind the open, or the refusal — the core's, not ours.
                self.messageRouter.resolveCoreDrain(answer, site: "open_session")
                self.sendSessionQueuedMessages(for: peer.account)
            }
        }
        // The peer could not read our current state with a device and the core retired it. The
        // next send opens a new one; this only carries the core's advice about how.
        SessionActionExecutor.shared.onSessionRetired = { [weak self] deviceId, withoutOneTimePrekey in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else {
                Log.info("SessionRetired for device \(deviceId.prefix(8))… of no known contact", category: "SessionCoordinator")
                return
            }
            Log.info(
                "SESSION_STATE[session_retired]: \(peer) could not read our state — the next send opens a new one\(withoutOneTimePrekey ? ", without a one-time prekey" : "")",
                category: "SessionInit"
            )
            if withoutOneTimePrekey {
                SessionReinitHintStore.shared.requestThreeDHReinit(for: peer.account)
            }
        }
        // The peer could not read one message we sent it: send that message again, to that device.
        SessionActionExecutor.shared.onResendMessage = { [weak self] deviceId, messageId in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else {
                Log.info("ResendMessage \(messageId.prefix(8))… for device \(deviceId.prefix(8))… of no known contact — not resent", category: "SessionCoordinator")
                return
            }
            self.resendAfterDecryptionError(messageId: messageId, to: PeerAddress(account: peer.account, device: deviceId))
        }
    }

    // MARK: - Public entry points

    /// Route a single incoming message through MessageRouter.
    func routeIncomingMessage(_ message: ChatMessage, in context: NSManagedObjectContext) {
        messageRouter.routeIncomingMessage(message, in: context)
    }

    /// Called when the stream receives a KEY_SYNC control message.
    func handleKeySyncRequest(for userId: String) {
        let scope = SessionScope.forAccount(userId)
        guard !isInitializing(scope) else {
            Log.info("KEY_SYNC skipped — session init already in progress for \(scope)", category: "SessionInit")
            return
        }
        let endInit = beginInit(scope)
        Log.info("SESSION_STATE[key_sync]: re-keying sending session for \(userId.prefix(8))…", category: "SessionInit")
        Task { [weak self] in
            guard let self else { return }
            defer { endInit() }
            do {
                let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                do {
                    try sessionInitService.initializeSession(userId: userId, bundle: bundle)
                } catch SessionError.peerSPKStale {
                    // Peer's SPK is stale; degrade rather than leave the re-key broken.
                    // The resulting session is flagged at-risk and healed if undecryptable.
                    try sessionInitService.initializeSession(userId: userId, bundle: bundle, allowStale: true)
                }
                Log.info("SESSION_STATE[key_sync_success]: session re-keyed for \(userId.prefix(8))…", category: "SessionInit")
            } catch {
                Log.error("SESSION_STATE[key_sync_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            }
        }
    }

    /// Pre-warm sessions for contacts we hold none with. Called once per app launch after the
    /// stream connects.
    ///
    /// Since 2026-09-04 the core answers `Wait` to an open with nothing to send, so what this does
    /// in practice is little. It told a peer we had lost a session with it (END_SESSION) until
    /// 2026-09-27; the peer now learns that from a decryption error on its next message.
    func prewarmSessions(for contactIds: [String]) {
        // Empty means the Keychain is unreadable, in which case no session decision can be made.
        guard !SessionAddressing.localIdentity().isEmpty else { return }

        // Do not make any session-missing decisions before the crypto core is built and
        // sessions have had a chance to restore from Keychain. While the core is nil,
        // hasSession returns false for every contact — prewarming here would send a
        // destructive END_SESSION + fresh re-init over a perfectly healthy session that
        // simply hasn't been imported yet (startup race, esp. with delayed auth refresh).
        // A later forceReconnect/network event re-triggers prewarm once the core is ready.
        let coreReady = CryptoManager.shared.isCoreReady
        guard coreReady else {
            Log.info("Session prewarm deferred — crypto core not ready yet", category: "SessionInit")
            return
        }

        let toPrewarm = contactIds.filter { peer in
            // A peer with no pinned identity key has no name in the crypto space: skip them — the
            // session establishes on the first send, whose bundle fetch pins the key.
            guard SessionAddressing.pinnedDevice(ofPeer: peer) != nil else { return false }
            return SessionReducer.shouldPrewarm(
                coreReady: coreReady,
                sessionExistsOrRestorable: CryptoManager.shared.hasOrRestoreSessionWithAnyDevice(ofPeer: peer)
            )
        }
        guard !toPrewarm.isEmpty else { return }

        Log.info("Session prewarm: \(toPrewarm.count) contact(s) need sessions", category: "SessionInit")
        Task { [weak self] in
            guard let self else { return }
            for contactId in toPrewarm {
                // Guard against both a session that appeared since we built toPrewarm
                // AND against a parallel prewarm Task for the same peer.
                // We insert into usersInitializingSession here (not inside
                // initializeSessionProactively) so that a second concurrent Task that
                // also reaches this point sees the flag and skips — otherwise both tasks
                // would slip past the guard, race through fetchBundle, and the second
                // would delete the session just created by the first.
                let scope = SessionScope.forAccount(contactId)
                guard !CryptoManager.shared.hasOrRestoreSessionWithAnyDevice(ofPeer: contactId),
                      !self.isInitializing(scope) else {
                    Log.info("Prewarm skipped — session exists or init in progress for \(scope)", category: "SessionInit")
                    continue
                }
                let endInit = self.beginInit(scope)
                defer { endInit() }

                await self.sessionInitService.initializeSessionProactively(
                    userId: contactId,
                    // The only `false` in the codebase, and the reason the parameter exists.
                    // A prewarm carries nothing: it opens a session because one is missing after a
                    // restart. 2026-09-04 12:30:11 this ran, and thirty-three seconds later the
                    // peer's user typed and opened a second INITIATOR session — two root keys, a
                    // divergence on both sides, thirty-two seconds of silence and four messages
                    // delivered in a batch. The core now answers `Wait` here.
                    hasOutboundWork: false,
                    onSuccess: { Log.info("Prewarm \(contactId.prefix(8))…", category: "SessionInit") },
                    onFailure: { err in Log.info("Prewarm \(contactId.prefix(8))…: \(err.localizedDescription)", category: "SessionInit") }
                )
            }
        }
    }

    // MARK: - MessageRouterDelegate

    /// `peer.device` is the device the core queued the message under — the one its sender
    /// certificate names — and the open is that device's alone.
    func messageRouter(_ router: MessageRouter, canOpenReceiving peer: PeerAddress, for message: ChatMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleReceivingOpen(peer: peer, message: message)
        }
    }

    func messageRouter(_ router: MessageRouter, needsUsernameUpdate peer: PeerAddress) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await self.publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: peer.account)
                await MainActor.run { _ = self.publicKeyBundleHandler.handlePublicKeyBundle(bundle) }
            } catch {
                Log.error("Failed to fetch public key for username update: \(error.localizedDescription)", category: "SessionCoordinator")
            }
        }
    }

    /// Re-establish a session for a peer that has QUEUED OUTBOUND messages but no live session:
    /// nothing inbound will open one, and the queued flush in `MessageRetryManager` would defer
    /// forever waiting for a session nothing creates. Opens one and flushes the queue, whose
    /// first message carries the handshake header.
    ///
    /// Guarded (`isCoreReady`, `!hasSession`, `!isInitializing` + `beginInit`) so repeated retry
    /// ticks don't spawn parallel inits and we never tear down a healthy-but-not-yet-imported
    /// session during the startup race.
    func reestablishSessionForQueuedOutbound(to userId: String) {
        assertMainThread()
        guard CryptoManager.shared.isCoreReady else {
            Log.info("reestablishSessionForQueuedOutbound: crypto core not ready — deferring for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard !CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId) else { return }
        let scope = SessionScope.forAccount(userId)
        guard !isInitializing(scope) else {
            Log.debug("reestablishSessionForQueuedOutbound: init already in progress for \(scope)", category: "SessionInit")
            return
        }
        Log.info("SESSION_STATE[zombie_recover]: no session for peer \(userId.prefix(8))… with queued messages — opening one", category: "SessionInit")
        let endInit = beginInit(scope)
        Task { [weak self] in
            guard let self else { endInit(); return }
            defer { endInit() }
            await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                // The peer has queued messages and no session — the queue is the work.
                hasOutboundWork: true,
                onSuccess: { },
                onFailure: { err in
                    Log.error("SESSION_STATE[zombie_recover_fail]: \(err.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            )
            self.sendSessionQueuedMessages(for: userId)
        }
    }

    /// The peer could not read something we sent it. `peer.device` is the device its sender
    /// certificate names — the one whose record the error is about; `payload` is the box the peer's
    /// core sealed to our identity key. The core opens it and answers: retire our current state
    /// when the error names it, resend the named message once, or nothing when the error is
    /// stale. END_SESSION (21), which this replaced, named no state, and the 30 s windows, the
    /// stale-by-timestamp check and the resend of everything unconfirmed stood in for that.
    func messageRouter(_ router: MessageRouter, receivedDecryptionError peer: PeerAddress, payload: Data) {
        guard let device = peer.device, !device.isEmpty else {
            // Unsealed: nothing names the device, and a record is per device.
            Log.info("DECRYPTION_ERROR from \(peer.account.prefix(8))… names no device — ignored", category: "SessionCoordinator")
            return
        }
        let actions: [CfeAction]
        do {
            actions = try CryptoManager.shared.handleOrchestratorEvent(
                .decryptionErrorReceived(contactId: device, payload: payload),
                tag: "decryption_error"
            )
        } catch {
            Log.error("DECRYPTION_ERROR from \(peer) not delivered to the core: \(error)", category: "SessionCoordinator")
            return
        }
        Log.info(
            "SESSION_STATE[decryption_error_received]: \(peer) — \(actions.isEmpty ? "stale, nothing to do" : "\(actions.count) action(s)")",
            category: "SessionInit"
        )
        // The save, `sessionRetired` and `resendMessage` all run in the executor, through the hooks
        // `SessionCoordinator` wires.
        SessionActionExecutor.shared.execute(actions)
    }

    func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String]) {
        onE2EDeliveryReceiptDecrypted?(messageIds)
    }

    // MARK: - RECEIVER session init

    /// Whether the peer is opening a session with us right now — a handshake of theirs queued in
    /// the core within the last 20 s. Asked of every device of the account known so far: the
    /// directory's, and any named only by the sender certificate of a message still waiting.
    ///
    /// Answered by the core since 2026-09-26, from the queue that holds the evidence. It was read
    /// here from `PendingSessionQueue`, the platform's copy of that queue.
    private func peerHandshakeIsHeld(for userId: String) -> Bool {
        let devices = Set(SessionAddressing.deviceIds(ofPeer: userId))
            .union(messageRouter.claimedDevicesAwaitingCore(ofPeer: userId))
        return CryptoManager.shared.peerHandshakeHeld(devices: Array(devices))
    }

    /// Stop trying to establish a receiving session for `userId` and release everything held on
    /// its behalf. The peer is told by the core (a decryption error per message given up).
    ///
    /// One authority for the give-up, because there are now two ways to reach it and they must not
    /// drift: `initReceivingSession` failed, or there was no handshake carrier to call it with.
    /// Both leave the same debts — a pending queue holding the device's stream cursor, and a peer
    /// who does not know we lost the session. The second path used to pay neither.
    ///
    /// No delivery receipt: nothing here was decrypted, so a checkmark would be a lie. Redelivery
    /// stops because the blamed messages are marked processed and their held cursor released
    /// (`releaseCoreQueued`) — the server trims from `Subscribe.since_cursor`, never from a receipt.
    ///
    /// - Parameter blamedMessageIds: the messages recorded as permanently failed so the
    ///   orphaned-init exception in `MessageRouter` does not re-process them on the next reconnect.
    /// Takes a **list** because the search is now two-dimensional: when it is exhausted, every
    /// carrier it tried has been proven unopenable against every device we know of, not just one.
    /// Blaming a single id left the others to re-trigger the same doomed search on the next
    /// reconnect — the queue is cleared either way, but the failure store is what stops the
    /// orphaned-init exception from bringing them back.
    private func giveUpInit(for userId: String, blamedMessageIds: [String], metricLabel: String) {
        PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: metricLabel)
        for id in blamedMessageIds {
            FailedInitMessageStore.shared.add(id)
            // Belt-and-suspenders alongside the failure store.
            if let context = viewContext {
                PersistentACKStore.shared.markProcessed(id, senderId: userId, in: context)
            }
        }
        messageRouter.releaseCoreQueued(blamedMessageIds)
        // Reset the phase to absent. Every caller is the RESPONDER open giving up, and it opened
        // no ratchet — so the subject is the peer-wide scope it locked, not any one device. The
        // core dropped its own queue when the open failed.
        apply(.initFailed, for: .wholePeer(userId))

        // The writer of each message given up is told by the core, with a decryption error in the
        // open's answer (`open_receiving`), and with the hint to open without a one-time prekey
        // when ours was the one missing. What is left here is our own side of it.
        Task { [weak self] in
            await self?.replenishOtpksAfterFailure(reason: "init_failed")
        }
    }

    /// Which device a completed RESPONDER init names to the core.
    ///
    /// The order is the whole point, and reversing it is the defect this exists to keep out. The
    /// device the session **opened against** is derived from the bundle in hand; the pinned one is
    /// looked up in `User.knownIdentityKey`. At first contact — which is exactly when a RESPONDER
    /// init runs — the pinned row does not exist yet, so a lookup-first order returns `nil` for a
    /// session that was just built and has already decrypted a message.
    ///
    /// `nil` only when neither answers, which is the state in which the core has nothing to be
    /// told about.
    nonisolated static func finalizeContactId(openedDevice: String?, pinnedDevice: String?) -> String? {
        // Normalised here rather than at three call sites: an empty string reads as a named device
        // at every `!= nil` downstream, and `pinnedDevice(ofPeer:)` is not the only thing that can
        // hand one back.
        if let openedDevice, !openedDevice.isEmpty { return openedDevice }
        guard let pinnedDevice, !pinnedDevice.isEmpty else { return nil }
        return pinnedDevice
    }

    /// How one `openReceiving` ended.
    private enum ReceivingOpenOutcome {
        /// A session exists with `device`, opened from `openerId`.
        case opened(device: String, openerId: String)
        /// Nothing opened. `tried` were refused or proven unopenable; the rest of the core's queue
        /// was dropped and is already released.
        case failed(tried: [String], lastError: String?)
        /// The core could not be asked, or could not check a certificate yet (no server key).
        /// Nothing was spent; what waits, waits for the redelivery.
        case unreachable
    }

    /// Ask the core to open a receiving session from what it holds for `peer.device`.
    ///
    /// First contact and a new state over one held alike, and nothing is fetched: each queued
    /// message opens with the key its sender certificate names
    /// (`decisions/first-message-opens-without-the-server.md`).
    /// Until 2026-09-27 this fetched the account's bundles and the core walked every carrier
    /// against every device; the bundle fetch also told the server whom the sealed message was from.
    ///
    /// `certificate` is the trigger message's: on success it records the device and its key, which
    /// the sealed replies need at once (the first reply after a first contact). The bundle
    /// fetch used to record them as a side effect; without it the first reply found no key
    /// (`IK_MISS[no_row]`, stand 2026-09-27). Recording it is sound only after the open: the core
    /// opened from this certificate's key because the server's signature on it checked out.
    private func openReceiving(
        _ peer: PeerAddress,
        site: String,
        certificate: SenderCertificate?
    ) async -> ReceivingOpenOutcome {
        let userId = peer.account
        guard let device = peer.device, !device.isEmpty else {
            return .failed(tried: [], lastError: nil)
        }
        guard let result = CryptoManager.shared.openReceiving(device: device) else {
            return .unreachable
        }
        if let kyberPrekeys = result.kyberPrekeys {
            KyberPrekeyService.persist(blob: kyberPrekeys)
        }
        // The save, the opener and what drained behind it — or, on failure, a decryption error to
        // the writer of each message given up.
        messageRouter.resolveCoreDrain(result.actions, site: site)

        guard let opened = result.openedDevice, let openerId = result.openerMessageId else {
            if result.awaitingServerKey {
                Log.error("SESSION_STATE[open_receiving_awaiting_server_key]: \(peer) — no server key to check the sender certificate with; the redelivery retries", category: "SessionInit")
                return .unreachable
            }
            let reason = result.lastError ?? ""
            Log.info(
                "SESSION_STATE[open_receiving_failed]: \(peer) — \(result.triedMessageIds.count) carrier(s) tried, \(result.droppedMessageIds.count) dropped; last: \(reason)",
                category: "SessionInit"
            )
            if reason.contains("PQXDH_REQUIRED") {
                Log.error("SESSION_STATE[pqxdh_required]: \(userId.prefix(8))… — sender is not on PQXDH v2", category: "SessionInit")
            } else if reason.contains("PQXDH_KEY_UNAVAILABLE") {
                Log.error("SESSION_STATE[pqxdh_key_unavailable]: \(userId.prefix(8))… — \(reason)", category: "SessionInit")
            } else if reason.hasPrefix("SENDER_") {
                Log.error("SESSION_STATE[sender_certificate_refused]: \(peer) — \(reason)", category: "SessionInit")
            }
            if reason.contains("cannot reproduce") {
                Log.info("SESSION_STATE[otpk_unreproducible]: \(userId.prefix(8))… — the core's decryption error asks for an open without a one-time prekey", category: "SessionInit")
            }
            // A carrier whose sender the core vouched for still refused: our own keys are out of
            // step with what the server serves. A refused certificate says nothing about ours.
            if !result.triedMessageIds.isEmpty, !reason.hasPrefix("SENDER_") {
                Task { await PreKeyRotationService.shared.verifyAndRepairKeyConsistency() }
            }
            messageRouter.releaseCoreQueued(result.droppedMessageIds)
            return .failed(tried: result.triedMessageIds, lastError: result.lastError)
        }

        let suite = CryptoManager.shared.sessionSuiteId(forDevice: opened)
        if suite > 0 {
            KeychainManager.shared.saveSessionSuiteId(userId: opened, suiteId: suite)
        }
        if let certificate, certificate.deviceId == opened {
            SessionAddressing.recordDevices(
                [(deviceId: certificate.deviceId, identityKey: certificate.identityKey)],
                ofPeer: userId
            )
        }
        Log.info(
            "SESSION_STATE[open_receiving]: \(userId.prefix(8))…/\(opened.prefix(8))… opened from \(openerId.prefix(8))…",
            category: "SessionInit"
        )
        return .opened(device: opened, openerId: openerId)
    }

    private func handleReceivingOpen(peer: PeerAddress, message: ChatMessage) async {
        let userId = peer.account
        // The one device the open touches. It was the whole peer while the open walked every
        // device bundle of the account and could file the session under any of them.
        let scope = SessionScope(peer)
        if isInitializing(scope) {
            Log.info("Session init already in progress for \(scope), skipping duplicate attempt", category: "SessionInit")
            return
        }
        let endInit = beginInit(scope)
        defer { endInit() }

        // Push-woken while locked: key material unreadable. Transient, not a broken session —
        // nothing is spent and nothing is told to the peer; the redelivery retries once the core
        // is restored. Tearing down here is the locked-launch desync.
        guard CryptoManager.shared.isInitialized else {
            Log.info("Receiving open deferred — core not initialized (device likely locked) for \(userId.prefix(8))… (no END_SESSION)", category: "SessionInit")
            return
        }

        switch await openReceiving(peer, site: "open_receiving_first", certificate: message.senderCertificate) {
        case .opened(let device, _):
            // Bob consumed one of his one-time prekeys for this X3DH.
            Task {
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
            }
            // The phase is about the one ratchet that opened.
            apply(.initSucceeded(at: UInt64(Date().timeIntervalSince1970)), for: .device(device))
            // Send what was queued for the peer while no session could carry it. Nothing is
            // announced back: the peer learns we hold the session from our next message on it.
            sendSessionQueuedMessages(for: userId)
        case .failed(let tried, _):
            // Nothing to open from is the same give-up as a carrier that would not open; both owe
            // the peer a restart.
            Log.info("initReceivingSession failed — giving up for \(userId.prefix(8))…", category: "SessionInit")
            giveUpInit(
                for: userId,
                blamedMessageIds: tried.isEmpty ? [message.id] : tried,
                metricLabel: tried.isEmpty ? "no_handshake_carrier" : "init_fail"
            )
        case .unreachable:
            break
        }
    }

    /// Tell the core the stream is back, and carry out what it does about it.
    ///
    /// The core answers `NetworkReconnected` by draining its own queue — messages that arrived
    /// while it held no session — and by arming its GC sweep. Nothing sent this event until
    /// 2026-09-26: the enum case existed, the handler existed, and no platform call reached it
    /// on iOS. It could not be wired while a drained message had nowhere to be saved; the router
    /// now keeps the envelope for every message the core queues (`resolveCoreDrain`).
    func networkReconnected() {
        guard CryptoManager.shared.isCoreReady else { return }
        do {
            let actions = try CryptoManager.shared.handleOrchestratorEvent(.networkReconnected, tag: "network_reconnected")
            messageRouter.resolveCoreDrain(actions, site: "network_reconnected")
        } catch {
            Log.error("NetworkReconnected not delivered to the core: \(error)", category: "SessionCoordinator")
        }
    }

    /// Sends the outgoing messages queued for `userId` (`.queued`) — ones that found no session,
    /// or a stealth send that could not seal. The re-queue on END_SESSION that fed it too went on
    /// 2026-09-27; a decryption error resends the one message it names instead.
    private func sendSessionQueuedMessages(for userId: String) {
        guard let context = viewContext,
              let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }
        let chatFetch = Chat.fetchRequest()
        chatFetch.predicate = NSPredicate(format: "otherUser.id == %@", userId)
        do {
            guard let chat = try context.fetch(chatFetch).first else { return }
            MessageRetryManager.shared.sendQueuedMessages(
                for: chat,
                recipientId: userId,
                currentUserId: myId,
                context: context
            )
        } catch {
            Log.error("Failed to fetch queued-message chat for \(userId.prefix(8))…: \(error)", category: "SessionInit")
        }
    }

    /// Replenish OTPKs after a session-init failure — append-only, guarded by
    /// low-water + cooldown inside the service. Force-replacing here (the old behavior)
    /// wiped keys that peers' in-flight inits still referenced, making the desync
    /// self-sustaining; see `OtpkReplenishmentService.replenishAfterInitFailure`.
    private func replenishOtpksAfterFailure(reason: String) async {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else { return }
        await OtpkReplenishmentService.replenishAfterInitFailure(deviceId: deviceId, reason: reason)
    }

    // The handshake controls — SESSION_RESET_INIT, the session ping and `session_ready` — and the
    // session-init `saveMessage` that discarded them on arrival lived here until 2026-09-27. A
    // session is opened by sending, so there is nothing to announce or confirm
    // (`decisions/sessions-renew-by-sending.md`).

    // MARK: - Resend after a decryption error

    /// The peer could not read `messageId`, which we sent it, and the core asked for it again
    /// (`ResendMessage`, once per message). It goes to that device alone — over a new state, when
    /// the core retired ours — and to nobody else: the peer's other devices read their copies.
    ///
    /// Until 2026-09-27 this was `resendUnconfirmedOutgoingMessagesIfNeeded`, run on END_SESSION:
    /// every unconfirmed outgoing row of the last five minutes, to every device of the peer, and
    /// the copies a sibling of ours had written among them (stand 2026-09-27: B resent A's
    /// messages). A decryption error names the message, so nothing is guessed.
    ///
    /// Text only, as the path it replaced: a media message's plaintext is not kept to resend.
    private func resendAfterDecryptionError(messageId: String, to peer: PeerAddress) {
        assertMainThread()
        guard let context = viewContext,
              let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty,
              let device = peer.device, !device.isEmpty else { return }
        // A sealed copy's id is the server's, not ours: the peer names what it received, and the
        // send response is where we learned which of our messages that is. Stand 2026-09-28: the
        // first error named `e474825e…` for the row `8b403ce9…`, and without this nothing was
        // resent. The map is persisted (`ServerMessageIdMap`) so an error answered across a
        // restart still finds the row — in memory, it retired the state and resent nothing.
        let localId = ServerMessageIdMap.shared.localId(for: messageId)
        let fetch = Message.fetchRequest()
        fetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "id ==[c] %@", localId),
            NSPredicate(format: "isSentByMe == YES"),
            NSPredicate(format: "toUserId == %@", peer.account)
        ])
        fetch.fetchLimit = 1
        guard let msg = (try? context.fetch(fetch))?.first else {
            Log.info("Resend: \(messageId.prefix(8))… for \(peer) is no message of ours here — not resent", category: "SessionInit")
            return
        }
        let plaintext = msg.displayText
        guard !plaintext.isEmpty else {
            Log.info("Resend: \(messageId.prefix(8))… has no text to resend", category: "SessionInit")
            return
        }
        Log.info("SESSION_STATE[resend_after_decryption_error]: \(messageId.prefix(8))… to \(peer)", category: "SessionInit")

        Task { @MainActor [weak self] in
            guard let self else { return }
            // No state with the device (the core retired it): open one by sending. The proactive
            // init opens every device of the account that has none, this one among them.
            if !CryptoManager.shared.hasSession(for: device) {
                do {
                    try await self.ensureSendingSession(for: peer.account, device: device)
                } catch {
                    Log.error("Resend: session init failed for \(peer): \(error.localizedDescription)", category: "SessionInit")
                    return
                }
            }
            // `.sending` ranks below `.sent`, so the guarded setter refuses the mark; the error is
            // what voided the evidence, so it goes through the writer that says so.
            msg.applyArchiveOutcome(.resend)
            msg.deliveryStatus = .sending
            msg.retryCount += 1
            context.saveAndLog()
            do {
                let plan = ChunkedMessageSender.shared.buildPlan(
                    plaintext: Data(plaintext.utf8),
                    messageId: UUID(uuidString: msg.id) ?? UUID()
                )
                guard !plan.payloads.isEmpty else {
                    msg.applyArchiveOutcome(.giveUp)
                    context.saveAndLog()
                    return
                }
                let response = try await OutboundMessagePipeline.shared.sendToRecipientDevices(
                    plan: plan,
                    baseMessageId: msg.id,
                    senderId: myId,
                    recipientId: peer.account,
                    timestamp: UInt64(msg.timestamp.timeIntervalSince1970),
                    onlyDevices: [device]
                ).status
                switch response.status.lowercased() {
                case "delivered": msg.deliveryStatus = .delivered
                case "queued": msg.deliveryStatus = .queued
                case "failed", "blocked": msg.deliveryStatus = .failed
                default: msg.deliveryStatus = .sent
                }
                context.saveAndLog()
            } catch is StealthDowngradeBlocked {
                // Stealth on but could not seal — keep it queued, never send identified.
                msg.deliveryStatus = .queued
                context.saveAndLog()
                SessionLifecycleController.shared.reestablishSessionForQueuedOutbound(to: peer.account)
            } catch {
                // `.failed` ranks below `.sent`: through the archive writer, as above.
                msg.applyArchiveOutcome(.giveUp)
                context.saveAndLog()
                Log.error("Resend of \(messageId.prefix(8))… failed: \(error.localizedDescription)", category: "SessionInit")
            }
        }
    }

    /// A session to send on with `device` of `userId`, opened by the proactive init when there is
    /// none — which opens one with every device of the account that lacks it.
    private func ensureSendingSession(for userId: String, device: String) async throws {
        if CryptoManager.shared.hasSession(for: device) {
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor [weak self] in
                guard let self else {
                    cont.resume(throwing: CancellationError())
                    return
                }
                await self.sessionInitService.initializeSessionProactively(
                    userId: userId,
                    // A message is being sent through this; that is the definition of the flag.
                    hasOutboundWork: true,
                    onSuccess: { cont.resume(returning: ()) },
                    onFailure: { cont.resume(throwing: $0) }
                )
            }
        }
    }
}
