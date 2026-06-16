//
//  SessionCoordinator.swift
//  Construct Messenger
//
//  Owns the entire session lifecycle for all peers:
//  – Receiving session init (RECEIVER role via X3DH)
//  – Sending END_SESSION (manual reset, logout, heal-exhausted)
//  – Session healing (re-key on messageNumber=0 decrypt failure)
//  – KEY_SYNC handling (re-key sending session on server request)
//  – OTPK replenishment after session init / heal exhaustion
//  – Pending message queue (messages that arrived before a session was ready)
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
    private let initMessageReassembler = ChunkedMessageReassembler()

    // MARK: - State

    /// Forwarded to ChatsViewModel — fires when an E2E-encrypted delivery receipt is decrypted.
    var onE2EDeliveryReceiptDecrypted: (([String]) -> Void)?

    /// Tracks when we last sent END_SESSION to each peer to prevent loop storms.
    private var endSessionSentAt: [String: Date] = [:]
    private let endSessionCooldown: TimeInterval = 30.0

    /// Shadow-only mirror of *every* END_SESSION send (rate-limited AND must-send), used solely
    /// to evaluate the Phase-2b cut-over question — "how often would the rate limiter suppress a
    /// currently must-send END_SESSION?" — without touching live behaviour. Never gates a send.
    private var shadowEndSessionSentAt: [String: Date] = [:]

    /// Tracks when we last attempted an automatic resend after receiving END_SESSION from a peer.
    /// Prevents resend loops when both sides reset simultaneously.
    private var resendAttemptedAt: [String: Date] = [:]
    private let resendCooldown: TimeInterval = 10.0
    private let resendWindow: TimeInterval = 5 * 60 // 5 minutes

    /// Watchdog tasks started after a tie-break WIN.
    /// If the RESPONDER (loser) does not reply within the timeout, re-sends the session ping
    /// so they can become RESPONDER even after a brief network outage.
    private var tieBreakWatchdogs: [String: Task<Void, Never>] = [:]
    private let tieBreakWatchdogTimeout: TimeInterval = 30.0

    /// Fallback tasks started when we are the natural RESPONDER (lower deviceId) and receive
    /// END_SESSION from the INITIATOR. If the INITIATOR does not send a new session init within
    /// the timeout, we override the natural ordering and proactively initialize ourselves.
    /// This prevents a permanent session deadlock when the INITIATOR is itself broken/offline.
    private var responderFallbackTasks: [String: Task<Void, Never>] = [:]
    /// 60 s gives ICE/network time to stabilise + fetchMissedMessages time to deliver the
    /// INITIATOR's X3DH message before we override ordering and create a competing session.
    private let responderFallbackTimeout: TimeInterval = 60.0

    /// Called when END_SESSION arrives from a userId that has no Core Data record yet
    /// (brand-new contact). ChatsViewModel subscribes to this callback and adds an ephemeral
    /// stream subscription so the INITIATOR's X3DH message can arrive via live stream.
    var onEphemeralSubscriptionNeeded: ((String) -> Void)?

    /// Timer that periodically evicts expired entries from cooldown dicts so they don't grow unboundedly.
    private var cooldownPurgeTimer: Timer?
    private let cooldownPurgeInterval: TimeInterval = 5 * 60 // every 5 minutes

    /// Formal session state machine for each peer contact, backed by the pure `SessionReducer`.
    /// Phase entries: `.initializing` / `.active(establishedAt:)`; absence (`nil`) == no session.
    private var sessionPhases: [String: SessionReducer.Phase] = [:]

    /// Run one reducer transition for `userId`, commit the new phase, and return its effects.
    /// Phase 1 consumes only the phase result here (initializing/active markers); the queue
    /// effects are exercised by tests and adopted by MessageRouter in a later phase.
    @discardableResult
    private func apply(_ event: SessionReducer.Event, for userId: String) -> [SessionReducer.Effect] {
        assertMainThread()
        let (newPhase, effects) = SessionReducer.reduce(sessionPhases[userId], on: event)
        sessionPhases[userId] = newPhase
        return effects
    }

    /// Effector: perform the pending-queue effects the reducer emitted. The reducer decides
    /// WHAT happens to the queue on each lifecycle transition; this carries out exactly the
    /// existing drain (skipping the already-decrypted init carrier) / clear semantics.
    /// `startInit`/`queueMessage`/`processMessage` are the incoming-message disposition and
    /// are performed in MessageRouter, not here.
    private func perform(_ effects: [SessionReducer.Effect], for userId: String, skippingFirst: Bool = false) {
        assertMainThread()
        for effect in effects {
            switch effect {
            case .drainQueuedMessages:
                drainPendingQueue(for: userId, skippingFirst: skippingFirst)
            case .clearQueuedMessages:
                messageRouter.removePendingMessages(for: userId)
            case .startInit, .queueMessage, .processMessage:
                break
            }
        }
    }

    private func assertMainThread(file: StaticString = #fileID, line: UInt = #line) {
        precondition(Thread.isMainThread, "SessionCoordinator state must be accessed on the main thread", file: file, line: line)
    }

    /// Returns true if a session init (or heal) is currently in progress for `userId`.
    private func isInitializing(_ userId: String) -> Bool {
        assertMainThread()
        if case .initializing = sessionPhases[userId] { return true }
        return false
    }

    /// Mark `userId` as initializing and return a `defer` block that clears the state.
    @discardableResult
    private func beginInit(_ userId: String) -> () -> Void {
        apply(.initStarted, for: userId)
        return { [weak self] in
            // `.initEnded` only clears the marker if still .initializing — it never clobbers
            // an .active set by a success path that ran inside the same init scope.
            self?.apply(.initEnded, for: userId)
        }
    }

    /// Mark `userId` as having an active session established right now.
    private func markActive(_ userId: String) {
        apply(.markActive(at: UInt64(Date().timeIntervalSince1970)), for: userId)
    }

    /// Return the timestamp (Unix seconds) when the active session for `userId` was established,
    /// or nil if there is no active session record.
    private func establishedAt(for userId: String) -> UInt64? {
        assertMainThread()
        if case .active(let t) = sessionPhases[userId] { return t }
        return nil
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
        startCooldownPurgeTimer()
    }

    // MARK: - Public entry points

    /// Route a single incoming message through MessageRouter.
    func routeIncomingMessage(_ message: ChatMessage, in context: NSManagedObjectContext) {
        messageRouter.routeIncomingMessage(message, in: context)
    }

    /// Called when the stream receives a KEY_SYNC control message.
    func handleKeySyncRequest(for userId: String) {
        guard !isInitializing(userId) else {
            Log.info("KEY_SYNC skipped — session init already in progress for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        let endInit = beginInit(userId)
        Log.info("SESSION_STATE[key_sync]: re-keying sending session for \(userId.prefix(8))…", category: "SessionInit")
        Task { [weak self] in
            guard let self else { return }
            defer { endInit() }
            do {
                let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                try sessionInitService.initializeSession(userId: userId, bundle: bundle, deleteExisting: true)
                Log.info("SESSION_STATE[key_sync_success]: session re-keyed for \(userId.prefix(8))…", category: "SessionInit")
            } catch {
                Log.error("SESSION_STATE[key_sync_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            }
        }
    }

    /// Send END_SESSION to a peer and archive + clear the local session.
    ///
    /// `rateLimited` marks calls that already passed the cooldown decision (the DR-diverge
    /// path). For every *other* caller (a "must-send" path) we run a shadow comparison: what
    /// would the rate limiter have decided here? This measures Phase-2b risk without changing
    /// behaviour — the send always proceeds.
    func sendEndSession(to userId: String, reason: String = "manual_reset", rateLimited: Bool = false) async throws {
        if !rateLimited {
            let candidate = SessionReducer.shouldSendEndSession(
                lastSentAt: shadowEndSessionSentAt[userId], now: Date(), cooldown: endSessionCooldown
            )
            // live = true (must-send paths always send today); candidate = the rate limiter's verdict.
            ShadowCompare.decide("end_session_must_send", key: userId, live: true, candidate: candidate, context: reason)
        }
        shadowEndSessionSentAt[userId] = Date()

        Log.info("Sending END_SESSION to \(userId): \(reason)", category: "ChatsViewModel")
        #if os(macOS)
        // On Desktop the engine owns the session state — dispatch via engine.
        EngineAdapter.shared.dispatch(.sendEndSession(contactId: userId))
        Log.info("END_SESSION dispatched to engine for \(userId.prefix(8))…", category: "ChatsViewModel")
        #else
        do {
            let response = try await MessagingServiceClient.shared.sendEndSession(to: userId, reason: reason)
            Log.info("END_SESSION sent successfully: \(response.messageId)", category: "ChatsViewModel")
        } catch {
            Log.error("Failed to send END_SESSION: \(error)", category: "ChatsViewModel")
            throw error
        }
        CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
        CryptoManager.shared.clearArchivedSessions(for: userId)
        Log.info("END_SESSION complete: session archived and cleared", category: "ChatsViewModel")
        #endif
    }

    /// Single rate-limited END_SESSION entry point for storm-prone recovery paths
    /// (DR-diverge). Suppresses repeats within `endSessionCooldown` per peer via the pure
    /// `SessionReducer.shouldSendEndSession` decision, and records the attempt time.
    /// Returns `true` iff a send was attempted (records + proceeds even if the network send
    /// throws, matching the prior inline behaviour). Must-send paths — logout broadcast,
    /// manual reset, terminal init/heal failures — call `sendEndSession` directly and are
    /// intentionally not rate-limited.
    @discardableResult
    private func sendEndSessionRateLimited(to userId: String, reason: String) async -> Bool {
        let now = Date()
        guard SessionReducer.shouldSendEndSession(
            lastSentAt: endSessionSentAt[userId], now: now, cooldown: endSessionCooldown
        ) else {
            Log.info("END_SESSION cooldown active for \(userId.prefix(8))…, skipping (\(reason))", category: "SessionCoordinator")
            return false
        }
        endSessionSentAt[userId] = now
        Log.info("Sending END_SESSION to \(userId.prefix(8))… (\(reason))", category: "SessionCoordinator")
        do {
            try await sendEndSession(to: userId, reason: reason, rateLimited: true)
        } catch {
            Log.error("Failed to send END_SESSION to \(userId.prefix(8))…: \(error)", category: "SessionCoordinator")
        }
        return true
    }

    /// Broadcast END_SESSION to all peers that have an active session (e.g., on logout).
    /// Pre-warm sessions for contacts where we are the natural INITIATOR (higher deviceId).
    /// Called once per app launch after stream connects. Ensures first messages are instant.
    func prewarmSessions(for contactIds: [String], skipEndSessionNotification: Bool = false) {
        let myId = AuthSessionManager.shared.currentUserId ?? ""
        guard !myId.isEmpty else { return }

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
            SessionReducer.shouldPrewarm(
                coreReady: coreReady,
                isNaturalInitiator: DeviceIdOrdering.isNaturalInitiator(myId: myId, peerId: peer),
                sessionExistsOrRestorable: CryptoManager.shared.hasOrRestoreSession(for: peer)
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
                guard !CryptoManager.shared.hasOrRestoreSession(for: contactId),
                      !self.isInitializing(contactId) else {
                    Log.info("Prewarm skipped — session exists or init in progress for \(contactId.prefix(8))…", category: "SessionInit")
                    continue
                }
                let endInit = self.beginInit(contactId)
                defer { endInit() }

                // Notify the peer that our session is missing ONLY when this prewarm
                // was triggered proactively (startup / stream-connect). When triggered
                // by onEndSessionReceived the peer has already sent us END_SESSION —
                // they already know their session with us needs reset. Sending another
                // END_SESSION in that path creates a ping-pong loop where each side
                // continuously triggers the other's END_SESSION handler.
                if !skipEndSessionNotification {
                    do {
                        try await self.sendEndSession(to: contactId, reason: "session_missing_restart")
                        self.endSessionSentAt[contactId] = Date()
                        Log.info("Prewarm: notified \(contactId.prefix(8))… of missing session before fresh init", category: "SessionInit")
                    } catch {
                        Log.error("Prewarm: END_SESSION to \(contactId.prefix(8))… failed (proceeding with prewarm): \(error.localizedDescription)", category: "SessionInit")
                    }
                }

                await self.sessionInitService.initializeSessionProactively(
                    userId: contactId,
                    onSuccess: { Log.info("Prewarm \(contactId.prefix(8))…", category: "SessionInit") },
                    onFailure: { err in Log.info("Prewarm \(contactId.prefix(8))…: \(err.localizedDescription)", category: "SessionInit") }
                )
            }
        }
    }

    func sendEndSessionToAllContacts(reason: String = "logout") async {
        Log.info("Sending END_SESSION to all contacts: \(reason)", category: "ChatsViewModel")
        let sessionUserIds = CryptoManager.shared.getAllSessionUserIds()
        Log.info("Found \(sessionUserIds.count) active sessions", category: "ChatsViewModel")
        var successCount = 0
        var failCount = 0
        for userId in sessionUserIds {
            do {
                try await sendEndSession(to: userId, reason: reason)
                successCount += 1
            } catch {
                Log.error("Failed to send END_SESSION to \(userId): \(error)", category: "ChatsViewModel")
                failCount += 1
            }
        }
        Log.info("END_SESSION broadcast: \(successCount) sent, \(failCount) failed", category: "ChatsViewModel")
    }

    // MARK: - MessageRouterDelegate

    func messageRouter(_ router: MessageRouter, needsReceipt messageIds: [String], to userId: String, status: Shared_Proto_Signaling_V1_ReceiptStatus) {
        streamManager?.sendReceipt(messageIds, to: userId, status: status)
    }

    func messageRouter(_ router: MessageRouter, needsPublicKeyBundle userId: String, for message: ChatMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handlePublicKeyBundleNeeded(userId: userId, message: message)
        }
    }

    func messageRouter(_ router: MessageRouter, needsUsernameUpdate userId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await self.publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
                await MainActor.run { _ = self.publicKeyBundleHandler.handlePublicKeyBundle(bundle) }
            } catch {
                Log.error("Failed to fetch public key for username update: \(error.localizedDescription)", category: "SessionCoordinator")
            }
        }
    }

    func messageRouter(_ router: MessageRouter, needsEndSession userId: String) {
        Task { [weak self] in
            guard let self else { return }
            // Cooldown gates the whole recovery sequence: if a recent END_SESSION is still in
            // its window, skip both the send AND the reinit/fallback below (avoids storms).
            guard await self.sendEndSessionRateLimited(to: userId, reason: "session_out_of_sync") else {
                return
            }
            let myId = AuthSessionManager.shared.currentUserId ?? ""
            guard !myId.isEmpty else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            if DeviceIdOrdering.isNaturalInitiator(myId: myId, peerId: userId) {
                Log.info("DR diverge: auto-reinit as natural INITIATOR for \(userId.prefix(8))…", category: "SessionInit")
                self.reinitAndAnnounceAsInitiator(to: userId, reason: "dr_diverge")
            } else {
                Log.info("DR diverge: starting RESPONDER fallback for \(userId.prefix(8))…", category: "SessionInit")
                self.startResponderFallback(for: userId)
            }
        }
    }

    func messageRouter(_ router: MessageRouter, needsSessionHeal userId: String, failedMessage: ChatMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleSessionHealNeeded(userId: userId, failedMessage: failedMessage)
        }
    }

    /// Seconds of clock-skew tolerance when deciding whether an END_SESSION pre-dates our session.
    private static let endSessionStaleFudge: UInt64 = 5

    func messageRouter(_ router: MessageRouter, isEndSessionStale userId: String, timestamp: UInt64) -> Bool {
        let established = establishedAt(for: userId)
        let stale = SessionReducer.isEndSessionStale(
            establishedAt: established, timestamp: timestamp, fudgeSeconds: Self.endSessionStaleFudge
        )
        // Diagnostic for the post-launch reset hypothesis: `established == nil` means we have no
        // in-memory establishment record, so we CANNOT filter a possibly-stale END_SESSION — and
        // if a live Rust session exists, it is about to be torn down. Surface this in device logs.
        if established == nil {
            let hasLive = CryptoManager.shared.hasSession(for: userId)
            Log.info("SESSION_STATE[end_session_stale_check]: \(userId.prefix(8))… ts=\(timestamp) established=nil hasLiveSession=\(hasLive) → not filtered\(hasLive ? " ⚠️ live session will be reset by a possibly-stale END_SESSION (no in-memory establishedAt)" : "")", category: "SessionInit")
        } else {
            Log.info("SESSION_STATE[end_session_stale_check]: \(userId.prefix(8))… ts=\(timestamp) established=\(established!) → \(stale ? "STALE (filtered)" : "fresh (acted on)")", category: "SessionInit")
        }
        return stale
    }

    func messageRouter(_ router: MessageRouter, receivedEndSession userId: String, timestamp: UInt64) {
        let myId = AuthSessionManager.shared.currentUserId ?? ""
        guard !myId.isEmpty else { return }
        guard DeviceIdOrdering.isNaturalInitiator(myId: myId, peerId: userId) else {
            Log.info("END_SESSION from natural INITIATOR \(userId.prefix(8))… — waiting as RESPONDER", category: "SessionInit")
            startResponderFallback(for: userId)
            onEphemeralSubscriptionNeeded?(userId)
            return
        }
        resendUnconfirmedOutgoingMessagesIfNeeded(to: userId)
        Log.info("END_SESSION received — re-init as natural INITIATOR for \(userId.prefix(8))…", category: "SessionInit")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            self.reinitAndAnnounceAsInitiator(to: userId, reason: "end_session_received")
        }
    }

    func messageRouter(_ router: MessageRouter, didWinTieBreak userId: String) {
        let suiteIdAtWin = Int(KeychainManager.shared.loadSessionSuiteId(userId: userId) ?? 0)
        Log.info("SESSION_STATE[tie_break_outcome]: INITIATOR role confirmed, peer=\(userId.prefix(8))… suiteId=\(suiteIdAtWin), sending SESSION_RESET_INIT", category: "SessionInit")
        reinitAndAnnounceAsInitiator(to: userId, reason: "tie_break_win")
    }

    /// Re-initialise as INITIATOR **and transmit** the X3DH init (SESSION_RESET_INIT)
    /// to the peer, then arm the tie-break watchdog to re-send if no `session_ready`
    /// comes back. Every natural-INITIATOR entry point must go through here.
    ///
    /// Why this exists: the DR-diverge and END_SESSION-as-initiator paths used to call
    /// bare `prewarmSessions`, which creates a local INITIATOR session but sends the peer
    /// *nothing*. The peer's RESPONDER wait then timed out after 60s and flipped to
    /// INITIATOR — producing a dueling-initiator deadlock where the winner buffers its
    /// outgoing messages forever (`SessionConfirmationTracker.pending` never clears) and
    /// silently drops the loser's inits (`stale_init_drop`). Transmitting the SRI here
    /// lets the RESPONDER bootstrap and reply `session_ready`, which clears `pending` and
    /// flushes the buffer via the existing markConfirmed → sendQueuedMessages path.
    private func reinitAndAnnounceAsInitiator(to userId: String, reason: String) {
        Log.info("SESSION_STATE[initiator_announce]: re-init + SESSION_RESET_INIT for \(userId.prefix(8))… (\(reason))", category: "SessionInit")
        Task { [weak self] in
            guard let self else { return }
            await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                onSuccess: { },
                onFailure: { err in
                    Log.error("SESSION_STATE[initiator_announce_fail]: \(err.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            )
            await self.sendSessionResetInit(to: userId)
            SessionConfirmationTracker.shared.markPending(userId)
        }
        startTieBreakWatchdog(for: userId)
    }

    func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String]) {
        onE2EDeliveryReceiptDecrypted?(messageIds)
    }

    // MARK: - RECEIVER session init

    private func handlePublicKeyBundleNeeded(userId: String, message: ChatMessage) async {
        if isInitializing(userId) {
            Log.info("Session init already in progress for \(userId.prefix(8))..., skipping duplicate attempt", category: "SessionInit")
            return
        }
        let endInit = beginInit(userId)
        Log.debug("Locked session init for \(userId.prefix(8))...", category: "SessionInit")

        do {
            let fetchStart = Date()
            let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)
            Log.info("SESSION_STATE[bundle_fetched]: userId=\(userId.prefix(8))..., duration=\(String(format: "%.2f", Date().timeIntervalSince(fetchStart)))s", category: "SessionInit")

            let success = publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                bundle,
                message: message
            ) { [weak self] chat, msg, decryptedBytes in
                self?.saveMessage(for: chat, with: msg, decryptedBytes: decryptedBytes)
            }

            if success {
                // New session established — reset END_SESSION cooldown so future failures are handled.
                endSessionSentAt.removeValue(forKey: userId)

                // ACK only after we successfully decrypted + persisted the first message.
                // This prevents message loss when initReceivingSession fails mid-flight.
                streamManager?.sendReceipt([message.id], to: userId, status: .delivered)
                if let context = viewContext {
                    PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
                }

                // Notify Rust orchestrator that RESPONDER-side session init completed.
                // Rust clears its init_lock for this contactId. We ignore returned
                // SaveSessionToSecureStore actions — the session was already persisted
                // by initReceivingSession above.
                do {
                    let sessionBytes = try CryptoManager.shared.exportSession(contactId: userId)
                    let event = CfeIncomingEvent.sessionInitCompleted(
                        contactId: userId,
                        sessionData: Data(sessionBytes)
                    )
                    _ = try CryptoManager.shared.handleOrchestratorEvent(event, tag: "session_init_completed_responder")
                } catch {
                    Log.error("SESSION_STATE[init_completed_finalize_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.sendEndSession(to: userId, reason: "session_init_completed_failed")
                        } catch {
                            Log.error("SESSION_STATE[init_completed_end_session_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                        }
                    }
                }

                // Replenish OTPKs — Bob consumed one OTPK for this X3DH session init.
                Task {
                    let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                    await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
                }
                // Transition to .active (records establishment time for stale END_SESSION
                // filtering) and drain the pending queue — both via the reducer: .initSucceeded
                // yields .active + a .drainQueuedMessages effect performed below.
                perform(apply(.initSucceeded(at: UInt64(Date().timeIntervalSince1970)), for: userId),
                        for: userId, skippingFirst: true)
                // Re-send messages that were re-queued on prior END_SESSION receipt.
                sendSessionQueuedMessages(for: userId)
                // Phase 2 of two-phase handshake: notify INITIATOR that RESPONDER
                // session is established. INITIATOR cancels its watchdog and flushes
                // any buffered outgoing messages.
                Task { [weak self] in
                    guard let self else { return }
                    await self.sendSessionReady(to: userId)
                }
            } else {
                // initReceivingSession failed — prekey exhausted or invalid.
                Log.info("initReceivingSession failed — clearing queue, sending END_SESSION to \(userId.prefix(8))...", category: "SessionInit")
                // ACK as delivered so the server advances the delivery cursor past this message.
                // Sending .failed causes some server implementations to re-enqueue for retry,
                // creating a cascade: on every reconnect the same undecryptable message comes
                // back, triggers another failed init, sends another END_SESSION, etc.
                // .delivered = "message reached device" — the END_SESSION we send separately
                // tells the sender that decryption failed and a fresh session is needed.
                streamManager?.sendReceipt([message.id], to: userId, status: .delivered)
                // Track as permanently failed so the orphaned-init exception in MessageRouter
                // does not re-process this message ID on subsequent reconnects.
                FailedInitMessageStore.shared.add(message.id)
                // Mark as permanently processed in ACK store (belt-and-suspenders).
                if let context = viewContext {
                    PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
                }
                // init failed → reset phase to absent + clear the pending queue, via the reducer.
                perform(apply(.initFailed, for: userId), for: userId)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sendEndSession(to: userId, reason: "session_init_failed")
                    } catch {
                        Log.error("SESSION_STATE[init_failed_end_session]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                    }
                    await self.uploadFreshOtpks(reason: "init_failed")
                }
            }
        } catch {
            Log.error("SESSION_STATE[bundle_fetch_failed]: userId=\(userId.prefix(8))..., error=\(error.localizedDescription)", category: "SessionInit")
        }

        endInit()
        Log.debug("Unlocked session init for \(userId.prefix(8))...", category: "SessionInit")
    }

    // MARK: - Session healing

    private func handleSessionHealNeeded(userId: String, failedMessage: ChatMessage) async {
        if isInitializing(userId) {
            Log.info("Heal skipped — session init already in progress for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        let endInit = beginInit(userId)
        Log.info("SESSION_STATE[heal_start]: fetching fresh bundle for \(userId.prefix(8))…", category: "SessionInit")

        defer {
            endInit()
            Log.debug("Heal lock released for \(userId.prefix(8))…", category: "SessionInit")
        }

        guard let context = viewContext else { return }

        let canContinue = SessionHealingService.shared.recordAttempt(
            for: failedMessage.id, in: context
        )

        do {
            let bundle = try await publicKeyBundleHandler.fetchPublicKeyWithRetry(userId: userId)

            let healed = publicKeyBundleHandler.handlePublicKeyBundleForIncomingMessage(
                bundle,
                message: failedMessage
            ) { [weak self] chat, msg, decryptedBytes in
                self?.saveMessage(for: chat, with: msg, decryptedBytes: decryptedBytes)
            }

            if healed {
                Log.info("SESSION_STATE[heal_success]: session healed for \(userId.prefix(8))…", category: "SessionInit")
                SessionHealingService.shared.removeRecord(for: failedMessage.id, in: context)

                // We can now decrypt the previously-failed X3DH init message: ACK it as delivered.
                streamManager?.sendReceipt([failedMessage.id], to: userId, status: .delivered)
                PersistentACKStore.shared.markProcessed(failedMessage.id, senderId: userId, in: context)

                // Heal does not reset establishment time (no markActive) — drain only.
                perform([.drainQueuedMessages], for: userId, skippingFirst: true)
            } else {
                Log.error("SESSION_STATE[heal_failed]: initReceivingSession still failing for \(userId.prefix(8))…", category: "SessionInit")
                if !canContinue {
                    Log.info("Heal exhausted — sending END_SESSION to \(userId.prefix(8))…", category: "SessionInit")
                    // ACK as delivered (same reasoning as initReceivingSession failure path):
                    // .failed receipt causes the server to re-enqueue, looping indefinitely.
                    streamManager?.sendReceipt([failedMessage.id], to: userId, status: .delivered)
                    // Permanently block re-processing of this message ID.
                    FailedInitMessageStore.shared.add(failedMessage.id)
                    PersistentACKStore.shared.markProcessed(failedMessage.id, senderId: userId, in: context)
                    perform([.clearQueuedMessages], for: userId)
                    SessionHealingService.shared.clearQueue(for: userId, in: context)
                    do {
                        try await sendEndSession(to: userId, reason: "heal_exhausted")
                    } catch {
                        Log.error("SESSION_STATE[heal_exhausted_end_session]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                    }
                    await uploadFreshOtpks(reason: "heal_exhausted")
                }
                // Otherwise leave HealingMessage in CoreData; next reconnect retries.
            }
        } catch {
            Log.error("SESSION_STATE[heal_bundle_error]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            if !canContinue {
                perform([.clearQueuedMessages], for: userId)
                SessionHealingService.shared.clearQueue(for: userId, in: context)
                do {
                    try await sendEndSession(to: userId, reason: "heal_bundle_unreachable")
                } catch {
                    Log.error("SESSION_STATE[heal_bundle_end_session]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Drain the pending queue for a peer after session init / heal succeeds.
    private func drainPendingQueue(for userId: String, skippingFirst: Bool) {
        let queued = messageRouter.drainPendingMessages(for: userId)
        let toProcess = skippingFirst ? queued.dropFirst() : queued[...]
        guard !toProcess.isEmpty, let context = viewContext else { return }
        Log.info("Decrypting \(toProcess.count) queued message(s) for \(userId.prefix(8))...", category: "SessionInit")
        for queuedMsg in toProcess {
            messageRouter.routeIncomingMessage(queuedMsg, in: context)
        }
    }

    /// Re-sends any outgoing messages that were marked `.queued` by `requeueUndeliveredOutgoing`
    /// after receiving END_SESSION (i.e. messages encrypted under the now-replaced session).
    private func sendSessionQueuedMessages(for userId: String) {
        // Session is now established — cancel any pending RESPONDER fallback.
        cancelResponderFallback(for: userId)
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

    /// Upload a fresh batch of OTPKs after session-init or heal failure.
    private func uploadFreshOtpks(reason: String) async {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else { return }
        Log.info("Force-uploading \(OtpkReplenishmentService.replenishBatchSize) fresh OTPKs (\(reason))", category: "OTPK")
        do {
            try await OtpkReplenishmentService.generateAndUpload(
                count: OtpkReplenishmentService.replenishBatchSize,
                deviceId: deviceId,
                replaceExisting: true
            )
        } catch {
            Log.error("Failed to upload fresh OTPKs (\(reason)): \(error)", category: "OTPK")
        }
    }

    /// Start a repeating timer that evicts expired entries from cooldown dicts.
    /// Prevents unbounded growth when contacts are frequently reset (e.g. during testing).
    private func startCooldownPurgeTimer() {
        assertMainThread()
        cooldownPurgeTimer?.invalidate()
        cooldownPurgeTimer = Timer.scheduledTimer(withTimeInterval: cooldownPurgeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.purgeStaleCooldowns()
            }
        }
    }

    private func purgeStaleCooldowns() {
        assertMainThread()
        let now = Date()
        // Cooldown entries older than 2× their window are safe to remove
        let endSessionTTL = endSessionCooldown * 2
        let resendTTL = resendCooldown * 2

        let beforeES = endSessionSentAt.count
        endSessionSentAt = endSessionSentAt.filter { now.timeIntervalSince($0.value) < endSessionTTL }
        let beforeRA = resendAttemptedAt.count
        resendAttemptedAt = resendAttemptedAt.filter { now.timeIntervalSince($0.value) < resendTTL }

        let removedES = beforeES - endSessionSentAt.count
        let removedRA = beforeRA - resendAttemptedAt.count
        if removedES + removedRA > 0 {
            Log.debug("Purged \(removedES) endSession + \(removedRA) resend cooldown entries", category: "SessionInit")
        }
    }

    // MARK: - Tie-break session establishment ping

    /// Encrypt and send an invisible session establishment ping to `userId`.
    /// Called after a tie-break WIN so the loser (lower deviceId) can immediately
    /// call `initReceivingSession` and become RESPONDER without waiting for user action.
    /// The receiver's `saveMessage` filters out the ping content so it is never shown in chat.
    /// Retries up to `pingMaxAttempts` times with exponential back-off on network failure.
    private let pingMaxAttempts = 3
    private let pingRetryBaseDelay: UInt64 = 1_000_000_000 // 1 s

    /// Send SESSION_RESET_INIT — atomic replacement for `sendEndSession` + `sendSessionPing`.
    ///
    /// Encodes the X3DH init payload (`msgNum=0`) with `contentType: .sessionResetInit`.
    /// RESPONDER atomically archives old session and inits as RESPONDER in one `handleEvent` pass,
    /// eliminating the 200 ms ordering window from the legacy two-step tie-break sequence.
    ///
    /// Falls back to the legacy two-step sequence if all attempts fail (backward compat).
    private func sendSessionResetInit(to userId: String) async {
        #if os(macOS)
        Log.info("SESSION_STATE[sri_engine]: dispatching InitSessionInitiator for \(userId.prefix(8))…", category: "SessionInit")
        EngineAdapter.shared.dispatch(.initSessionInitiator(contactId: userId))
        #else
        guard CryptoManager.shared.hasSession(for: userId) else {
            Log.info("SESSION_STATE[sri_skip]: no INITIATOR session for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }

        for attempt in 1...pingMaxAttempts {
            do {
                let sriContent = "__session_reset_init_\(UUID().uuidString)__"
                let sriId = UUID().uuidString.lowercased()
                let _ = try await MessagingServiceClient.shared.sendMessage(
                    messageId: sriId,
                    recipientId: userId,
                    senderId: myId,
                    conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                    encryptedPayload: try OutboundSessionService.shared.encryptSessionControl(
                        plaintext: sriContent,
                        messageId: sriId,
                        recipientId: userId
                    ),
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    contentType: .sessionResetInit
                )
                Log.info("SESSION_STATE[sri_sent]: SESSION_RESET_INIT to \(userId.prefix(8))… (attempt \(attempt))", category: "SessionInit")
                return
            } catch {
                Log.error("SESSION_STATE[sri_fail]: attempt \(attempt)/\(pingMaxAttempts): \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                if attempt < pingMaxAttempts {
                    do {
                        try await Task.sleep(nanoseconds: pingRetryBaseDelay * UInt64(attempt))
                    } catch {
                        return
                    }
                } else {
                    Log.info("SESSION_STATE[sri_fallback]: SESSION_RESET_INIT exhausted, falling back to two-step for \(userId.prefix(8))…", category: "SessionInit")
                    do {
                        _ = try await MessagingServiceClient.shared.sendEndSession(to: userId, reason: "sri_fallback")
                    } catch {
                        Log.error("SESSION_STATE[sri_fallback_end_session_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                    }
                    do {
                        try await Task.sleep(nanoseconds: 300_000_000)
                    } catch {
                        return
                    }
                    await sendSessionPing(to: userId)
                }
            }
        }
        #endif
    }

    private func sendSessionPing(to userId: String) async {
        #if os(macOS)
        // InitSessionInitiator (dispatched by sendSessionResetInit) already sent the first
        // encrypted message — there is no separate ping step on the engine path.
        _ = userId
        #else
        guard CryptoManager.shared.hasSession(for: userId) else {
            Log.info("SESSION_STATE[tie_break_ping_skip]: no INITIATOR session for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }

        for attempt in 1...pingMaxAttempts {
            do {
                let pingContent = "__session_ping_\(UUID().uuidString)__"
                let pingId = UUID()
                let pingMessageId = pingId.uuidString.lowercased()
                let _ = try await MessagingServiceClient.shared.sendMessage(
                    messageId: pingMessageId,
                    recipientId: userId,
                    senderId: myId,
                    conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                    encryptedPayload: try OutboundSessionService.shared.encryptSessionControl(
                        plaintext: pingContent,
                        messageId: pingMessageId,
                        recipientId: userId
                    ),
                    timestamp: UInt64(Date().timeIntervalSince1970)
                )
                Log.info("SESSION_STATE[tie_break_ping]: sent to \(userId.prefix(8))… (attempt \(attempt)) — loser can now init as RESPONDER", category: "SessionInit")
                return
            } catch {
                Log.error("SESSION_STATE[tie_break_ping_fail]: attempt \(attempt)/\(pingMaxAttempts): \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                if attempt < pingMaxAttempts {
                    // Exponential back-off: 1s, 2s
                    do {
                        try await Task.sleep(nanoseconds: pingRetryBaseDelay * UInt64(attempt))
                    } catch {
                        return
                    }
                } else {
                    Log.error("SESSION_STATE[tie_break_ping_exhausted]: loser \(userId.prefix(8))… must re-initiate manually", category: "SessionInit")
                }
            }
        }
        #endif
    }

    // MARK: - Session ready signal (RESPONDER → INITIATOR, phase 2 of two-phase handshake)

    /// Sent by the RESPONDER after a successful `initReceivingSession`.
    /// Signals to the INITIATOR that both sides have established matching sessions,
    /// allowing them to cancel the watchdog and flush any buffered outgoing messages.
    private func sendSessionReady(to userId: String) async {
        guard CryptoManager.shared.hasSession(for: userId) else {
            Log.info("SESSION_STATE[session_ready_skip]: no RESPONDER session for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }

        do {
            let readyContent = "__session_ready_\(UUID().uuidString)__"
            let readyMessageId = UUID().uuidString.lowercased()
            let _ = try await MessagingServiceClient.shared.sendMessage(
                messageId: readyMessageId,
                recipientId: userId,
                senderId: myId,
                conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                encryptedPayload: try OutboundSessionService.shared.encryptSessionControl(
                    plaintext: readyContent,
                    messageId: readyMessageId,
                    recipientId: userId
                ),
                timestamp: UInt64(Date().timeIntervalSince1970)
            )
            Log.info("SESSION_STATE[session_ready_sent]: RESPONDER notified INITIATOR \(userId.prefix(8))…", category: "SessionInit")
        } catch {
            Log.error("SESSION_STATE[session_ready_fail]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
        }
    }

    // MARK: - Tie-break watchdog

    /// Start a watchdog Task that re-sends the session ping if the RESPONDER has not
    /// replied within `tieBreakWatchdogTimeout` seconds.  Cancels any prior watchdog
    /// for the same peer so multiple tie-breaks don't stack up.
    private func startTieBreakWatchdog(for userId: String) {
        assertMainThread()
        tieBreakWatchdogs[userId]?.cancel()
        tieBreakWatchdogs[userId] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.tieBreakWatchdogTimeout * 1_000_000_000))
            } catch {
                return // Task was cancelled — RESPONDER replied in time
            }
            guard !Task.isCancelled else { return }
            // RESPONDER has not replied — reinitialize session so the retry ping
            // is a fresh X3DH init (msgNum=0) that RESPONDER can accept.
            Log.info("SESSION_STATE[tie_break_watchdog]: timeout — re-prewarming for \(userId.prefix(8))…", category: "SessionInit")
            await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                onSuccess: { },
                onFailure: { err in
                    Log.error("SESSION_STATE[watchdog_reinit_fail]: \(err.localizedDescription)", category: "SessionInit")
                }
            )
            await self.sendSessionResetInit(to: userId)
        }
    }

    /// Cancel the tie-break watchdog for `userId` once communication is confirmed.
    func cancelTieBreakWatchdog(for userId: String) {
        assertMainThread()
        tieBreakWatchdogs[userId]?.cancel()
        tieBreakWatchdogs.removeValue(forKey: userId)
    }

    // MARK: - Responder fallback

    /// Starts a fallback task: if the natural INITIATOR hasn't sent a new session init within
    /// `responderFallbackTimeout` seconds, we override the ordering and init ourselves.
    private func startResponderFallback(for userId: String) {
        assertMainThread()
        responderFallbackTasks[userId]?.cancel()
        responderFallbackTasks[userId] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.responderFallbackTimeout * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !CryptoManager.shared.hasSession(for: userId),
                      !self.isInitializing(userId) else {
                    Log.debug("RESPONDER fallback: session already established for \(userId.prefix(8))… — skipping", category: "SessionInit")
                    return
                }
                Log.info("RESPONDER fallback: no init from \(userId.prefix(8))… after \(Int(self.responderFallbackTimeout))s — taking INITIATOR role", category: "SessionInit")
                let endInit = self.beginInit(userId)
                Task { [weak self] in
                    guard let self else { return }
                    defer { Task { @MainActor in endInit() } }
                    await self.sessionInitService.initializeSessionProactively(
                        userId: userId,
                        onSuccess: { Log.info("RESPONDER fallback \(userId.prefix(8))…", category: "SessionInit") },
                        onFailure: { err in Log.error("RESPONDER fallback \(userId.prefix(8))…: \(err.localizedDescription)", category: "SessionInit") }
                    )
                }
            }
        }
    }

    /// Cancels any pending RESPONDER fallback task for `userId`.
    private func cancelResponderFallback(for userId: String) {
        assertMainThread()
        responderFallbackTasks[userId]?.cancel()
        responderFallbackTasks.removeValue(forKey: userId)
    }

    // MARK: - Message persistence (session-init path only)

    private func saveMessage(for chat: Chat, with messageData: ChatMessage, decryptedBytes: Data) {
        guard let context = viewContext else { return }

        // Decode raw bytes through the same binary pipeline as normal messages.
        // Handles KNST-framed protobuf (real user messages as X3DH init carrier),
        // raw protobuf (single-message delivery), and UTF-8 control strings (pings).
        let plaintext: String
        switch initMessageReassembler.process(data: decryptedBytes) {
        case .assembled(let text, _):
            plaintext = text
        case .legacy(let text):
            plaintext = text
        case .incomplete:
            Log.debug("Session-init message is a partial chunk — will be reassembled later", category: "SessionCoordinator")
            return
        case .invalid(let reason):
            Log.error("Session-init message envelope invalid: \(reason) — dropping", category: "SessionCoordinator")
            return
        }

        // Silently discard SESSION_RESET_INIT control payloads — they are sent as the X3DH
        // carrier for an atomic session reset and must never appear as chat bubbles.
        // iOS format: "__session_reset_init_<UUID>__"; other clients may omit the markers.
        if plaintext.hasPrefix("__session_reset_init") || plaintext.hasPrefix("session_reset_init_") {
            Log.info("SESSION_RESET_INIT payload discarded (not user-visible)", category: "SessionCoordinator")
            cancelTieBreakWatchdog(for: messageData.from)
            cancelResponderFallback(for: messageData.from)
            return
        }

        // Silently discard session establishment pings — they are sent after a tie-break win
        // purely to trigger RESPONDER session init on the peer and must not appear in chat.
        // Format: "__session_ping_<UUID>__" (legacy: "__session_ping__").
        if plaintext.hasPrefix("__session_ping") && plaintext.hasSuffix("__") {
            Log.info("SESSION_STATE[ping_received]: session established as RESPONDER (ping discarded)", category: "SessionCoordinator")
            cancelTieBreakWatchdog(for: messageData.from)
            cancelResponderFallback(for: messageData.from)
            return
        }

        // Phase 2 of two-phase handshake: RESPONDER sends __session_ready__ after its
        // initReceivingSession succeeds. We are the INITIATOR receiving confirmation.
        // Also handle legacy format without __ markers (older client versions).
        if plaintext.hasPrefix("__session_ready") || plaintext.hasPrefix("session_ready_") {
            let peerId = messageData.from
            Log.info("SESSION_STATE[session_ready_received]: RESPONDER \(peerId.prefix(8))… confirmed — session established both sides", category: "SessionCoordinator")
            cancelTieBreakWatchdog(for: peerId)
            cancelResponderFallback(for: peerId)
            markActive(peerId)
            SessionConfirmationTracker.shared.markConfirmed(peerId)
            sendSessionQueuedMessages(for: peerId)
            return
        }

        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", messageData.id)

        if let existing = try? context.fetch(fetchRequest).first {
            if !existing.hasDecryptedContent {
                existing.applyStoredEncryption(plaintext: plaintext, contactId: messageData.from)
            }
            return
        }

        let message = Message(context: context)
        message.id = messageData.id
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.timestamp = Date(timeIntervalSince1970: TimeInterval(messageData.timestamp))
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        message.applyStoredEncryption(plaintext: plaintext, contactId: messageData.from)

        chat.lastMessageText = Chat.formatPreviewText(plaintext)
        chat.lastMessageTime = message.timestamp
    }

    // MARK: - Auto-resend After END_SESSION (sender-side recovery)

    /// If we receive END_SESSION from a peer, it usually means they couldn't decrypt something we sent
    /// (or their local session state was reset). In that case, resend recent unconfirmed messages
    /// under a fresh session to avoid silent message loss.
    private func resendUnconfirmedOutgoingMessagesIfNeeded(to userId: String) {
        assertMainThread()
        guard let context = viewContext else { return }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }

        let now = Date()
        if let last = resendAttemptedAt[userId], now.timeIntervalSince(last) < resendCooldown {
            Log.info("Auto-resend cooldown active for \(userId.prefix(8))..., skipping", category: "SessionInit")
            return
        }
        resendAttemptedAt[userId] = now

        let cutoff = now.addingTimeInterval(-resendWindow) as NSDate
        // Include .failed in addition to .sending/.sent: when the receiver sends a "failed" receipt
        // (decryption failure), the sender marks the message as .failed. Without this, those
        // messages would be silently excluded from auto-resend after the session heals.
        let statusPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.sending.rawValue),
            NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.sent.rawValue),
            NSPredicate(format: "deliveryStatusRaw == %d", DeliveryStatus.failed.rawValue)
        ])

        let fetch = Message.fetchRequest()
        fetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isSentByMe == YES"),
            NSPredicate(format: "fromUserId == %@", myId),
            NSPredicate(format: "toUserId == %@", userId),
            NSPredicate(format: "timestamp >= %@", cutoff),
            NSPredicate(format: "retryCount == 0"),
            statusPredicate
        ])
        fetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        fetch.fetchLimit = 20

        let candidates: [Message]
        do {
            candidates = try context.fetch(fetch)
        } catch {
            Log.error("END_SESSION recovery: failed to fetch resend candidates for \(userId.prefix(8))…: \(error)", category: "SessionInit")
            return
        }
        guard !candidates.isEmpty else {
            return
        }

        Log.info("END_SESSION recovery: attempting auto-resend of \(candidates.count) message(s) to \(userId.prefix(8))...", category: "SessionInit")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ensureSendingSession(for: userId)
            } catch {
                Log.error("Auto-resend: session init failed for \(userId.prefix(8))…: \(error.localizedDescription)", category: "SessionInit")
                return
            }

            for msg in candidates {
                let plaintext = msg.displayText
                guard !plaintext.isEmpty else { continue }

                msg.deliveryStatus = .sending
                msg.retryCount += 1
                context.saveAndLog()

                do {
                    let messageUUID = UUID(uuidString: msg.id) ?? UUID()
                    let plan = ChunkedMessageSender.shared.buildPlan(plaintext: Data(plaintext.utf8), messageId: messageUUID)
                    guard !plan.payloads.isEmpty else {
                        Log.error("Auto-resend: message too large to build chunk plan: \(msg.id.prefix(8))…", category: "SessionInit")
                        msg.deliveryStatus = .failed
                        context.saveAndLog()
                        continue
                    }

                    let responses = try await ChunkedMessageSender.shared.sendChunks(
                        plan: plan,
                        senderId: myId,
                        recipientId: userId,
                        conversationId: ConversationId.direct(myUserId: myId, theirUserId: userId),
                        timestamp: UInt64(msg.timestamp.timeIntervalSince1970)
                    )

                    let response = responses.first ?? SendMessageResponse(messageId: msg.id, status: "sent")
                    let newStatus: DeliveryStatus
                    switch response.status.lowercased() {
                    case "delivered": newStatus = .delivered
                    case "queued": newStatus = .queued
                    case "failed": newStatus = .failed
                    default: newStatus = .sent
                    }
                    msg.deliveryStatus = newStatus
                    context.saveAndLog()
                    Log.info("Auto-resend: message \(msg.id.prefix(8))… status=\(newStatus)", category: "SessionInit")
                } catch {
                    msg.deliveryStatus = .failed
                    context.saveAndLog()
                    Log.error("Auto-resend failed for \(msg.id.prefix(8))…: \(error.localizedDescription)", category: "SessionInit")
                }
            }
        }
    }

    private func ensureSendingSession(for userId: String) async throws {
        if CryptoManager.shared.hasSession(for: userId) {
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
                    onSuccess: { cont.resume(returning: ()) },
                    onFailure: { cont.resume(throwing: $0) }
                )
            }
        }
    }
}
