//
//  SessionCoordinator.swift
//  Construct Messenger
//
//  Owns the entire session lifecycle for all peers:
//  – Receiving open (a message carrying the handshake header, from its sender certificate)
//  – Sending END_SESSION (manual reset, logout, a message nothing held decrypts)
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

    /// Tracks when we last attempted an automatic resend after receiving END_SESSION from a peer.
    /// Prevents resend loops when both sides reset simultaneously.
    private var resendAttemptedAt: [String: Date] = [:]
    private let resendCooldown: TimeInterval = 10.0
    private let resendWindow: TimeInterval = 5 * 60 // 5 minutes

    /// Peers with an INITIATOR reopen currently executing (`OpenSession`).
    ///
    /// A second reopen starting while the first fetches its bundle spends another one-time prekey
    /// for a state that will not be used; overlaps are dropped.
    ///
    /// Account-keyed on purpose: the init runs for a whole account's device set.
    private var initiatorReinitInFlight: Set<String> = []


    /// Called when END_SESSION arrives from a userId that has no Core Data record yet
    /// (brand-new contact). ChatsViewModel subscribes to this callback and adds an ephemeral
    /// stream subscription so the INITIATOR's X3DH message can arrive via live stream.
    var onEphemeralSubscriptionNeeded: ((String) -> Void)?

    /// Timer that periodically evicts expired entries from cooldown dicts so they don't grow unboundedly.
    private var cooldownPurgeTimer: Timer?
    private let cooldownPurgeInterval: TimeInterval = 5 * 60 // every 5 minutes

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
        // Mirror the establishment timestamp into the Keychain so the END_SESSION stale-check
        // survives restart (the in-memory phase map is empty after launch even though the Rust
        // core restored live sessions). `.active` persists the time; a teardown to `nil` clears
        // it; `.initializing` leaves any existing value untouched (a re-key over a live session
        // must not drop its establishment time — a terminal failure will clear it via `nil`).
        switch newPhase {
        case .active(let at):
            SessionEstablishment.record(for: scope.storageKey, at: at)
        case .none:
            SessionEstablishment.clear(for: scope.storageKey)
        case .initializing:
            break
        }
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

    /// Return the timestamp (Unix seconds) when the active session for `scope` was established,
    /// or nil if there is no active session record.
    private func establishedAt(for scope: SessionScope) -> UInt64? {
        assertMainThread()
        if case .active(let t) = sessionPhases[scope] { return t }
        // No in-memory phase (typical right after launch: the Rust core restored the session
        // from CFE but this map starts empty). Fall back to the persisted timestamp so the
        // END_SESSION stale-check can still filter a re-delivered old END_SESSION.
        return SessionEstablishment.loadTimestamp(for: scope.storageKey)
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
        // Cooldown timer fires off the incoming-message path; reuse the same END_SESSION
        // consumer so an owed teardown actually leaves the device.
        //
        // The core names the device (`cooldown_expired:<deviceId>`) and there is no envelope here
        // to name the account, so this is the one caller that has to read the seam backwards.
        // Unresolvable means we hold no row attributing that device to any contact — the same
        // state as "no session with them", so there is nothing to tear down and nothing to log
        // beyond saying which device we could not place.
        OutboundSessionService.shared.onTimerSendEndSession = { [weak self] deviceId in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else {
                Log.info(
                    "Owed END_SESSION dropped: device \(deviceId.prefix(8))… belongs to no known contact",
                    category: "SessionCoordinator"
                )
                return
            }
            // Pre-approved, and it has to be: this fires *because* the machine granted the owed
            // teardown, and the grant opened a fresh window. Asking again would land inside that
            // window, defer the debt it came to pay, and arm another alarm — a teardown that
            // re-owes itself every window and never leaves the device.
            self.handleNeedsEndSession(peer, preapproved: true)
        }
        // The core's ask to open a new session over the one held (the PQXDH v2 upgrade sweep).
        // The core names a device and the bundle fetch addresses an account, so the seam is read
        // backwards, as for the teardown hook above.
        SessionActionExecutor.shared.onOpenSession = { [weak self] deviceId in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else {
                Log.info(
                    "Requested reopen dropped: device \(deviceId.prefix(8))… belongs to no known contact",
                    category: "SessionCoordinator"
                )
                return
            }
            Log.info("SESSION_STATE[reopen_requested]: opening a new session with \(peer)", category: "SessionInit")
            self.reopenAsInitiator(to: peer.account, reason: "open_session")
        }
        CryptoManager.shared.onPendingDropped = { [weak self] actions in
            self?.messageRouter.releaseDroppedQueues(actions)
        }
        startCooldownPurgeTimer()
    }

    /// After CFE restore the Rust core has live sessions but `sessionPhases` / Keychain
    /// `establishedAt` may be empty (older builds never persisted them). Without a timestamp,
    /// re-delivered END_SESSION is never filtered as stale and tears down healthy sessions.
    /// Hydrate once the core is ready.
    ///
    /// This walks the core's session list, which is **device** ids. Until 2026-09-05 it wrote them
    /// into an account-keyed map and an account-keyed Keychain namespace, so the entries it
    /// stamped were read by nobody: every lookup still answered `nil`, and
    /// `isEndSessionStale(nil, …)` is `false` — the teardown is honoured. The function written to
    /// stop redelivered END_SESSIONs from destroying restored sessions could not do it, and the
    /// log line said it had.
    func hydrateEstablishedTimestampsForRestoredSessions() {
        assertMainThread()
        guard CryptoManager.shared.isCoreReady else { return }
        let deviceIds = CryptoManager.shared.getAllSessionDeviceIds()
        guard !deviceIds.isEmpty else { return }
        var hydrated = 0
        var carried = 0
        let now = UInt64(Date().timeIntervalSince1970)
        let context = viewContext ?? PersistenceController.shared.container.viewContext
        for deviceId in deviceIds {
            let scope = SessionScope.device(deviceId)
            if establishedAt(for: scope) != nil { continue }
            // A record written by a build that keyed this by account. Carry it across rather than
            // stamping `now`: the real establishment time is what the stale-check compares the
            // peer's clock against, and `now` makes every genuine teardown sent before this launch
            // look stale. One-shot — the device-keyed write below is what later launches read.
            let inherited = PeerAddress.resolving(device: deviceId, in: context)
                .flatMap { SessionEstablishment.loadTimestamp(for: $0.account) }
            if inherited != nil { carried += 1 }
            // Prefer a real timestamp; otherwise stamp "now" so historical offline-queue
            // END_SESSIONs (ts << now) are treated as stale.
            apply(.markActive(at: inherited ?? now), for: scope)
            hydrated += 1
        }
        if hydrated > 0 {
            Log.info(
                "SESSION_STATE[hydrate_established]: stamped establishedAt for \(hydrated)/\(deviceIds.count) restored session(s), \(carried) carried from an account-keyed record",
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

    /// Send END_SESSION to a peer and archive + clear the local session.
    ///
    /// Gated recovery paths pass `rateLimited: true` and the window is asked for per device in
    /// the loop below — the core's window, via `recordEndSessionSendIfAllowed`. Must-send paths
    /// (logout, manual reset) call this directly and always send.
    ///
    /// The local teardown is conditional on the session still being the one we condemned. The
    /// logout broadcast inherits that check; skipping a teardown there is harmless because
    /// `performLocalSignOut` wipes the keys immediately afterwards.
    /// `peerId` may name an account or a single device; either way the teardown is addressed to
    /// **devices**, one signal each.
    ///
    /// It used to be one send with `recipient_device` unset, which the server writes to every queue
    /// of the account — so a divergence with one device tore down its siblings' healthy sessions —
    /// and, when the caller happened to hold a device id, put 32 hex characters into a field that
    /// parses a UUID and delivered nowhere at all. See `orchestration::teardown_plan` in the core.
    ///
    /// A failure is per device: one unreachable device must not leave the others on a session we
    /// have already stopped being able to read. The error is rethrown only when **no** device could
    /// be told, which is the case the old single-send contract described.
    /// `rateLimited` gates **each device** through the cooldown rather than the account. Off for
    /// the must-send paths — logout broadcast, manual reset, terminal init failure — which are
    /// deliberately not rate-limited and never were.
    ///
    /// Returns the number of devices a send was attempted for, which is what the rate-limited
    /// wrapper reports: attempted, not delivered, because a network failure still consumed the
    /// cooldown and the caller must not immediately retry.
    @discardableResult
    /// - Parameter devices: when the caller knows which of the peer's devices the teardown is
    ///   about — the server refused one device's ciphertext, say — the candidates are narrowed to
    ///   those. The plan is still the core's; this only keeps a device whose session was never in
    ///   question out of it. `nil` means the whole set, which is the ordinary reset.
    func sendEndSession(
        to peerId: String,
        devices: [String]? = nil,
        reason: String = "manual_reset",
        resetReason: Shared_Proto_Messaging_V1_SessionResetReason = .unspecified,
        peerOnDeadSession: Bool = false,
        cause: CfeTearDownCause = .blind,
        rateLimited: Bool = false
    ) async throws -> Int {
        // Translation here, decision in the core. This app owns `account → devices` because the
        // core has no `ServerUserId`; it does not own "which of them does this teardown touch",
        // which is a plan and therefore protocol — see AGENTS.md, "The core decides, this app
        // executes", and `orchestration::teardown_plan`.
        var deviceSet = SessionAddressing.deviceIds(
            ofPeer: peerId,
            in: PersistenceController.shared.container.viewContext
        )
        if let devices { deviceSet = deviceSet.filter { devices.contains($0) } }
        guard !deviceSet.isEmpty else {
            Log.info(
                "END_SESSION skipped for \(peerId.prefix(8))… — no device can be named (\(reason))",
                category: "SessionCoordinator"
            )
            return 0
        }
        guard let core = CryptoManager.shared.orchestratorCore else {
            Log.error("END_SESSION skipped for \(peerId.prefix(8))… — core not initialised", category: "SessionCoordinator")
            return 0
        }
        let plan = core.planTeardown(candidateDeviceIds: deviceSet, peerOnDeadSession: peerOnDeadSession)
        let targets = plan.filter { $0.action != TeardownAction.skip }
        guard !targets.isEmpty else {
            // Not a failure: nothing of ours to condemn and no evidence anyone is on a dead
            // session. Under sealed sender an envelope saying that costs a Privacy Pass token.
            Log.info(
                "END_SESSION: nothing to tear down for \(peerId.prefix(8))… — \(deviceSet.count) device(s) all skipped (\(reason))",
                category: "SessionCoordinator"
            )
            return 0
        }
        Log.info(
            "Sending END_SESSION to \(peerId.prefix(8))… across \(targets.count)/\(deviceSet.count) device(s): \(reason)"
            + "\(resetReason != .unspecified ? " [hint=\(resetReason)]" : "")",
            category: "ChatsViewModel"
        )

        var firstError: Error?
        var delivered = 0
        var attempted = 0
        for decision in targets {
            let device = decision.deviceId
            // Per device, inside the loop. Outside it and keyed by the account, one timestamp
            // stood for every device the plan named.
            if rateLimited, !recordEndSessionSendIfAllowed(device, cause: cause) {
                Log.info(
                    "END_SESSION cooldown active for device \(device.prefix(8))… of \(peerId.prefix(8))…, skipping (\(reason))",
                    category: "SessionCoordinator"
                )
                continue
            }
            attempted += 1
            // Identify the session being condemned BEFORE the network round-trip. The teardown
            // below destroys whatever session exists when the RPC returns, and the peer can
            // establish a new one inside that window — see
            // `SessionReducer.shouldTearDownAfterEndSession`. Read per device: the window is per
            // session, and there is one session per device.
            let condemnedEpoch = CryptoManager.shared.sessionEpoch(for: device)
            do {
                let response = try await MessagingServiceClient.shared.sendEndSession(
                    toDevice: device, reason: reason, resetReason: resetReason
                )
                delivered += 1
                Log.info("END_SESSION sent to \(device.prefix(8))…: \(response.messageId)", category: "ChatsViewModel")
            } catch {
                if firstError == nil { firstError = error }
                Log.error("Failed to send END_SESSION to \(device.prefix(8))…: \(error)", category: "ChatsViewModel")
                // No local teardown for a device we could not tell. Archiving here would leave us
                // unable to read a session the peer is still happily using.
                continue
            }
            // `.sendOnly` means we hold no session with this device — the peer is on one we cannot
            // read, and telling them is the whole point. There is nothing local to archive, and
            // running the teardown below would archive whatever session appeared during the flight.
            guard decision.action == TeardownAction.sendAndArchive else { continue }

            let currentEpoch = CryptoManager.shared.sessionEpoch(for: device)
            guard SessionReducer.shouldTearDownAfterEndSession(
                condemned: condemnedEpoch, current: currentEpoch
            ) else {
                Log.info(
                    "SESSION_STATE[end_session_teardown_skipped]: session for \(device.prefix(8))… changed during the END_SESSION flight (condemned=\(condemnedEpoch.logDescription) current=\(currentEpoch.logDescription)) — keeping it",
                    category: "SessionInit"
                )
                continue
            }
            CryptoManager.shared.archiveSession(for: device, reason: .manualReset)
            CryptoManager.shared.clearArchivedSessions(for: device)
        }

        Log.info(
            "END_SESSION complete for \(peerId.prefix(8))…: \(delivered)/\(targets.count) device(s)",
            category: "ChatsViewModel"
        )
        if delivered == 0, attempted > 0, let firstError { throw firstError }
        return attempted
    }

    /// Ask the core whether this ratchet may be torn down now.
    ///
    /// The window is the machine's — `orchestration::session_machine`, reached through the same
    /// `handle_event` the core's own teardowns take. It used to be here as well: a 30 s
    /// `endSessionSentAt` beside the core's 5 s `cooldowns`, two gates on one envelope to one
    /// device, and what a peer actually experienced was whichever noticed first. See
    /// `decisions/session-is-one-state-machine.md`, step 2.
    ///
    /// A refusal is not a drop. The core records the debt and arms the alarm that pays it, which
    /// is what the `scheduleTimer` in the returned list is; executing the list here is what arms
    /// it. `sendEndSession` is deliberately a no-op in the executor — the send belongs to the
    /// caller that asked.
    ///
    /// `cause` says what this teardown knows. It is **not** `peerOnDeadSession`, which the same
    /// call used to pass: that flag answers `plan_teardown`'s question — whether a device we hold
    /// no session with should still be told — and is true on branches where the machine's answer
    /// must differ. One value for two questions is why a blind teardown and an explained one were
    /// indistinguishable here. What each cause buys is the machine's to decide, not this site's.
    ///
    /// Keyed by **device**, because the thing it rate-limits is. The teardown became per-device
    /// when the plan moved to the core, and this gate spent a while on the account outside the
    /// loop: one timestamp stood for N sends, so tearing down device A silenced device B for the
    /// whole window — and B is exactly the device that might be on a session we cannot read.
    private func recordEndSessionSendIfAllowed(
        _ deviceId: String,
        cause: CfeTearDownCause = .blind
    ) -> Bool {
        let event = CfeIncomingEvent.teardownRequested(contactId: deviceId, cause: cause)
        guard let actions = try? CryptoManager.shared.handleOrchestratorEvent(
            event,
            tag: "teardown_requested"
        ) else {
            // The core is the only thing that holds sessions, so a core that cannot answer holds
            // none — there is nothing to tear down and no one to tell.
            Log.error(
                "END_SESSION not asked for device \(deviceId.prefix(8))… — core did not answer",
                category: "SessionCoordinator"
            )
            return false
        }
        SessionActionExecutor.shared.execute(actions)
        return actions.contains { action in
            if case .sendEndSession = action { return true }
            return false
        }
    }

    /// Single gated END_SESSION entry point for the storm-prone recovery paths (DR diverge,
    /// terminal init failure). Returns `true` iff a send was attempted — attempted, not
    /// delivered, because a network failure still spent the window and the caller must not
    /// immediately retry into it. Must-send paths — logout broadcast, manual reset — call
    /// `sendEndSession` directly and are intentionally not gated.
    ///
    /// `gated: false` is for a caller that is already holding the machine's answer: the alarm
    /// that pays an owed teardown fires with a grant in hand, and asking again would land inside
    /// the window that grant just opened and defer the very debt it came to pay.
    @discardableResult
    private func sendEndSessionRateLimited(
        to userId: String,
        reason: String,
        peerStillOnDeadSession: Bool = false,
        cause: CfeTearDownCause = .blind,
        gated: Bool = true
    ) async -> Bool {
        Log.info("Sending END_SESSION to \(userId.prefix(8))… (\(reason))", category: "SessionCoordinator")
        do {
            // The gate moved inside, and it had to: the cooldown is per device and the device set
            // is only known in there, after the core has named which of them the teardown touches.
            // Asking here meant asking about an account, then acting on N devices.
            //
            // The flag is forwarded rather than re-derived. It is evidence — a message arrived on a
            // session we no longer have — and it is what turns a device we hold no session with
            // from `.skip` into `.sendOnly` in the core's plan. That device is precisely the one
            // that must restart, so dropping the flag here would make the recovery path unable to
            // reach the branch it exists for.
            return try await sendEndSession(
                to: userId,
                reason: reason,
                peerOnDeadSession: peerStillOnDeadSession,
                cause: cause,
                rateLimited: gated
            ) > 0
        } catch {
            Log.error("Failed to send END_SESSION to \(userId.prefix(8))…: \(error)", category: "SessionCoordinator")
            // A throw means every device we attempted failed on the network. The cooldown is
            // already recorded for each of them, so this was an attempt — reporting otherwise
            // would invite the caller to retry straight into the same failure.
            return true
        }
    }

    /// Pre-warm sessions for contacts we hold none with. Called once per app launch after the
    /// stream connects.
    ///
    /// Since 2026-09-04 the core answers `Wait` to an open with nothing to send, so what this does
    /// in practice is hydrate the establishment timestamps and tell a peer we lost a session with.
    func prewarmSessions(for contactIds: [String], skipEndSessionNotification: Bool = false) {
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

        // Ensure restored sessions can filter re-delivered END_SESSION (see hydrate docs).
        hydrateEstablishedTimestampsForRestoredSessions()

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

    func sendEndSessionToAllContacts(reason: String = "logout") async {
        Log.info("Sending END_SESSION to all contacts: \(reason)", category: "ChatsViewModel")
        // The core lists **devices**; `sendEndSession` takes an **account** and resolves it to the
        // device set itself (the teardown plan is the core's, the translation is ours). Feeding it
        // device ids — which is what this did while the accessor was called
        // `getAllSessionUserIds` — made `deviceIds(ofPeer:)` find no rows, so every session was
        // skipped with "no device can be named" and logout tore down nothing at all.
        let context = PersistenceController.shared.container.viewContext
        let deviceIds = CryptoManager.shared.getAllSessionDeviceIds()
        // Deduped: a peer with three devices is one teardown over a set, not three over subsets.
        var accountIds: [String] = []
        var seen = Set<String>()
        var unresolved = 0
        for deviceId in deviceIds {
            guard let account = PeerAddress.resolving(device: deviceId, in: context)?.account else {
                unresolved += 1
                continue
            }
            if seen.insert(account).inserted { accountIds.append(account) }
        }
        Log.info(
            "Found \(deviceIds.count) active session device(s) → \(accountIds.count) contact(s)\(unresolved > 0 ? ", \(unresolved) unattributable" : "")",
            category: "ChatsViewModel"
        )
        var successCount = 0
        var failCount = 0
        for userId in accountIds {
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

    /// The path this seam exists for.
    ///
    /// Both halves are used, and they are used for different things: the **device** is what
    /// diverged, so it is what the tie-break ranks, what the cooldown counts and what the teardown
    /// is addressed to; the **account** is what a re-init fetches a bundle for. Before 2026-09-01
    /// one id did all four, and when it arrived from the core it was a device id — so
    /// `reinitAndAnnounceAsInitiator` asked the key service for an account that does not exist and
    /// every recovery on this path failed `notFound`, three attempts at a time. See `PeerAddress`.
    func messageRouter(_ router: MessageRouter, needsEndSession peer: PeerAddress) {
        handleNeedsEndSession(peer, preapproved: false)
    }

    func messageRouter(_ router: MessageRouter, coreGrantedEndSession peer: PeerAddress) {
        handleNeedsEndSession(peer, preapproved: true)
    }

    /// - Parameter preapproved: the caller already holds the machine's grant for this device and
    ///   must not ask for a second one — the owed-teardown alarm, and the core's own
    ///   `sendEndSession` verdict on an incoming message.
    private func handleNeedsEndSession(_ peer: PeerAddress, preapproved: Bool) {
        Task { [weak self] in
            guard let self else { return }
            // Our own half of every tie-break below. Empty means the Keychain is unreadable, in
            // which case no session decision can be made at all.
            guard !SessionAddressing.localIdentity().isEmpty else { return }

            // The device space for everything below the seam. `nil` is the same state as "we
            // have never pinned this contact's key", in which no session with them exists and
            // there is nothing to tear down — the teardown plan would return no targets anyway.
            guard let divergedDevice = peer.deviceOrPinned() else {
                Log.info("END_SESSION skipped for \(peer) — no device can be named", category: "SessionCoordinator")
                return
            }

            // One teardown per divergence, whichever side we are: nothing is ranked since
            // 2026-09-27. The peer's answer is its next message, which carries the handshake
            // header and opens a new state here (`decisions/sessions-renew-by-sending.md`). Until
            // then the natural INITIATOR sent a SESSION_RESET_INIT instead, and the RESPONDER an
            // END_SESSION and a request for the rebuild.
            //
            // A message arrived on a session we cannot read, which is proof the peer never
            // applied our last END_SESSION if there was one — so the flag that turns a device we
            // hold no session with into `.sendOnly` in the core's plan is set.
            await self.sendEndSessionRateLimited(
                to: divergedDevice,
                reason: "session_out_of_sync",
                peerStillOnDeadSession: true,
                gated: !preapproved
            )
        }
    }

    /// Seconds of clock-skew tolerance when deciding whether an END_SESSION pre-dates our session.
    private static let endSessionStaleFudge: UInt64 = 5

    /// `peer.device` is the device that sent the teardown, recovered from its sealed certificate
    /// (`ResolvedSender.senderDeviceId`) since 2026-09-21, so `SessionScope(peer)` is that
    /// device's scope and the establishment it is compared against is that ratchet's. An
    /// unsealed teardown names no device and resolves to the pinned one, the only session it can
    /// be about.
    func messageRouter(_ router: MessageRouter, isEndSessionStale peer: PeerAddress, timestamp: UInt64) -> Bool {
        let userId = peer.account
        let established = establishedAt(for: SessionScope(peer))
        let stale = SessionReducer.isEndSessionStale(
            establishedAt: established, timestamp: timestamp, fudgeSeconds: Self.endSessionStaleFudge
        )
        // Diagnostic for the post-launch reset hypothesis: `established == nil` means we have no
        // in-memory establishment record, so we CANNOT filter a possibly-stale END_SESSION — and
        // if a live Rust session exists, it is about to be torn down. Surface this in device logs.
        if established == nil {
            let hasLive = CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId)
            Log.info("SESSION_STATE[end_session_stale_check]: \(userId.prefix(8))… ts=\(timestamp) established=nil hasLiveSession=\(hasLive) → not filtered\(hasLive ? " live session will be reset by a possibly-stale END_SESSION (no in-memory establishedAt)" : "")", category: "SessionInit")
        } else {
            Log.info("SESSION_STATE[end_session_stale_check]: \(userId.prefix(8))… ts=\(timestamp) established=\(established!) → \(stale ? "STALE (filtered)" : "fresh (acted on)")", category: "SessionInit")
        }
        return stale
    }

    func messageRouter(_ router: MessageRouter, receivedEndSession peer: PeerAddress, timestamp: UInt64) {
        let userId = peer.account
        // The peer tore this ratchet down: tell the machine, which is where the quiet that
        // follows now lives. It used to be a 20 s `lastInboundEndSessionAt` map here, beside the
        // core's own 30 s window, both answering "may an END_SESSION go to this device" and
        // neither aware of the other — step 2 of `decisions/session-is-one-state-machine.md`.
        //
        // Per device, and it can be: `peer.device` is the sending device from its sealed
        // certificate since 2026-09-21 (§D), and an unsealed teardown falls back to the pinned
        // one — the only session it can be about. The map it replaces was account-keyed because
        // at the time nothing named the sender, so one peer's teardown quieted every device.
        if let device = peer.deviceOrPinned() {
            _ = try? CryptoManager.shared.handleOrchestratorEvent(
                .peerToreDown(contactId: device),
                tag: "peer_tore_down"
            )
        }

        // The peer's next message opens a new state here, and a contact with no Core Data record
        // yet has no stream subscription to receive it on.
        onEphemeralSubscriptionNeeded?(userId)

        // What we sent on the torn-down session goes out again, and the first of it opens a new
        // one: a session is opened by sending (`decisions/sessions-renew-by-sending.md`). Until
        // 2026-09-27 a reopen was asked of the core here, ranked, deferred for the peer's flush
        // and announced with a SESSION_RESET_INIT.
        resendUnconfirmedOutgoingMessagesIfNeeded(to: userId)
        sendSessionQueuedMessages(for: userId)
    }

    /// Open a new session with `userId` as INITIATOR over the one held — the answer to the core's
    /// `OpenSession` (the PQXDH v2 upgrade sweep). Nothing is announced: the handshake header
    /// rides on the next message, and anything already queued for the peer goes now. The core
    /// keeps the replaced state as a previous one, so what the peer sends on it meanwhile still
    /// decrypts.
    ///
    /// Until 2026-09-27 this was `reinitAndAnnounceAsInitiator`: the same init, then a
    /// SESSION_RESET_INIT, a confirm window raised over it and every outgoing message held until
    /// the peer's `session_ready`.
    private func reopenAsInitiator(to userId: String, reason: String) {
        assertMainThread()
        guard !initiatorReinitInFlight.contains(userId) else {
            Log.info("SESSION_STATE[reopen_coalesced]: reopen already in flight for \(userId.prefix(8))… (\(reason))", category: "SessionInit")
            return
        }
        initiatorReinitInFlight.insert(userId)
        Log.info("SESSION_STATE[reopen]: new session for \(userId.prefix(8))… (\(reason))", category: "SessionInit")
        Task { [weak self] in
            guard let self else { return }
            defer { self.initiatorReinitInFlight.remove(userId) }
            await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                // The core asked for this state; the next message is what carries it.
                hasOutboundWork: true,
                onSuccess: { },
                onFailure: { err in
                    // A refusal (`PQ_REQUIRED` from a peer on an old build) keeps the held session
                    // exactly as it was, so there is nothing to undo.
                    Log.error("SESSION_STATE[reopen_fail]: \(err.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            )
            self.sendSessionQueuedMessages(for: userId)
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

    /// Stop trying to establish a receiving session for `userId`, release everything held on its
    /// behalf, and ask the peer to restart.
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

        // If the init failed because we couldn't reproduce the sender's OTPK, ask them
        // (via the typed END_SESSION reason) to re-init WITHOUT one — 3-DH is always
        // reproducible, so this breaks the 4-DH retry loop instead of perpetuating it.
        let otpkUnreproducible = SessionReinitHintStore.shared.consumeResponderOtpkUnreproducible(for: userId)
        Task { [weak self] in
            guard let self else { return }
            await self.replenishOtpksAfterFailure(reason: "init_failed")

            // Single branch authority — otpk or plain, decided by the reducer. The third branch
            // it used to have, `.suppressWithinGrace`, is gone: whether the peer's own teardown
            // silences this one is the machine's answer now, given per device inside the send,
            // and it distinguishes the two branches below — which a `Bool` checked out here
            // could not. A plain teardown after the peer tore down says what they just told us;
            // the typed one says something they cannot work out, and must survive.
            let failureAction = SessionReducer.initFailureAction(otpkUnreproducible: otpkUnreproducible)
            switch failureAction {
            case .sendTypedOtpk:
                // Must carry the typed reason; the window is asked for per device inside the
                // send, like every other gated path. It was asked for here until 2026-09-22, and
                // with `userId` — an account, into a gate keyed by device. That ask matched no
                // device's window, spent a phase under an id the core holds no ratchet for, and
                // then sent ungated to every device the plan named.
                do {
                    try await self.sendEndSession(
                        to: userId,
                        reason: "session_init_failed_otpk_unreproducible",
                        resetReason: .otpkUnreproducible,
                        peerOnDeadSession: failureAction.peerOnDeadSession,
                        cause: failureAction.cause,
                        rateLimited: true
                    )
                } catch {
                    Log.error("SESSION_STATE[init_failed_end_session]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }

            case .sendPlain:
                _ = await self.sendEndSessionRateLimited(
                    to: userId,
                    reason: "session_init_failed",
                    peerStillOnDeadSession: failureAction.peerOnDeadSession,
                    cause: failureAction.cause
                )
            }
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
        // The archive of a replaced session, the save, the opener and what drained behind it.
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
                Log.info("SESSION_STATE[otpk_unreproducible]: \(userId.prefix(8))… — will request 3-DH re-init via END_SESSION", category: "SessionInit")
                SessionReinitHintStore.shared.recordResponderOtpkUnreproducible(for: userId)
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
        if let certificate, certificate.deviceId == opened, let context = viewContext {
            SessionAddressing.recordDevices(
                [(deviceId: certificate.deviceId, identityKey: certificate.identityKey)],
                ofPeer: userId,
                in: context
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
            // The establishment record is about the one ratchet that opened; hydration reads it
            // back by device on the next launch.
            apply(.initSucceeded(at: UInt64(Date().timeIntervalSince1970)), for: .device(device))
            // Re-send messages that were re-queued on a prior END_SESSION. Nothing is announced
            // back: the peer learns we hold the session from our next message on it.
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

    /// Re-sends any outgoing messages that were marked `.queued` by `requeueUndeliveredOutgoing`
    /// after receiving END_SESSION (i.e. messages encrypted under the now-replaced session).
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
        // Cooldown entries older than 2× their window are safe to remove. The END_SESSION window
        // is no longer among them: the core sweeps its own on `gc_sweep`, and the rule that makes
        // the sweep safe — a spent retry budget outlives the window that spent it — is a
        // transition in `session_machine`, not a timer here.
        let resendTTL = resendCooldown * 2

        let beforeRA = resendAttemptedAt.count
        resendAttemptedAt = resendAttemptedAt.filter { now.timeIntervalSince($0.value) < resendTTL }

        let removedRA = beforeRA - resendAttemptedAt.count
        if removedRA > 0 {
            Log.debug("Purged \(removedRA) resend cooldown entries", category: "SessionInit")
        }
    }

    // The handshake controls — SESSION_RESET_INIT, the session ping and `session_ready` — and the
    // session-init `saveMessage` that discarded them on arrival lived here until 2026-09-27. A
    // session is opened by sending, so there is nothing to announce or confirm
    // (`decisions/sessions-renew-by-sending.md`).

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
        // messages would be silently excluded from auto-resend after the session reopens.
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
        fetch.sortDescriptors = [
            NSSortDescriptor(key: "serverOrderKey", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
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

            // E14: one save for all "sending" marks instead of save-per-message before network.
            var resendQueue: [(Message, String)] = []
            resendQueue.reserveCapacity(candidates.count)
            for msg in candidates {
                let plaintext = msg.displayText
                guard !plaintext.isEmpty else { continue }
                // This fetch selects `.sent` rows on purpose, and `.sending` ranks below `.sent`,
                // so the guarded setter refuses the mark. The archive that brought us here is what
                // voided the evidence, so it goes through the writer that says so.
                msg.applyArchiveOutcome(.resend)
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
                        msg.applyArchiveOutcome(.giveUp)
                        context.saveAndLog()
                        continue
                    }

                    // Every device of theirs, sealed per device, through the one sender — a
                    // resend after a teardown is not a place for a second send path.
                    let response = try await OutboundMessagePipeline.shared.sendToRecipientDevices(
                        plan: plan,
                        baseMessageId: msg.id,
                        senderId: myId,
                        recipientId: userId,
                        timestamp: UInt64(msg.timestamp.timeIntervalSince1970)
                    ).status
                    let newStatus: DeliveryStatus
                    switch response.status.lowercased() {
                    case "delivered": newStatus = .delivered
                    case "queued": newStatus = .queued
                    case "failed", "blocked": newStatus = .failed
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
                    // `.failed` ranks below `.sent`, so this too must go through the archive
                    // writer — otherwise a resend that threw leaves the row on the checkmark it
                    // had, and `retryCount` has already moved past this fetch's `== 0`, so nothing
                    // comes back for it.
                    msg.applyArchiveOutcome(.giveUp)
                    context.saveAndLog()
                    Log.error("Auto-resend failed for \(msg.id.prefix(8))…: \(error.localizedDescription)", category: "SessionInit")
                }
            }
        }
    }

    private func ensureSendingSession(for userId: String) async throws {
        if CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId) {
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
