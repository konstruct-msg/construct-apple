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

    /// When we last *received* END_SESSION from a peer (any role). Used to suppress an
    /// immediate outbound END_SESSION if the first post-reset msg0 fails AEAD — that
    /// message is often a race/stale wire frame; the peer usually follows with
    /// SESSION_RESET_INIT or a fresh init. Blind END_SESSION here doubles the reset storm
    /// (seen in device logs: AEAD fail → session_init_failed → SRI → success).
    private var lastInboundEndSessionAt: [String: Date] = [:]
    /// The SESSION_RESET_INITs we have decided to apply, per peer, identified by their X3DH
    /// ephemeral public key. See `AppliedInitLedger` for why the identity is the key and not a
    /// timestamp, and why it is in memory only.
    private var appliedResetInits: [String: AppliedInitLedger] = [:]
    /// Grace after inbound END_SESSION during which initReceiving failure does not
    /// emit outbound END_SESSION (still ACKs + FailedInitMessageStore + OTPK top-up).
    private let postEndSessionInitFailGrace: TimeInterval = 20.0

    /// Tracks when we last attempted an automatic resend after receiving END_SESSION from a peer.
    /// Prevents resend loops when both sides reset simultaneously.
    private var resendAttemptedAt: [String: Date] = [:]
    private let resendCooldown: TimeInterval = 10.0
    private let resendWindow: TimeInterval = 5 * 60 // 5 minutes

    /// Pending INITIATOR re-inits scheduled by END_SESSION receipt, keyed by peer.
    /// A server backlog flush delivers several END_SESSIONs at once; each used to schedule its
    /// own wipe+init+SRI, and every re-init after the first destroyed the session the previous
    /// one had just created — so the peer AEAD-failed all but the last SRI and answered with
    /// fresh END_SESSIONs, sustaining the storm. One pending re-init per peer is enough.
    /// The `token` disambiguates removal when a cancelled task's cleanup races a newly
    /// scheduled one for the same peer.
    private var endSessionReinitTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Delay before an END_SESSION-triggered re-init runs. Long enough for the rest of the same
    /// stream flush — including the peer's own fresh X3DH init, which makes us RESPONDER — to be
    /// processed first, so the re-init can see the new session and stand down.
    private let endSessionReinitDebounceNanos: UInt64 = 1_500_000_000

    /// Peers with an INITIATOR re-init currently executing (any entry point). A second re-init
    /// starting while one is in flight deletes the session the first just created, invalidating
    /// its SESSION_RESET_INIT before the peer ever sees it — overlaps are dropped; the tie-break
    /// watchdog re-sends if the surviving SRI is lost.
    private var initiatorReinitInFlight: Set<String> = []

    /// Watchdog tasks started after a tie-break WIN.
    /// If the RESPONDER (loser) does not reply within the timeout, re-sends the session ping
    /// so they can become RESPONDER even after a brief network outage.
    private var tieBreakWatchdogs: [String: Task<Void, Never>] = [:]
    /// Interval between SESSION_RESET_INIT re-sends while awaiting the RESPONDER's ack. The watchdog
    /// re-arms at this cadence and gives up when the confirm window (`SessionConfirmationTracker`)
    /// lapses — see `SessionReducer.tieBreakWatchdogTick`. (Was a single-shot 30 s timeout.)
    private let tieBreakWatchdogRetryInterval: TimeInterval = 30.0

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
        // Mirror the establishment timestamp into the Keychain so the END_SESSION stale-check
        // survives restart (the in-memory phase map is empty after launch even though the Rust
        // core restored live sessions). `.active` persists the time; a teardown to `nil` clears
        // it; `.initializing` leaves any existing value untouched (a re-key over a live session
        // must not drop its establishment time — a terminal failure will clear it via `nil`).
        switch newPhase {
        case .active(let at):
            KeychainManager.shared.saveSessionEstablishedAt(at, for: userId)
        case .none:
            KeychainManager.shared.deleteSessionEstablishedAt(for: userId)
        case .initializing:
            break
        }
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
        // No in-memory phase (typical right after launch: the Rust core restored the session
        // from CFE but this map starts empty). Fall back to the persisted timestamp so the
        // END_SESSION stale-check can still filter a re-delivered old END_SESSION.
        return KeychainManager.shared.loadSessionEstablishedAt(for: userId)
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

    /// After CFE restore the Rust core has live sessions but `sessionPhases` / Keychain
    /// `establishedAt` may be empty (older builds never persisted them). Without a timestamp,
    /// re-delivered END_SESSION is never filtered as stale and tears down healthy sessions →
    /// SESSION_RESET_INIT / openStream storms. Hydrate once the core is ready.
    func hydrateEstablishedTimestampsForRestoredSessions() {
        assertMainThread()
        guard CryptoManager.shared.isCoreReady else { return }
        let ids = CryptoManager.shared.getAllSessionUserIds()
        guard !ids.isEmpty else { return }
        var hydrated = 0
        let now = UInt64(Date().timeIntervalSince1970)
        for userId in ids {
            if establishedAt(for: userId) != nil { continue }
            // Prefer an existing Keychain value; otherwise stamp "now" so historical
            // offline-queue END_SESSIONs (ts << now) are treated as stale.
            if let persisted = KeychainManager.shared.loadSessionEstablishedAt(for: userId) {
                sessionPhases[userId] = .active(establishedAt: persisted)
            } else {
                apply(.markActive(at: now), for: userId)
            }
            hydrated += 1
        }
        if hydrated > 0 {
            Log.info(
                "SESSION_STATE[hydrate_established]: stamped establishedAt for \(hydrated)/\(ids.count) restored session(s)",
                category: "SessionInit"
            )
        }
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
                do {
                    try sessionInitService.initializeSession(userId: userId, bundle: bundle, deleteExisting: true)
                } catch SessionError.peerSPKStale {
                    // Peer's SPK is stale; degrade rather than leave the re-key broken.
                    // The resulting session is flagged at-risk and healed if undecryptable.
                    try sessionInitService.initializeSession(userId: userId, bundle: bundle, deleteExisting: true, allowStale: true)
                }
                Log.info("SESSION_STATE[key_sync_success]: session re-keyed for \(userId.prefix(8))…", category: "SessionInit")
            } catch {
                Log.error("SESSION_STATE[key_sync_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            }
        }
    }

    /// Send END_SESSION to a peer and archive + clear the local session.
    ///
    /// Rate-limited recovery paths (`sendEndSessionRateLimited`, the otpk-unreproducible path)
    /// decide via `SessionReducer.shouldSendEndSession` *before* calling this; must-send paths
    /// (logout, manual reset, terminal init/heal failures) call it directly and always send.
    ///
    /// The local teardown is conditional on the session still being the one we condemned. The
    /// logout broadcast inherits that check; skipping a teardown there is harmless because
    /// `performLocalSignOut` wipes the keys immediately afterwards.
    func sendEndSession(
        to userId: String,
        reason: String = "manual_reset",
        resetReason: Shared_Proto_Messaging_V1_SessionResetReason = .unspecified
    ) async throws {
        Log.info("Sending END_SESSION to \(userId): \(reason)\(resetReason != .unspecified ? " [hint=\(resetReason)]" : "")", category: "ChatsViewModel")
        // Identify the session being condemned BEFORE the network round-trip. The teardown below
        // destroys whatever session exists when the RPC returns, and the peer can establish a new
        // one inside that window — see `SessionReducer.shouldTearDownAfterEndSession`.
        let condemnedEpoch = CryptoManager.shared.sessionEpoch(for: userId)
        do {
            let response = try await MessagingServiceClient.shared.sendEndSession(to: userId, reason: reason, resetReason: resetReason)
            Log.info("END_SESSION sent successfully: \(response.messageId)", category: "ChatsViewModel")
        } catch {
            Log.error("Failed to send END_SESSION: \(error)", category: "ChatsViewModel")
            throw error
        }
        let currentEpoch = CryptoManager.shared.sessionEpoch(for: userId)
        guard SessionReducer.shouldTearDownAfterEndSession(
            condemned: condemnedEpoch, current: currentEpoch
        ) else {
            Log.info(
                "SESSION_STATE[end_session_teardown_skipped]: session for \(userId.prefix(8))… changed during the END_SESSION flight (condemned=\(condemnedEpoch.logDescription) current=\(currentEpoch.logDescription)) — keeping it",
                category: "SessionInit"
            )
            return
        }
        CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
        CryptoManager.shared.clearArchivedSessions(for: userId)
        Log.info("END_SESSION complete: session archived and cleared", category: "ChatsViewModel")
    }

    /// Single rate-limited END_SESSION entry point for storm-prone recovery paths
    /// (DR-diverge). Suppresses repeats within `endSessionCooldown` per peer via the pure
    /// Single authority for the outbound END_SESSION per-peer cooldown: consults
    /// `SessionReducer.shouldSendEndSession` and, iff allowed, records the send time. Returns whether
    /// the caller may proceed. Both the general rate-limited path and the typed-OTPK reset path gate
    /// through this, so the cooldown read-and-record can't drift between the two sites.
    private func recordEndSessionSendIfAllowed(_ userId: String, now: Date = Date()) -> Bool {
        guard SessionReducer.shouldSendEndSession(
            lastSentAt: endSessionSentAt[userId], now: now, cooldown: endSessionCooldown
        ) else { return false }
        endSessionSentAt[userId] = now
        return true
    }

    /// `SessionReducer.shouldSendEndSession` decision, and records the attempt time.
    /// Returns `true` iff a send was attempted (records + proceeds even if the network send
    /// throws, matching the prior inline behaviour). Must-send paths — logout broadcast,
    /// manual reset, terminal init/heal failures — call `sendEndSession` directly and are
    /// intentionally not rate-limited.
    @discardableResult
    private func sendEndSessionRateLimited(to userId: String, reason: String) async -> Bool {
        guard recordEndSessionSendIfAllowed(userId) else {
            Log.info("END_SESSION cooldown active for \(userId.prefix(8))…, skipping (\(reason))", category: "SessionCoordinator")
            return false
        }
        Log.info("Sending END_SESSION to \(userId.prefix(8))… (\(reason))", category: "SessionCoordinator")
        do {
            try await sendEndSession(to: userId, reason: reason)
        } catch {
            Log.error("Failed to send END_SESSION to \(userId.prefix(8))…: \(error)", category: "SessionCoordinator")
        }
        return true
    }

    /// Broadcast END_SESSION to all peers that have an active session (e.g., on logout).
    /// Pre-warm sessions for contacts where we are the natural INITIATOR (higher userId — see
    /// `SessionReducer.tieBreakRole`, which matches the Rust core rule).
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

        // Ensure restored sessions can filter re-delivered END_SESSION (see hydrate docs).
        hydrateEstablishedTimestampsForRestoredSessions()

        let toPrewarm = contactIds.filter { peer in
            SessionReducer.shouldPrewarm(
                coreReady: coreReady,
                isNaturalInitiator: SessionReducer.isNaturalInitiator(myId: myId, peerId: peer),
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
                // Rate-limited: startup + reconnect can hit prewarm repeatedly for the
                // same peer and used to spray END_SESSION → peer reset storms.
                if !skipEndSessionNotification {
                    let sent = await self.sendEndSessionRateLimited(
                        to: contactId,
                        reason: "session_missing_restart"
                    )
                    if sent {
                        Log.info("Prewarm: notified \(contactId.prefix(8))… of missing session before fresh init", category: "SessionInit")
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
            if SessionReducer.isNaturalInitiator(myId: myId, peerId: userId) {
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
            Log.info("SESSION_STATE[end_session_stale_check]: \(userId.prefix(8))… ts=\(timestamp) established=nil hasLiveSession=\(hasLive) → not filtered\(hasLive ? " live session will be reset by a possibly-stale END_SESSION (no in-memory establishedAt)" : "")", category: "SessionInit")
        } else {
            Log.info("SESSION_STATE[end_session_stale_check]: \(userId.prefix(8))… ts=\(timestamp) established=\(established!) → \(stale ? "STALE (filtered)" : "fresh (acted on)")", category: "SessionInit")
        }
        return stale
    }

    func messageRouter(
        _ router: MessageRouter,
        isResetInitSuperseded userId: String,
        timestamp: UInt64,
        initEphemeral: Data
    ) -> Bool {
        let established = establishedAt(for: userId)
        var ledger = appliedResetInits[userId] ?? AppliedInitLedger()
        let alreadyApplied = ledger.contains(initEphemeral)
        let superseded = SessionReducer.isResetInitSuperseded(
            alreadyApplied: alreadyApplied,
            establishedAt: established,
            timestamp: timestamp,
            fudgeSeconds: Self.endSessionStaleFudge
        )
        // Recorded here, at the decision, and not where the re-init finishes — that lag is the
        // defect. This is the sole caller and it applies the init whenever the answer is `false`,
        // so "decided to apply" and "applied" are the same event from this method's side.
        if !superseded {
            ledger.record(initEphemeral)
            appliedResetInits[userId] = ledger
        } else if alreadyApplied {
            PerformanceMetrics.shared.record(.resetInitDuplicate, label: "redelivery")
        }
        // `established == nil` → apply (never strand a possibly-live re-init on a missing record).
        // A *newer* init (superseded == false) is applied even while a session is active: the peer
        // has ratcheted onto it and its next msgNum≥1 only decrypts against the new session.
        if established == nil {
            Log.info("SESSION_STATE[reset_init_supersede_check]: \(userId.prefix(8))… ts=\(timestamp) established=nil → apply (no establishment record)", category: "SessionInit")
        } else {
            Log.info("SESSION_STATE[reset_init_supersede_check]: \(userId.prefix(8))… ts=\(timestamp) established=\(established!) → \(superseded ? "SUPERSEDED (coalesced)" : "fresh (apply re-init)")", category: "SessionInit")
        }
        return superseded
    }

    func messageRouter(_ router: MessageRouter, receivedEndSession userId: String, timestamp: UInt64) {
        lastInboundEndSessionAt[userId] = Date()
        let myId = AuthSessionManager.shared.currentUserId ?? ""
        guard !myId.isEmpty else { return }

        switch SessionReducer.endSessionReceiptAction(
            isNaturalInitiator: SessionReducer.isNaturalInitiator(myId: myId, peerId: userId),
            hasPendingReinit: endSessionReinitTasks[userId] != nil
        ) {
        case .waitAsResponder:
            Log.info("END_SESSION from natural INITIATOR \(userId.prefix(8))… — waiting as RESPONDER", category: "SessionInit")
            startResponderFallback(for: userId)
            onEphemeralSubscriptionNeeded?(userId)
            return
        case .coalesce:
            resendUnconfirmedOutgoingMessagesIfNeeded(to: userId)
            Log.info("END_SESSION coalesced — INITIATOR re-init already pending for \(userId.prefix(8))…", category: "SessionInit")
            return
        case .scheduleReinit:
            resendUnconfirmedOutgoingMessagesIfNeeded(to: userId)
        }
        Log.info("END_SESSION received — re-init as natural INITIATOR for \(userId.prefix(8))…", category: "SessionInit")
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.endSessionReinitTasks[userId]?.token == token {
                    self.endSessionReinitTasks.removeValue(forKey: userId)
                }
            }
            do {
                try await Task.sleep(nanoseconds: self.endSessionReinitDebounceNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // A session that exists NOW was established AFTER this END_SESSION wiped the old
            // one (MessageRouter archives before delegating) — typically the peer's fresh init
            // from the same stream flush just made us RESPONDER. Re-initing over it would
            // destroy a working session and re-open the desync it just closed.
            guard SessionReducer.endSessionReinitStillNeeded(
                hasSession: CryptoManager.shared.hasSession(for: userId)
            ) else {
                Log.info("SESSION_STATE[reinit_skipped_fresh_session]: session with \(userId.prefix(8))… established after END_SESSION — keeping it", category: "SessionInit")
                return
            }
            self.reinitAndAnnounceAsInitiator(to: userId, reason: "end_session_received")
        }
        endSessionReinitTasks[userId] = (token, task)
    }

    /// Cancel a pending END_SESSION-triggered INITIATOR re-init. Called whenever a session gets
    /// established or confirmed for the peer, so the delayed re-init cannot destroy it.
    private func cancelPendingEndSessionReinit(for userId: String, reason: String) {
        assertMainThread()
        guard let pending = endSessionReinitTasks.removeValue(forKey: userId) else { return }
        pending.task.cancel()
        Log.info("SESSION_STATE[reinit_cancelled]: pending INITIATOR re-init for \(userId.prefix(8))… cancelled (\(reason))", category: "SessionInit")
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
    /// holds the loser's inits until the window lapses (`confirm_hold`; before 2026-08-04 it
    /// discarded them, which is how a genuinely live re-init could be lost). Transmitting the SRI here
    /// lets the RESPONDER bootstrap and reply `session_ready`, which clears `pending` and
    /// flushes the buffer via the existing markConfirmed → sendQueuedMessages path.
    private func reinitAndAnnounceAsInitiator(to userId: String, reason: String) {
        assertMainThread()
        guard !initiatorReinitInFlight.contains(userId) else {
            Log.info("SESSION_STATE[initiator_announce_coalesced]: re-init already in flight for \(userId.prefix(8))… (\(reason))", category: "SessionInit")
            return
        }
        initiatorReinitInFlight.insert(userId)
        Log.info("SESSION_STATE[initiator_announce]: re-init + SESSION_RESET_INIT for \(userId.prefix(8))… (\(reason))", category: "SessionInit")
        // Mark pending synchronously at announce time, before any await:
        //  1. It gates `sendSessionInitPing`. With proactive-init coalescing the SRI and the ping
        //     share one session, so only one can be msgNum=0 — the SRI must win, it is the X3DH
        //     carrier the RESPONDER bootstraps from. Setting the flag inside the Task would leave
        //     the two coalesced continuations racing for it.
        //  2. A peer replying `session_ready` faster than the old post-emit call hit
        //     `markConfirmed`'s `guard removeValue != nil` and was swallowed, leaving the gate up
        //     until the watchdog TTL.
        SessionConfirmationTracker.shared.markPending(userId)
        Task { [weak self] in
            guard let self else { return }
            defer { self.initiatorReinitInFlight.remove(userId) }
            await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                onSuccess: { },
                onFailure: { err in
                    Log.error("SESSION_STATE[initiator_announce_fail]: \(err.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            )
            await self.emitHandshakeControls(.tieBreakWin, to: userId)
        }
        startTieBreakWatchdog(for: userId)
    }

    /// Re-establish a session for a peer that has QUEUED OUTBOUND messages but no live session
    /// (the "zombie session"): we are the natural RESPONDER for a purely-outbound peer, so
    /// `prewarmSessions` (INITIATOR-only) never fires and no inbound traffic ever triggers a
    /// RESPONDER init — the queued flush in `MessageRetryManager.sendQueuedMessages` would defer
    /// forever waiting for a session that nothing creates.
    ///
    /// Forces the INITIATOR role and transmits SESSION_RESET_INIT, exactly like a tie-break win,
    /// so the peer bootstraps its RESPONDER session and replies `session_ready`. That clears
    /// `SessionConfirmationTracker.pending` and flushes the queue via `sendSessionQueuedMessages`
    /// → `MessageRetryManager`, where the orphaned ciphertext (bound to the dead ratchet) has been
    /// purged and the recoverable plaintext is re-encrypted under the fresh session.
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
        guard !CryptoManager.shared.hasSession(for: userId) else { return }
        guard !isInitializing(userId) else {
            Log.debug("reestablishSessionForQueuedOutbound: init already in progress for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        Log.info("SESSION_STATE[zombie_recover]: no session for purely-outbound peer \(userId.prefix(8))… with queued messages — forcing INITIATOR re-establish", category: "SessionInit")
        // Same reasoning as `reinitAndAnnounceAsInitiator`: mark pending synchronously, before
        // any await, so the SRI (not a coalesced init ping) owns msgNum=0 and a fast peer's
        // `session_ready` cannot arrive before the gate exists.
        SessionConfirmationTracker.shared.markPending(userId)
        let endInit = beginInit(userId)
        Task { [weak self] in
            guard let self else { endInit(); return }
            defer { endInit() }
            await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                onSuccess: { },
                onFailure: { err in
                    Log.error("SESSION_STATE[zombie_recover_fail]: \(err.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            )
            await self.emitHandshakeControls(.tieBreakWin, to: userId)
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
                lastInboundEndSessionAt.removeValue(forKey: userId)
                // And stand down any END_SESSION-scheduled INITIATOR re-init: it would delete
                // the RESPONDER session we just established.
                cancelPendingEndSessionReinit(for: userId, reason: "responder_init_success")

                // Receipt only after we successfully decrypted + persisted the first message —
                // it is in the transcript, so the sender's checkmark is now true.
                if let context = viewContext {
                    OutboundSessionService.sendDeliveryReceipt(for: [message.id], to: userId, in: context)
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
                    await self.emitHandshakeControls(.becameResponder, to: userId)
                }
            } else if !CryptoManager.shared.isInitialized {
                // initReceivingSession failed because the crypto core isn't initialized
                // (device woken by push while locked → key material unreadable). This is
                // transient, NOT a broken session: do NOT ACK and do NOT send END_SESSION.
                // Leave the message queued; it is retried once the device unlocks and the
                // core is restored. Tearing the session down here is the locked-launch
                // desync bug (see also the entry guard in MessageRouter.routeIncomingMessage).
                Log.info("initReceivingSession deferred — core not initialized (device likely locked) for \(userId.prefix(8))… (no END_SESSION)", category: "SessionInit")
            } else {
                // initReceivingSession failed — prekey exhausted, AEAD mismatch, or race after
                // peer END_SESSION (stale msg0 on the wire).
                Log.info("initReceivingSession failed — clearing queue for \(userId.prefix(8))…", category: "SessionInit")
                // No receipt: this message was never decrypted, so telling the sender
                // "delivered" would put a checkmark on something they never received.
                //
                // The old comment here claimed the receipt advanced the server's delivery
                // cursor. It does not — the server trims strictly from `Subscribe.since_cursor`
                // (`messaging-service/src/stream.rs`), which the client drives through
                // `StreamCursorTracker`. The give-up below releases the watermark via
                // `.clearQueuedMessages` → `removePendingMessages`, so redelivery stops
                // without any receipt at all.
                PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "init_fail")
                // Track as permanently failed so the orphaned-init exception in MessageRouter
                // does not re-process this message ID on subsequent reconnects.
                FailedInitMessageStore.shared.add(message.id)
                // Mark as permanently processed in ACK store (belt-and-suspenders).
                if let context = viewContext {
                    PersistentACKStore.shared.markProcessed(message.id, senderId: userId, in: context)
                }
                // init failed → reset phase to absent + clear the pending queue, via the reducer.
                perform(apply(.initFailed, for: userId), for: userId)

                let withinPostEndSessionGrace: Bool = {
                    guard let t = lastInboundEndSessionAt[userId] else { return false }
                    return Date().timeIntervalSince(t) < postEndSessionInitFailGrace
                }()

                // If the init failed because we couldn't reproduce the sender's OTPK, ask them
                // (via the typed END_SESSION reason) to re-init WITHOUT one — 3-DH is always
                // reproducible, so this breaks the 4-DH retry loop instead of perpetuating it.
                let otpkUnreproducible = SessionReinitHintStore.shared.consumeResponderOtpkUnreproducible(for: userId)
                Task { [weak self] in
                    guard let self else { return }
                    await self.replenishOtpksAfterFailure(reason: "init_failed")

                    // Single branch authority — grace/otpk/plain now decided by the reducer.
                    // Cooldown (per-peer storm rate limit) is still applied at each send site.
                    switch SessionReducer.initFailureAction(
                        otpkUnreproducible: otpkUnreproducible,
                        withinInboundGrace: withinPostEndSessionGrace
                    ) {
                    case .suppressWithinGrace:
                        Log.info(
                            "SESSION_STATE[init_fail_grace]: suppressed END_SESSION for \(userId.prefix(8))… (within \(Int(self.postEndSessionInitFailGrace))s of inbound END_SESSION)",
                            category: "SessionInit"
                        )

                    case .sendTypedOtpk:
                        // Must carry the typed reason; still respect per-peer cooldown.
                        if self.recordEndSessionSendIfAllowed(userId) {
                            do {
                                try await self.sendEndSession(
                                    to: userId,
                                    reason: "session_init_failed_otpk_unreproducible",
                                    resetReason: .otpkUnreproducible
                                )
                            } catch {
                                Log.error("SESSION_STATE[init_failed_end_session]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                            }
                        } else {
                            Log.info("END_SESSION cooldown active for \(userId.prefix(8))…, skipping (session_init_failed_otpk_unreproducible)", category: "SessionCoordinator")
                        }

                    case .sendPlain:
                        _ = await self.sendEndSessionRateLimited(to: userId, reason: "session_init_failed")
                    }
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

                // The previously-failed X3DH init message is now decrypted and saved — the
                // sender's checkmark is true, so send the receipt.
                OutboundSessionService.sendDeliveryReceipt(for: [failedMessage.id], to: userId, in: context)
                PersistentACKStore.shared.markProcessed(failedMessage.id, senderId: userId, in: context)

                // Heal does not reset establishment time (no markActive) — drain only.
                perform([.drainQueuedMessages], for: userId, skippingFirst: true)
            } else {
                Log.error("SESSION_STATE[heal_failed]: initReceivingSession still failing for \(userId.prefix(8))…", category: "SessionInit")
                if !canContinue {
                    Log.info("Heal exhausted — sending END_SESSION to \(userId.prefix(8))…", category: "SessionInit")
                    // No receipt — same reasoning as the initReceivingSession failure path:
                    // nothing was decrypted, and the cursor is advanced by StreamCursorTracker,
                    // never by a receipt.
                    PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "heal_exhausted")
                    // Permanently block re-processing of this message ID.
                    FailedInitMessageStore.shared.add(failedMessage.id)
                    PersistentACKStore.shared.markProcessed(failedMessage.id, senderId: userId, in: context)
                    perform([.clearQueuedMessages], for: userId)
                    SessionHealingService.shared.clearQueue(for: userId, in: context)
                    let otpkUnreproducible = SessionReinitHintStore.shared.consumeResponderOtpkUnreproducible(for: userId)
                    do {
                        try await sendEndSession(
                            to: userId,
                            reason: otpkUnreproducible ? "heal_exhausted_otpk_unreproducible" : "heal_exhausted",
                            resetReason: otpkUnreproducible ? .otpkUnreproducible : .unspecified
                        )
                    } catch {
                        Log.error("SESSION_STATE[heal_exhausted_end_session]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                    }
                    await replenishOtpksAfterFailure(reason: "heal_exhausted")
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
        // The init carrier (first queued message) was already decrypted during session init and
        // is not re-routed below — resolve it explicitly so its deferred entry releases the
        // stream-cursor watermark. Re-routed messages resolve themselves via routeIncomingMessage.
        if skippingFirst, let first = queued.first {
            StreamCursorTracker.shared.resolve(messageId: first.id)
        }
        let toProcess = skippingFirst ? queued.dropFirst() : queued[...]
        guard !toProcess.isEmpty, let context = viewContext else { return }
        Log.info("Decrypting \(toProcess.count) queued message(s) for \(userId.prefix(8))...", category: "SessionInit")
        for queuedMsg in toProcess {
            messageRouter.routeIncomingMessage(queuedMsg, in: context)
        }
    }

    /// Drop the tie-break confirm gate for `userId` and flush **both** directions it was holding.
    ///
    /// One call because the two flushes must not drift apart. For as long as the gate existed only
    /// the outgoing side was flushed at these sites, which is precisely why the incoming side had
    /// to be a discard rather than a hold — there was nowhere for a held message to be released.
    /// A future fourth release site gets both by construction.
    private func releaseConfirmGate(for userId: String, lapsed: Bool = false) {
        assertMainThread()
        if lapsed {
            SessionConfirmationTracker.shared.releaseLapsed(userId)
        } else {
            SessionConfirmationTracker.shared.markConfirmed(userId)
        }
        sendSessionQueuedMessages(for: userId)
        if let context = viewContext {
            messageRouter.replayHeldMessages(for: userId, in: context)
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

    /// Replenish OTPKs after session-init or heal failure — append-only, guarded by
    /// low-water + cooldown inside the service. Force-replacing here (the old behavior)
    /// wiped keys that peers' in-flight inits still referenced, making the desync
    /// self-sustaining; see `OtpkReplenishmentService.replenishAfterInitFailure`.
    private func replenishOtpksAfterFailure(reason: String) async {
        let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
        guard !deviceId.isEmpty else { return }
        await OtpkReplenishmentService.replenishAfterInitFailure(deviceId: deviceId, reason: reason)
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

    /// Emit the control message(s) the reducer prescribes for a handshake transition — the single
    /// send-side authority (`SessionReducer.controlsToEmit`). Tie-break win → SESSION_RESET_INIT;
    /// RESPONDER established → session_ready.
    private func emitHandshakeControls(_ transition: SessionReducer.HandshakeTransition, to userId: String) async {
        for op in SessionReducer.controlsToEmit(on: transition) {
            switch op {
            case .resetInit: await sendSessionResetInit(to: userId)
            case .ready:     await sendSessionReady(to: userId)
            case .ping:      await sendSessionPing(to: userId)
            case .endSession, .other: break
            }
        }
    }

    /// One handshake-control emitter (replaces the three near-identical
    /// sendSessionResetInit/Ping/Ready bodies). Encodes the op payload once — the typed
    /// `content_type` for new consumers, with the magic-string payload from `encodePayload` as the
    /// dual-send fallback for peers predating typed dispatch — and sends with bounded retries +
    /// exponential back-off. `onExhaustion` runs after the final failed attempt (SRI's two-step
    /// fallback); `logTag` keeps the existing per-op log breadcrumbs.
    private func sendSessionControlCore(
        codecOp: SessionControlCodec.Op,
        contentType: Shared_Proto_Core_V1_ContentType,
        to userId: String,
        maxAttempts: Int,
        logTag: String,
        onExhaustion: (() async -> Void)? = nil
    ) async {
        guard CryptoManager.shared.hasSession(for: userId) else {
            Log.info("SESSION_STATE[\(logTag)_skip]: no session for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }

        // ping (25) / ready (26) hide their type in KNST byte 5, inside the ciphertext, and tell
        // the server nothing. SESSION_RESET_INIT (24) cannot: it is wire-identical to an ordinary
        // X3DH carrier, so the receiver must know before it decrypts. That is the only handshake
        // type left on `SealedInner`.
        let frameType = SessionControlCodec.frameContentType(for: codecOp)
        let wireContentType: Shared_Proto_Core_V1_ContentType = frameType == nil ? contentType : .unspecified

        // The session this send speaks for, pinned before the first attempt. A retry crosses the
        // network, and a session can be replaced underneath it: on 2026-08-04 attempts 1 and 2
        // failed on `StealthDowngradeBlocked`, the peer's own SESSION_RESET_INIT landed in the gap
        // and made us the RESPONDER on a new session, and attempt 3 then announced a session that
        // had not existed for a second. The peer read it as "reset" and tore down a healthy ratchet
        // — the first domino of a cascade that ended in a lost user message.
        //
        // Same defect and same remedy as `SessionReducer.shouldTearDownAfterEndSession`: identify
        // the session the decision was made about, rather than asserting that *a* session exists.
        // The `hasSession` guard above cannot see this — it was true throughout.
        let announcedEpoch = CryptoManager.shared.sessionEpoch(for: userId)

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                let stillLive = CryptoManager.shared.hasSession(for: userId)
                guard SessionReducer.shouldContinueControlRetry(
                    announced: announcedEpoch,
                    current: CryptoManager.shared.sessionEpoch(for: userId),
                    hasSession: stillLive
                ) else {
                    let why = stillLive ? "replaced" : "gone"
                    Log.info("SESSION_STATE[\(logTag)_superseded]: session for \(userId.prefix(8))… is \(why) between attempts — abandoning at \(attempt)/\(maxAttempts) rather than announcing a session that no longer exists", category: "SessionInit")
                    PerformanceMetrics.shared.record(.controlRetrySuperseded, label: "\(logTag):\(why)")
                    return
                }
            }
            do {
                let nonce = UUID().uuidString
                let msgId = UUID().uuidString.lowercased()
                let convId = ConversationId.direct(myUserId: myId, theirUserId: userId)
                let ts = UInt64(Date().timeIntervalSince1970)
                let encryptedPayload = try OutboundSessionService.shared.encryptSessionControl(
                    payload: SessionControlCodec.encodePayload(op: codecOp, nonce: nonce),
                    messageId: msgId,
                    recipientId: userId,
                    frameAs: frameType
                )

                // Stealth: seal the control envelope exactly like a message body.
                // Fail-closed: under stealth-on we NEVER emit an identified control send — that
                // is the server-observable session-graph leak the sealed path exists to close
                // (decisions/sealed-sender-session-control-channel.md). A blocked send just
                // fails this attempt; the tie-break watchdog re-drives the handshake.
                if StealthPolicy.shared.shouldUseSealedSender() {
                    let ctx = viewContext ?? PersistenceController.shared.container.viewContext
                    guard let recipientIK = StealthSenderService.recipientIdentityKey(recipientId: userId, context: ctx) else {
                        throw StealthDowngradeBlocked(reason: "no recipient identity key for \(logTag) → \(userId.prefix(8))…")
                    }
                    let sealedInner = try await StealthSenderService.buildSealedInner(
                        recipientUserId: userId,
                        recipientIdentityKey: recipientIK,
                        encryptedPayload: encryptedPayload,
                        contentType: wireContentType
                    )
                    _ = try await StealthSendRecovery.sendSealed(sealedInner, rebuild: {
                        try await StealthSenderService.buildSealedInner(
                            recipientUserId: userId,
                            recipientIdentityKey: recipientIK,
                            encryptedPayload: encryptedPayload,
                            contentType: wireContentType
                        )
                    }, send: { inner in
                        try await MessagingServiceClient.shared.sendMessage(
                            messageId: msgId,
                            recipientId: userId,
                            senderId: myId,
                            conversationId: convId,
                            encryptedPayload: encryptedPayload,
                            timestamp: ts,
                            sealedInnerBytes: inner
                        )
                    })
                } else {
                    let _ = try await MessagingServiceClient.shared.sendMessage(
                        messageId: msgId,
                        recipientId: userId,
                        senderId: myId,
                        conversationId: convId,
                        encryptedPayload: encryptedPayload,
                        timestamp: ts,
                        contentType: wireContentType
                    )
                }
                Log.info("SESSION_STATE[\(logTag)_sent]: to \(userId.prefix(8))… (attempt \(attempt))", category: "SessionInit")
                return
            } catch {
                Log.error("SESSION_STATE[\(logTag)_fail]: attempt \(attempt)/\(maxAttempts): \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                if attempt < maxAttempts {
                    do {
                        try await Task.sleep(nanoseconds: pingRetryBaseDelay * UInt64(attempt))
                    } catch {
                        return
                    }
                } else {
                    await onExhaustion?()
                }
            }
        }
    }

    /// Send SESSION_RESET_INIT — atomic replacement for `sendEndSession` + `sendSessionPing`.
    /// Encodes the X3DH init payload (`msgNum=0`) as `.sessionResetInit` (always typed — no peer
    /// predates this atomic form). Falls back to the legacy two-step (END_SESSION → ping) if all
    /// attempts fail (backward compat).
    private func sendSessionResetInit(to userId: String) async {
        await sendSessionControlCore(
            codecOp: .resetInit, contentType: .sessionResetInit, to: userId,
            maxAttempts: pingMaxAttempts, logTag: "sri"
        ) { [weak self] in
            guard let self else { return }
            Log.info("SESSION_STATE[sri_fallback]: SESSION_RESET_INIT exhausted, falling back to two-step for \(userId.prefix(8))…", category: "SessionInit")
            do {
                _ = try await MessagingServiceClient.shared.sendEndSession(to: userId, reason: "sri_fallback")
            } catch {
                Log.error("SESSION_STATE[sri_fallback_end_session_failed]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
            }
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            await self.sendSessionPing(to: userId)
        }
    }

    /// Legacy tie-break ping (superseded by SESSION_RESET_INIT; survives only in the SRI fallback).
    /// Dual-send: typed `.sessionPing` for new consumers, `.e2EeSignal` + magic string otherwise.
    private func sendSessionPing(to userId: String) async {
        await sendSessionControlCore(
            codecOp: .ping,
            contentType: .unspecified,  // the ping's type is in the frame; the wire says nothing
            to: userId, maxAttempts: pingMaxAttempts, logTag: "tie_break_ping"
        )
    }

    /// RESPONDER → INITIATOR ack after a successful `initReceivingSession` (phase 2 of the two-phase
    /// handshake): lets the INITIATOR cancel its watchdog and flush. Single attempt (no retry).
    /// Dual-send: typed `.sessionReady` for new consumers, `.e2EeSignal` + magic string otherwise.
    private func sendSessionReady(to userId: String) async {
        await sendSessionControlCore(
            codecOp: .ready,
            contentType: .unspecified,  // the ready's type is in the frame; the wire says nothing
            to: userId, maxAttempts: 1, logTag: "session_ready"
        )
    }

    // MARK: - Tie-break watchdog

    /// Start a **re-arming, bounded** watchdog that re-sends SESSION_RESET_INIT every
    /// `tieBreakWatchdogRetryInterval` while the RESPONDER hasn't acked — but only within the confirm
    /// window (`SessionReducer.tieBreakWatchdogTick`). When the window lapses it gives up cleanly:
    /// releases the confirm gate and proactively flushes the buffer, so a persistently lost SRI/ping
    /// can no longer deadlock (the single-shot version fired once then went silent forever, leaving
    /// `pending` set — the confirm-deadlock root). Cancelled on any RESPONDER ack (ready/ping/SRI).
    private func startTieBreakWatchdog(for userId: String) {
        assertMainThread()
        tieBreakWatchdogs[userId]?.cancel()
        tieBreakWatchdogs[userId] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.tieBreakWatchdogRetryInterval * 1_000_000_000))
                } catch {
                    return // cancelled — RESPONDER acked in time
                }
                guard !Task.isCancelled else { return }
                switch SessionConfirmationTracker.shared.watchdogTick(userId) {
                case .retry:
                    // RESPONDER still silent — re-send a fresh X3DH init (msgNum=0) it can accept.
                    Log.info("SESSION_STATE[tie_break_watchdog]: no ack — re-sending SESSION_RESET_INIT for \(userId.prefix(8))…", category: "SessionInit")
                    await self.sessionInitService.initializeSessionProactively(
                        userId: userId,
                        onSuccess: { },
                        onFailure: { err in
                            Log.error("SESSION_STATE[watchdog_reinit_fail]: \(err.localizedDescription)", category: "SessionInit")
                        }
                    )
                    await self.sendSessionResetInit(to: userId)
                case .giveUp:
                    // Confirm window exhausted — stop retrying, release the gate, drain the buffer
                    // (rather than waiting for the lazy TTL / next reconnect). New sends flow; if the
                    // session is genuinely broken the peer's decrypt-fail drives normal recovery.
                    Log.info("SESSION_STATE[tie_break_watchdog]: confirm window exhausted for \(userId.prefix(8))… — releasing gate + flushing buffers", category: "SessionInit")
                    // Give-up path for the incoming hold too: replay it and let the ordinary
                    // decrypt/heal decision run now that the gate no longer suppresses it.
                    self.releaseConfirmGate(for: userId, lapsed: true)
                    self.tieBreakWatchdogs.removeValue(forKey: userId)
                    return
                }
            }
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
                // Override gate — the mirror of the watchdog, via the reducer authority.
                guard SessionReducer.shouldResponderOverride(
                    hasSession: CryptoManager.shared.hasSession(for: userId),
                    isInitializing: self.isInitializing(userId)
                ) else {
                    Log.debug("RESPONDER fallback: session already established / initializing for \(userId.prefix(8))… — skipping", category: "SessionInit")
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
        let e2eMessageId: String?
        switch initMessageReassembler.process(data: decryptedBytes, envelopeId: messageData.id) {
        case .assembled(let text, _, let e2eId, _, _):
            plaintext = text
            e2eMessageId = e2eId
        case .legacy(let text):
            plaintext = text
            e2eMessageId = nil
        case .profile(let profileData):
            // A profile share arrived as the session's first message — render it as a profile,
            // never persist a placeholder string.
            if let profile = ProfileShareData.fromBinaryData(profileData) {
                ProfileSharingManager.shared.handleProfileMessage(profile, from: messageData.from, in: context)
            }
            return
        case .edit:
            plaintext = ""
            e2eMessageId = nil
        case .incomplete:
            Log.debug("Session-init message is a partial chunk — will be reassembled later", category: "SessionCoordinator")
            return
        case .invalid(let reason):
            Log.error("Session-init message envelope invalid: \(reason) — dropping", category: "SessionCoordinator")
            return
        }

        // Side-channel frames (call signal 12, delivery receipt 14) go through the router's
        // dispatcher — the same one the ordinary path uses. This site had no equivalent at all: it
        // knew about session-control ops only, so a receipt arriving as the first message of a
        // fresh session was persisted as a chat row. On 2026-08-04 that produced a bubble
        // containing the message id the receipt referenced.
        //
        // Since `cf157f64` the envelope carries `.unspecified` for these — the type rides in frame
        // byte 5, inside the ciphertext, so the server learns nothing. A site that asks only the
        // envelope now hears "ordinary message" about every one of them.
        if messageRouter.handleFramedSideChannel(
            decryptedBytes,
            messageId: messageData.id,
            from: messageData.from,
            resolvedSender: messageData.from,
            in: context
        ) {
            return
        }

        // Session-handshake ops additionally drive this coordinator's own watchdogs and queues,
        // so they are re-read here after the router has had its turn. Frame first, envelope second,
        // for the reason above.
        let frameOp = ChunkedMessageCodec.controlFrame(decryptedBytes)
            .flatMap { SessionControlCodec.op(forContentType: Int($0.contentType)) }
        if let op = frameOp ?? SessionControlCodec.op(forContentType: Int(messageData.contentType)) {
            let peerId = messageData.from
            switch op {
            case .resetInit:
                Log.info("SESSION_RESET_INIT payload discarded (not user-visible, content_type=24)", category: "SessionCoordinator")
                cancelTieBreakWatchdog(for: peerId)
                cancelResponderFallback(for: peerId)
                cancelPendingEndSessionReinit(for: peerId, reason: "sri_received")
                return
            case .ping:
                Log.info("SESSION_STATE[ping_received]: session established as RESPONDER (ping discarded, content_type=25)", category: "SessionCoordinator")
                cancelTieBreakWatchdog(for: peerId)
                cancelResponderFallback(for: peerId)
                cancelPendingEndSessionReinit(for: peerId, reason: "ping_received")
                // A RESPONDER session now exists. If we were also waiting on our own
                // INITIATOR session_ready, that confirmation will never arrive (the peer is the
                // INITIATOR here) — release the stale pending flag and flush both buffers
                // so sends stop deadlocking on a session_ready that won't come.
                releaseConfirmGate(for: peerId)
                return
            case .ready:
                Log.info("SESSION_STATE[session_ready_received]: RESPONDER \(peerId.prefix(8))… confirmed (content_type=26)", category: "SessionCoordinator")
                cancelTieBreakWatchdog(for: peerId)
                cancelResponderFallback(for: peerId)
                cancelPendingEndSessionReinit(for: peerId, reason: "session_ready")
                markActive(peerId)
                releaseConfirmGate(for: peerId)
                return
            case .end, .unspecified, .UNRECOGNIZED:
                break  // fall through to normal handling
            }
        }

        // Silently discard SESSION_RESET_INIT control payloads — they are sent as the X3DH
        // carrier for an atomic session reset and must never appear as chat bubbles.
        // iOS format: "__session_reset_init_<UUID>__"; other clients may omit the markers.
        if plaintext.hasPrefix("__session_reset_init") || plaintext.hasPrefix("session_reset_init_") {
            Log.info("SESSION_RESET_INIT payload discarded (not user-visible)", category: "SessionCoordinator")
            cancelTieBreakWatchdog(for: messageData.from)
            cancelResponderFallback(for: messageData.from)
            cancelPendingEndSessionReinit(for: messageData.from, reason: "sri_received_legacy")
            return
        }

        // Silently discard session establishment pings — they are sent after a tie-break win
        // purely to trigger RESPONDER session init on the peer and must not appear in chat.
        // Format: "__session_ping_<UUID>__" (legacy: "__session_ping__").
        if plaintext.hasPrefix("__session_ping") && plaintext.hasSuffix("__") {
            Log.info("SESSION_STATE[ping_received]: session established as RESPONDER (ping discarded)", category: "SessionCoordinator")
            cancelTieBreakWatchdog(for: messageData.from)
            cancelResponderFallback(for: messageData.from)
            cancelPendingEndSessionReinit(for: messageData.from, reason: "ping_received_legacy")
            // See the typed-ping case above: a RESPONDER session exists, so release any stale
            // INITIATOR-pending buffer instead of waiting for a session_ready that won't arrive.
            releaseConfirmGate(for: messageData.from)
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
            cancelPendingEndSessionReinit(for: peerId, reason: "session_ready_legacy")
            markActive(peerId)
            SessionConfirmationTracker.shared.markConfirmed(peerId)
            sendSessionQueuedMessages(for: peerId)
            return
        }

        // Canonical row id: sender's E2E id from the KNST header when present (see
        // MessageRouter.saveMessage — the server reassigns envelope ids on the sealed path).
        let canonicalId = (e2eMessageId ?? messageData.id).lowercased()
        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id ==[c] %@", canonicalId)
        fetchRequest.fetchLimit = 1

        if let existing = try? context.fetch(fetchRequest).first {
            if existing.fromUserId == messageData.from, !existing.hasDecryptedContent {
                existing.applyStoredEncryption(plaintext: plaintext, contactId: messageData.from)
            }
            return
        }

        let message = Message(context: context)
        message.id = canonicalId
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.timestamp = Date.fromRemoteTimestamp(messageData.timestamp)
        message.isSentByMe = false
        message.deliveryStatus = .delivered
        message.retryCount = 0
        message.chat = chat

        message.applyStoredEncryption(plaintext: plaintext, contactId: messageData.from)

        chat.applyPreview(text: plaintext, timestamp: message.timestamp)
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

            // Resolve the recipient identity key once so resent bodies are SEALED — never downgraded
            // to identified on retry (the server-influence deanonymisation vector).
            let recipientIdentityKey = StealthSenderService.recipientIdentityKey(recipientId: userId, context: context)

            // E14: one save for all "sending" marks instead of save-per-message before network.
            var resendQueue: [(Message, String)] = []
            resendQueue.reserveCapacity(candidates.count)
            for msg in candidates {
                let plaintext = msg.displayText
                guard !plaintext.isEmpty else { continue }
                msg.deliveryStatus = .sending
                msg.retryCount += 1
                resendQueue.append((msg, plaintext))
            }
            if context.hasChanges {
                context.saveAndLog()
            }

            for (msg, plaintext) in resendQueue {
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
                        timestamp: UInt64(msg.timestamp.timeIntervalSince1970),
                        recipientIdentityKey: recipientIdentityKey
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
                } catch is StealthDowngradeBlocked {
                    // Stealth on but could not seal — keep queued, never send identified.
                    msg.deliveryStatus = .queued
                    context.saveAndLog()
                    Log.info("Auto-resend: sealed send blocked (cannot seal) for \(msg.id.prefix(8))… — queued, nudging fetch", category: "SessionInit")
                    SessionLifecycleController.shared.reestablishSessionForQueuedOutbound(to: userId)
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
