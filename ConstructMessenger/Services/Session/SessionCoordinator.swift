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

    /// Tracks when we last attempted an automatic resend after receiving END_SESSION from a peer.
    /// Prevents resend loops when both sides reset simultaneously.
    private var resendAttemptedAt: [String: Date] = [:]
    private let resendCooldown: TimeInterval = 10.0
    private let resendWindow: TimeInterval = 5 * 60 // 5 minutes

    /// Peers with an INITIATOR re-init currently executing (any entry point).
    ///
    /// The machine refuses a second `Opening` for a device, but it only learns of this one when
    /// the SESSION_RESET_INIT is announced — and the window this guards is the one *before* that,
    /// while the bundle fetch runs. A second re-init starting there deletes the session the first
    /// just created, invalidating its SRI before the peer ever sees it; overlaps are dropped and
    /// the core's retry re-sends if the surviving SRI is lost.
    ///
    /// Account-keyed on purpose while it lasts: the init runs for a whole account's device set.
    /// It goes when the announce itself is core-driven — step 5.
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

    /// Returns true if a session init (or heal) is currently in progress for `scope`.
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
        // The machine's grant to reopen, whichever way it arrives: immediately from
        // `reopenRequested`, or off the core's own `reopen_quiet:` alarm once the peer's
        // teardown flush has finished. Same backwards read of the seam as the teardown hook
        // above, and the same reason — the core names a device and the announce addresses an
        // account.
        SessionActionExecutor.shared.onOpenSession = { [weak self] deviceId in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else {
                Log.info(
                    "Granted re-init dropped: device \(deviceId.prefix(8))… belongs to no known contact",
                    category: "SessionCoordinator"
                )
                return
            }
            Log.info("SESSION_STATE[reopen_granted]: re-init as natural INITIATOR for \(peer)", category: "SessionInit")
            self.reinitAndAnnounceAsInitiator(to: peer.account, reason: "end_session_received")
        }
        // The retry and the bound of an unanswered announcement, both the machine's. They were
        // `startTieBreakWatchdog` — a `Task.sleep` loop per account that re-sent the SRI and, on
        // give-up, released the gate. Same two outcomes, decided where the phase is.
        SessionActionExecutor.shared.onResendSri = { [weak self] deviceId in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else {
                Log.info(
                    "SRI re-send dropped: device \(deviceId.prefix(8))… belongs to no known contact",
                    category: "SessionCoordinator"
                )
                return
            }
            Log.info("SESSION_STATE[sri_resend]: no acknowledgement — re-announcing to \(peer)", category: "SessionInit")
            Task { await self.emitHandshakeControls(.tieBreakWin, to: peer) }
        }
        SessionActionExecutor.shared.onOpeningGaveUp = { [weak self] deviceId in
            guard let self else { return }
            let ctx = self.viewContext ?? PersistenceController.shared.container.viewContext
            guard let peer = PeerAddress.resolving(device: deviceId, in: ctx) else { return }
            Log.info(
                "SESSION_STATE[opening_gave_up]: confirm window exhausted for \(peer) — releasing the gate and flushing both directions",
                category: "SessionInit"
            )
            // `acknowledged: false` — the machine has already dropped the phase, and telling it
            // the peer answered would be a lie the next decision reads back. What it held
            // incoming rides on the same answer as this action.
            self.releaseConfirmGate(peer, acknowledged: false)
        }
        CryptoManager.shared.onHeldReleased = { [weak self] actions in
            self?.messageRouter.performHeldReleases(actions)
        }
        startCooldownPurgeTimer()
    }

    /// After CFE restore the Rust core has live sessions but `sessionPhases` / Keychain
    /// `establishedAt` may be empty (older builds never persisted them). Without a timestamp,
    /// re-delivered END_SESSION is never filtered as stale and tears down healthy sessions →
    /// SESSION_RESET_INIT / openStream storms. Hydrate once the core is ready.
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
    /// the must-send paths — logout broadcast, manual reset, terminal init/heal failure — which are
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

    /// Broadcast END_SESSION to all peers that have an active session (e.g., on logout).
    /// Pre-warm sessions for contacts where we are the natural INITIATOR (see
    /// `SessionAddressing.isNaturalInitiator(againstPeer:)`, which asks the core).
    /// Called once per app launch after stream connects. Ensures first messages are instant.
    func prewarmSessions(for contactIds: [String], skipEndSessionNotification: Bool = false) {
        // Our own half of every tie-break below. Empty means the Keychain is unreadable, in
        // which case no session decision can be made at all.
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
            // A peer with no pinned identity key has no name in the crypto space, so the pair
            // cannot be ranked — and prewarming on a role we guessed is the concurrent init this
            // predicate exists to prevent. Skip them: the session still establishes on the first
            // send, whose bundle fetch pins the key that makes the peer nameable.
            guard let weInitiate = SessionAddressing.isNaturalInitiator(againstPeer: peer) else {
                return false
            }
            return SessionReducer.shouldPrewarm(
                coreReady: coreReady,
                isNaturalInitiator: weInitiate,
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

            // **One teardown signal per divergence.** As the natural INITIATOR we are about to send
            // a SESSION_RESET_INIT, and SESSION_RESET_INIT *is* the teardown — "archive the session
            // you hold, here is the new one", atomically, which is why it replaced
            // `sendEndSession + sendSessionPing` in the first place. Sending both meant the peer
            // received two instructions about one event, in whatever order the network chose, and
            // the END_SESSION applied to whatever it held when it arrived — including the session
            // our own SRI had just built.
            //
            // Device 2026-08-21, one divergence turning into two full re-inits:
            //
            //     17:03:22  B  rust_end_session: DR diverged — sending END_SESSION
            //     17:03:23  B  re-init + SESSION_RESET_INIT (dr_diverge)
            //     17:03:25  B  session_ready_received — A built the session, gate confirmed
            //     17:03:26  B  Received END_SESSION from A   ← A tore down what it had just built
            //     17:03:28  B  re-init + SESSION_RESET_INIT (end_session_received)
            //
            // The RESPONDER branch keeps the END_SESSION: it announces nothing of its own, so the
            // teardown is the only thing that tells the peer to stop using a session we cannot read.
            // An unnameable peer takes the RESPONDER branch below. Reaching this callback at all
            // means we once held a session with them, so `nil` is not expected here — and it is no
            // reason to send an init whose role we guessed. The RESPONDER branch announces nothing
            // of its own; it only tells the peer to stop using a session we cannot read.
            guard SessionAddressing.isNaturalInitiator(againstPeer: divergedDevice) ?? false else {
                // Cooldown gates the whole recovery sequence here: if a recent END_SESSION is still
                // in its window, skip both the send AND the fallback below (avoids storms). This
                // callback fires because a message arrived on a session we no longer have — which
                // is proof the peer never applied our last END_SESSION. Suppressing the
                // re-notification on the plain cooldown is what left the two sides permanently
                // disagreeing (device 2026-08-11 07:19:03, messageNumber 3 and 4 both skipped).
                guard await self.sendEndSessionRateLimited(
                    to: divergedDevice,
                    reason: "session_out_of_sync",
                    peerStillOnDeadSession: true,
                    gated: !preapproved
                ) else {
                    return
                }
                // The teardown is out and the rebuild is the peer's to make. Ask for it rather
                // than schedule it: the machine ranks the pair, hands back a deferral, and its
                // own alarm takes the role if their rebuild never comes.
                //
                // A 300 ms sleep stood here so the END_SESSION would land before the 60 s
                // `Task.sleep` was armed. Neither is needed: the wait is measured from the
                // teardown the machine recorded, not from the moment we get around to asking.
                Log.info("DR diverge: asking for the rebuild of \(peer)", category: "SessionInit")
                if let actions = try? CryptoManager.shared.handleOrchestratorEvent(
                    .reopenRequested(contactId: divergedDevice),
                    tag: "dr_diverge"
                ) {
                    SessionActionExecutor.shared.execute(actions)
                }
                return
            }

            // The same window, and asked for even though what goes out is a SESSION_RESET_INIT
            // rather than an END_SESSION: the bound is on how often we re-drive a handshake with
            // one peer, and SRI *is* the teardown on this branch — "archive what you hold, here
            // is the new one". A bound attached only to the envelope it was first written for
            // would not survive the branch that stopped sending that envelope.
            //
            // `Unacknowledged`, like the core's own `EndSessionNeeded` for the same situation: a
            // message arrived on a ratchet we cannot read, which is proof rather than suspicion.
            // Not `Blind` — this must survive the peer's own teardown, because what goes out is
            // the rebuild and not a repetition of what they said.
            guard preapproved || self.recordEndSessionSendIfAllowed(divergedDevice, cause: .unacknowledged) else {
                Log.info("DR diverge: re-init cooldown active for \(peer), skipping", category: "SessionInit")
                return
            }
            Log.info("DR diverge: auto-reinit as natural INITIATOR for \(peer) (SESSION_RESET_INIT carries the teardown)", category: "SessionInit")
            // The account, not the device: this ends in a bundle fetch, and the key service is
            // asked for an account. The device it diverged with is already spent — on the
            // tie-break, the cooldown and the teardown above.
            self.reinitAndAnnounceAsInitiator(to: peer.account, reason: "dr_diverge")
        }
    }

    /// The device the core named is on `peer.device`; the heal opens from the carrier the core
    /// queued for it, with the key its sender certificate names.
    func messageRouter(_ router: MessageRouter, needsSessionHeal peer: PeerAddress, failedMessage: ChatMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleSessionHealNeeded(peer: peer, failedMessage: failedMessage)
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

    func messageRouter(
        _ router: MessageRouter,
        isResetInitSuperseded peer: PeerAddress,
        timestamp: UInt64,
        initEphemeral: Data
    ) -> Bool {
        // The core decides and keeps the ledger of applied inits, per device (step 5 of
        // decisions/session-is-one-state-machine). This used to be `appliedResetInits`, an
        // account-keyed map here that the machine owning the same ratchet never saw.
        //
        // `peer.device` is the sender from the sealed certificate; an unsealed init falls back
        // to the pinned device, the only session it can be about. No device at all means no
        // pinned key, so no session to pre-date — apply.
        guard let device = peer.deviceOrPinned() else {
            Log.info("SESSION_STATE[reset_init_supersede_check]: \(peer) ts=\(timestamp) no device → apply", category: "SessionInit")
            return false
        }
        let established = establishedAt(for: SessionScope(peer))
        let verdict = CryptoManager.shared.judgeResetInit(
            fromDevice: device,
            initEphemeral: initEphemeral,
            sentAt: timestamp,
            establishedAt: established
        )
        if verdict == .redelivery {
            PerformanceMetrics.shared.record(.resetInitDuplicate, label: "redelivery")
        }
        Log.info("SESSION_STATE[reset_init_supersede_check]: \(peer) ts=\(timestamp) established=\(established.map(String.init) ?? "nil") → \(verdict)", category: "SessionInit")
        return verdict != .apply
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
        let device = peer.deviceOrPinned()
        if let device {
            _ = try? CryptoManager.shared.handleOrchestratorEvent(
                .peerToreDown(contactId: device),
                tag: "peer_tore_down"
            )
        }
        // No local identity means the Keychain is unreadable, and then nothing below can be
        // decided — here or in the core, which ranks the pair against this same id.
        guard !SessionAddressing.localIdentity().isEmpty else { return }
        guard let device else { return }

        // The peer's X3DH is what we are waiting for either way — as the RESPONDER it is the
        // only thing that will arrive, as the INITIATOR it is what answers ours — and a contact
        // with no Core Data record yet has no stream subscription to receive it on. This used to
        // hang off the RESPONDER arm of a role switch here; it is not a role-shaped need.
        onEphemeralSubscriptionNeeded?(userId)

        // Ask; do not schedule, and do not rank. Two client timers stood here. The first was a
        // 1.5 s `Task.sleep` with an `endSessionReinitTasks` map beside it — a debounce waiting
        // out the rest of the flush, and a coalescer so N teardowns in that flush produced one
        // re-init instead of N that each destroyed the previous one's session. The second was
        // the role branch: `endSessionReceiptAction` over `isNaturalInitiator`, whose RESPONDER
        // arm armed a 60 s `[String: Task]` keyed by account — so one device's teardown armed
        // the wait for the whole person.
        //
        // Both are one phase per device now, and both answers arrive as `.openSession`: at once,
        // after the flush, or when the peer's turn runs out. The "has a session appeared
        // meanwhile" guard went with them — the core holds the ratchet, so it is the one that
        // can see it — and so did the resend, which belongs where the rebuild actually starts.
        if let actions = try? CryptoManager.shared.handleOrchestratorEvent(
            .reopenRequested(contactId: device),
            tag: "reopen_requested"
        ) {
            SessionActionExecutor.shared.execute(actions)
        }
    }

    func messageRouter(_ router: MessageRouter, didWinTieBreak peer: PeerAddress) {
        // Device-keyed, matching every `saveSessionSuiteId` call site. Read by account it missed
        // every time and logged 0 — beside a `suite_negotiated` line saying 3.
        let suiteIdAtWin = Int(peer.deviceOrPinned().flatMap {
            KeychainManager.shared.loadSessionSuiteId(userId: $0)
        } ?? 0)
        Log.info("SESSION_STATE[tie_break_outcome]: INITIATOR role confirmed, peer=\(peer) suiteId=\(suiteIdAtWin), sending SESSION_RESET_INIT", category: "SessionInit")
        reinitAndAnnounceAsInitiator(to: peer.account, reason: "tie_break_win")
    }

    /// Re-initialise as INITIATOR **and transmit** the X3DH init (SESSION_RESET_INIT)
    /// to the peer, then arm the tie-break watchdog to re-send if no `session_ready`
    /// comes back. Every natural-INITIATOR entry point must go through here.
    ///
    /// Why this exists: the DR-diverge and END_SESSION-as-initiator paths used to call
    /// bare `prewarmSessions`, which creates a local INITIATOR session but sends the peer
    /// *nothing*. The peer's RESPONDER wait then timed out after 60s and flipped to
    /// INITIATOR — producing a dueling-initiator deadlock where the winner buffers its
    /// outgoing messages forever (the confirm window never closes) and
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
        // The messages that rode the ratchet this replaces. Called here rather than at the
        // inbound-teardown delegate, which is where the role switch used to put it: a rebuild
        // held behind the flush quiet reaches this method off the machine's alarm and never
        // returns to that delegate, so the resend went missing exactly when the hold applied.
        // It carries its own cooldown and finds nothing to do on a first contact.
        resendUnconfirmedOutgoingMessagesIfNeeded(to: userId)
        // Mark pending synchronously at announce time, before any await:
        //  1. It gates `sendSessionInitPing`. With proactive-init coalescing the SRI and the ping
        //     share one session, so only one can be msgNum=0 — the SRI must win, it is the X3DH
        //     carrier the RESPONDER bootstraps from. Setting the flag inside the Task would leave
        //     the two coalesced continuations racing for it.
        //  2. A peer replying `session_ready` faster than the old post-emit call hit
        //     `markConfirmed`'s `guard removeValue != nil` and was swallowed, leaving the gate up
        //     until the watchdog TTL.
        // Raised for the devices the directory already names, then again for the ones the init
        // actually opened — the second raise restamps the window at the real announcement. On a
        // genuine first contact the directory answers nothing and nothing is raised, which costs
        // nothing: there is no ratchet yet, so there is neither anything to confirm nor anything
        // to hold. The raise used to be account-keyed for this case; the machine is keyed by
        // device, and `deviceIds(ofPeer:)` is the same directory the init is about to plan from.
        announceRaisedFor(SessionAddressing.deviceIds(ofPeer: userId))
        Task { [weak self] in
            guard let self else { return }
            defer { self.initiatorReinitInFlight.remove(userId) }
            var initFailed = false
            let opened = await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                // A divergence forced this; the SESSION_RESET_INIT is itself the thing to send.
                hasOutboundWork: true,
                onSuccess: { },
                onFailure: { err in
                    initFailed = true
                    Log.error("SESSION_STATE[initiator_announce_fail]: \(err.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            )
            // A failed init opened nothing, so the SRI would go out on the ratchet still held — and
            // the peer, reading an SRI, archives that ratchet and tries to open one from a message
            // that is not a carrier. On 2026-09-25 the PQXDH v2 upgrade sweep met a peer on an old
            // build (`PQ_REQUIRED`): the core kept the classical session, as it is designed to,
            // and this SRI then cost both sides their session. Nothing to announce, so announce
            // nothing.
            //
            // And let go of what the gate raised above was holding. The core ends a refused
            // reopen's `Opening` itself (`OpenFailed`), so the gate is already down; what it held
            // meanwhile was queued here, and nothing else releases it — no acknowledgement is
            // coming for an announcement that never went out. Not `acknowledged`: the peer said
            // nothing.
            if initFailed {
                Log.info("SESSION_STATE[initiator_announce_skipped]: init failed, held session left in place for \(userId.prefix(8))… (\(reason))", category: "SessionInit")
                self.releaseConfirmGate(PeerAddress(account: userId), acknowledged: false)
                return
            }
            // The devices the init opened, not the one the account resolves to: an announcement
            // is about a ratchet and there is one per device. Nothing opened (every session was
            // already in place), the account falls back to the pinned device as before.
            self.announceRaisedFor(opened)
            for device in opened.isEmpty ? [nil] : opened.map(Optional.init) {
                await self.emitHandshakeControls(.tieBreakWin, to: PeerAddress(account: userId, device: device))
            }
        }
    }

    /// Re-establish a session for a peer that has QUEUED OUTBOUND messages but no live session
    /// (the "zombie session"): we are the natural RESPONDER for a purely-outbound peer, so
    /// `prewarmSessions` (INITIATOR-only) never fires and no inbound traffic ever triggers a
    /// RESPONDER init — the queued flush in `MessageRetryManager.sendQueuedMessages` would defer
    /// forever waiting for a session that nothing creates.
    ///
    /// Forces the INITIATOR role and transmits SESSION_RESET_INIT, exactly like a tie-break win,
    /// so the peer bootstraps its RESPONDER session and replies `session_ready`. That clears
    /// the confirm window and flushes the queue via `sendSessionQueuedMessages`
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
        guard !CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId) else { return }
        let scope = SessionScope.forAccount(userId)
        guard !isInitializing(scope) else {
            Log.debug("reestablishSessionForQueuedOutbound: init already in progress for \(scope)", category: "SessionInit")
            return
        }
        Log.info("SESSION_STATE[zombie_recover]: no session for purely-outbound peer \(userId.prefix(8))… with queued messages — forcing INITIATOR re-establish", category: "SessionInit")
        // Same reasoning as `reinitAndAnnounceAsInitiator`: mark pending synchronously, before
        // any await, so the SRI (not a coalesced init ping) owns msgNum=0 and a fast peer's
        // `session_ready` cannot arrive before the gate exists.
        announceRaisedFor(SessionAddressing.deviceIds(ofPeer: userId))
        let endInit = beginInit(scope)
        Task { [weak self] in
            guard let self else { endInit(); return }
            defer { endInit() }
            let opened = await self.sessionInitService.initializeSessionProactively(
                userId: userId,
                // The peer has queued messages and no session — the queue is the work.
                hasOutboundWork: true,
                onSuccess: { },
                onFailure: { err in
                    Log.error("SESSION_STATE[zombie_recover_fail]: \(err.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
                }
            )
            // One announcement per opened ratchet; see the twin above.
            self.announceRaisedFor(opened)
            for device in opened.isEmpty ? [nil] : opened.map(Optional.init) {
                await self.emitHandshakeControls(.tieBreakWin, to: PeerAddress(account: userId, device: device))
            }
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
    /// First contact and heal alike, and nothing is fetched: each queued message opens with the
    /// key its sender certificate names (`decisions/first-message-opens-without-the-server.md`).
    /// Until 2026-09-27 this fetched the account's bundles and the core walked every carrier
    /// against every device; the bundle fetch also told the server whom the sealed message was from.
    private func openReceiving(_ peer: PeerAddress, site: String) async -> ReceivingOpenOutcome {
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

        switch await openReceiving(peer, site: "open_receiving_first") {
        case .opened(let device, _):
            // Bob consumed one of his one-time prekeys for this X3DH.
            Task {
                let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
                await OtpkReplenishmentService.replenishIfNeeded(deviceId: deviceId)
            }
            // The establishment record is about the one ratchet that opened; hydration reads it
            // back by device on the next launch.
            apply(.initSucceeded(at: UInt64(Date().timeIntervalSince1970)), for: .device(device))
            // Re-send messages that were re-queued on a prior END_SESSION.
            sendSessionQueuedMessages(for: userId)
            // Phase 2 of the two-phase handshake: the INITIATOR's confirm window closes on this.
            // Addressed to the device that opened: the ready is encrypted on that ratchet.
            let readyTo = PeerAddress(account: userId, device: device)
            Task { [weak self] in
                await self?.emitHandshakeControls(.becameResponder, to: readyTo)
            }
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

    // MARK: - Session healing

    private func handleSessionHealNeeded(peer: PeerAddress, failedMessage: ChatMessage) async {
        let userId = peer.account
        // The device whose ratchet failed, not the peer's pinned one. Healing is about one
        // ratchet, and taking the lock on the pinned device meant a failure on a peer's second
        // device blocked — and reported itself as — work on their first.
        let scope = SessionScope(peer)
        if isInitializing(scope) {
            Log.info("Heal skipped — session init already in progress for \(scope)", category: "SessionInit")
            return
        }
        let endInit = beginInit(scope)
        Log.info("SESSION_STATE[heal_start]: opening from the queued carrier for \(scope)", category: "SessionInit")
        defer {
            endInit()
            Log.debug("Heal lock released for \(scope)", category: "SessionInit")
        }
        guard let context = viewContext else { return }

        // One attempt, spent against the core's budget for this device.
        let canContinue = peer.deviceOrPinned().map {
            CryptoManager.shared.recordHealAttempt(forDevice: $0)
        } ?? false

        let outcome = await openReceiving(peer, site: "open_receiving_heal")
        if case .opened(let device, let openerId) = outcome {
            // Heal does not reset establishment time (no `initSucceeded`). The core settled the
            // episode and released the phase when the session opened.
            Log.info("SESSION_STATE[heal_success]: session healed for \(userId.prefix(8))…/\(device.prefix(8))… on \(openerId.prefix(8))…", category: "SessionInit")
            return
        }
        Log.error("SESSION_STATE[heal_failed]: receiving open still failing for \(userId.prefix(8))…", category: "SessionInit")
        guard !canContinue else {
            // The carrier stays unacknowledged; its redelivery raises the heal again, against
            // the budget.
            return
        }
        Log.info("Heal exhausted — sending END_SESSION to \(userId.prefix(8))…", category: "SessionInit")
        // No receipt — nothing was decrypted; the cursor is advanced by the release, never by a
        // receipt.
        PerformanceMetrics.shared.record(.undeliveredNoReceipt, label: "heal_exhausted")
        FailedInitMessageStore.shared.add(failedMessage.id)
        PersistentACKStore.shared.markProcessed(failedMessage.id, senderId: userId, in: context)
        if case .failed(let tried, _) = outcome {
            messageRouter.releaseCoreQueued(tried + [failedMessage.id])
        } else {
            messageRouter.releaseCoreQueued([failedMessage.id])
        }
        let unreachable: Bool
        switch outcome {
        case .unreachable: unreachable = true
        default: unreachable = false
        }
        let otpkUnreproducible = SessionReinitHintStore.shared.consumeResponderOtpkUnreproducible(for: userId)
        do {
            if unreachable {
                try await sendEndSession(to: userId, reason: "heal_open_unreachable")
            } else {
                try await sendEndSession(
                    to: userId,
                    reason: otpkUnreproducible ? "heal_exhausted_otpk_unreproducible" : "heal_exhausted",
                    resetReason: otpkUnreproducible ? .otpkUnreproducible : .unspecified,
                    // `failedMessage` arrived and stayed unreadable after every heal attempt;
                    // without this the teardown plan skips the devices we hold no session with,
                    // which after an exhausted heal is all of them.
                    peerOnDeadSession: true
                )
            }
        } catch {
            Log.error("SESSION_STATE[heal_exhausted_end_session]: \(error.localizedDescription) for \(userId.prefix(8))…", category: "SessionInit")
        }
        if !unreachable {
            await replenishOtpksAfterFailure(reason: "heal_exhausted")
        }
    }

    /// Drop the tie-break confirm gate for `userId` and flush **both** directions it was holding.
    ///
    /// One call because the two flushes must not drift apart. For as long as the gate existed only
    /// the outgoing side was flushed at these sites, which is precisely why the incoming side had
    /// to be a discard rather than a hold — there was nowhere for a held message to be released.
    /// A future fourth release site gets both by construction.
    /// Re-raise the gate on the ratchets the init actually opened, replacing the placeholder.
    ///
    /// The placeholder exists because the raise cannot wait: a gate raised after the init would
    /// be a gate a fast peer's `session_ready` slips past, which is the race the synchronous
    /// raise at the call sites was written for. So the account is held first and the devices
    /// replace it here.
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

    private func announceRaisedFor(_ devices: [String]) {
        for device in devices {
            // The answer is the `open_confirm:` alarm — the re-send and the give-up both hang off
            // it. Dropped, as it was from 2026-09-23, neither ever happened.
            if let actions = try? CryptoManager.shared.handleOrchestratorEvent(
                .sriAnnounced(contactId: device),
                tag: "sri_announced"
            ) {
                SessionActionExecutor.shared.executeOffRouter(actions, site: "sri_announced")
            }
        }
    }

    /// **Named by device since 2026-09-22.** The gate is *raised* where the device is known (we
    /// are about to send an SRI to it) and *released* by an inbound `session_ready` or ping —
    /// which, since §D, names its sending device on every sealed delivery. The account key was
    /// the right one while that name was missing: a confirmation that cannot name itself would
    /// never release a device-keyed gate, and sends to that peer would deadlock. That is still
    /// the rule for a delivery that names nothing — `markConfirmed` with no device settles the
    /// account — and it is now the exception rather than the shape.
    private func releaseConfirmGate(_ peer: PeerAddress, acknowledged: Bool = true) {
        assertMainThread()
        let userId = peer.account
        if acknowledged {
            // A confirmation that names no device settles the whole account. That is the valve,
            // not a shortcut: a `session_ready` arriving unsealed, or from a client older than the
            // sender certificate, cannot say which ratchet it is about, and a gate nothing can
            // release is a conversation that stops sending for the length of the window.
            let devices = peer.device.map { [$0] } ?? SessionAddressing.deviceIds(ofPeer: userId)
            for device in devices {
                // Cancels the `open_confirm:` alarm the announcement armed.
                if let actions = try? CryptoManager.shared.handleOrchestratorEvent(
                    .peerAcked(contactId: device),
                    tag: "peer_acked"
                ) {
                    SessionActionExecutor.shared.executeOffRouter(actions, site: "peer_acked")
                }
            }
        }
        sendSessionQueuedMessages(for: userId)
        // The incoming half — what the gate held — is the core's to release, and it comes back
        // with the answer to whichever event lowered the gate (`MessageRouter.performHeldReleases`).
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
    private func emitHandshakeControls(_ transition: SessionReducer.HandshakeTransition, to peer: PeerAddress) async {
        for op in SessionReducer.controlsToEmit(on: transition) {
            switch op {
            case .resetInit: await sendSessionResetInit(to: peer)
            case .ready:     await sendSessionReady(to: peer)
            case .ping:      await sendSessionPing(to: peer)
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
    ///
    /// `peer.device` is the device whose ratchet this control speaks for. Named, the control is
    /// encrypted on that device's session, sealed to that device's key — which is what routes it
    /// (`SealedInner.recipient_device` is derived from the sealing key) — and its session checks
    /// are about that ratchet. Unnamed, everything resolves to the pinned device as before.
    ///
    /// Why it has to be named: the RESPONDER walk opens a ratchet with **one** device of the
    /// account, and `session_ready` is the INITIATOR's only proof that it did. Addressed to the
    /// account it was encrypted on the pinned device's ratchet and sealed to the pinned device's
    /// key, so after a re-init from the peer's *other* device the ready went to the wrong device
    /// on a ratchet it did not hold, the initiator's watchdog never heard back, and it re-sent
    /// its SESSION_RESET_INIT every tick — four inits on the stand for one reset, 2026-09-21.
    private func sendSessionControlCore(
        codecOp: SessionControlCodec.Op,
        contentType: Shared_Proto_Core_V1_ContentType,
        to peer: PeerAddress,
        maxAttempts: Int,
        logTag: String,
        onExhaustion: (() async -> Void)? = nil
    ) async {
        let userId = peer.account
        // The session this control is about. A device id passes through the seam unchanged; an
        // account resolves to the pinned device, exactly as every call here did before.
        guard let sessionOwner = peer.deviceOrPinned(),
              CryptoManager.shared.hasSession(for: sessionOwner) else {
            Log.info("SESSION_STATE[\(logTag)_skip]: no session for \(peer)", category: "SessionInit")
            return
        }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }

        // ping (25) / ready (26) hide their type in KNST byte 5, inside the ciphertext, and tell
        // the server nothing. SESSION_RESET_INIT (24) cannot: it is wire-identical to an ordinary
        // X3DH carrier, so the receiver must know before it decrypts. That is the only handshake
        // type left on `SealedInner`.
        let frameType = SessionControlCodec.frameContentType(for: codecOp)
        let wireContentType: Shared_Proto_Core_V1_ContentType = frameType == nil ? contentType : .unspecified
        // The sealed envelope declares strictly less than the identified one: anything that is not
        // one of the two pre-decryption exceptions collapses to `.generic`, i.e. to no field at all.
        let sealedType = SealedEnvelopeType(declaring: wireContentType)

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
        let announcedEpoch = CryptoManager.shared.sessionEpoch(for: sessionOwner)

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                let stillLive = CryptoManager.shared.hasSession(for: sessionOwner)
                guard SessionReducer.shouldContinueControlRetry(
                    announced: announcedEpoch,
                    current: CryptoManager.shared.sessionEpoch(for: sessionOwner),
                    hasSession: stillLive
                ) else {
                    let why = stillLive ? "replaced" : "gone"
                    Log.info("SESSION_STATE[\(logTag)_superseded]: session for \(peer) is \(why) between attempts — abandoning at \(attempt)/\(maxAttempts) rather than announcing a session that no longer exists", category: "SessionInit")
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
                    toDevice: sessionOwner,
                    frameAs: frameType
                )

                // Stealth: seal the control envelope exactly like a message body.
                // Fail-closed: under stealth-on we NEVER emit an identified control send — that
                // is the server-observable session-graph leak the sealed path exists to close
                // (decisions/sealed-sender-session-control-channel.md). A blocked send just
                // fails this attempt; the tie-break watchdog re-drives the handshake.
                if StealthPolicy.shared.shouldUseSealedSender() {
                    let ctx = viewContext ?? PersistenceController.shared.container.viewContext
                    // The device's key, so the seal names the device (`SealedInner.recipient_device`
                    // is derived from it) and only that device can open it.
                    guard let recipientIK = StealthSenderService.recipientIdentityKey(recipientId: sessionOwner, context: ctx) else {
                        throw StealthDowngradeBlocked(reason: "no recipient identity key for \(logTag) → \(peer)")
                    }
                    let sealedInner = try await StealthSenderService.buildSealedInner(
                        recipientUserId: userId,
                        recipientIdentityKey: recipientIK,
                        encryptedPayload: encryptedPayload,
                        contentType: sealedType
                    )
                    _ = try await StealthSendRecovery.sendSealed(sealedInner, rebuild: { afterCredentialRejection in
                        try await StealthSenderService.buildSealedInner(
                            recipientUserId: userId,
                            recipientIdentityKey: recipientIK,
                            encryptedPayload: encryptedPayload,
                            contentType: sealedType,
                            afterCredentialRejection: afterCredentialRejection
                        )
                    }, send: { inner in
                        try await MessagingServiceClient.shared.sendMessage(
                            messageId: msgId,
                            recipientId: userId,
                            senderId: myId,
                            conversationId: convId,
                            encryptedPayload: encryptedPayload,
                            timestamp: ts,
                            sealing: .sealed(inner)
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
                        // Unsealed, the device rides on the envelope instead of the seal.
                        recipientDeviceId: peer.device,
                        contentType: wireContentType,
                        sealing: .identified(.stealthDisabled)
                    )
                }
                Log.info("SESSION_STATE[\(logTag)_sent]: to \(peer) (attempt \(attempt))", category: "SessionInit")
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
    private func sendSessionResetInit(to peer: PeerAddress) async {
        let userId = peer.account
        await sendSessionControlCore(
            codecOp: .resetInit, contentType: .sessionResetInit, to: peer,
            maxAttempts: pingMaxAttempts, logTag: "sri"
        ) { [weak self] in
            guard let self else { return }
            Log.info("SESSION_STATE[sri_fallback]: SESSION_RESET_INIT exhausted, falling back to two-step for \(userId.prefix(8))…", category: "SessionInit")
            // The raw client, not `self.sendEndSession`, and deliberately: the legacy two-step is
            // teardown-then-reinit, and the ping below rebuilds what we just condemned — archiving
            // locally in between would destroy the session that ping is about to replace. Only the
            // addressing changes here: one send per device instead of one at the account, which
            // reached every device's queue.
            for device in SessionAddressing.deviceIds(
                ofPeer: userId, in: PersistenceController.shared.container.viewContext
            ) {
                do {
                    _ = try await MessagingServiceClient.shared.sendEndSession(toDevice: device, reason: "sri_fallback")
                } catch {
                    Log.error("SESSION_STATE[sri_fallback_end_session_failed]: \(error.localizedDescription) for \(device.prefix(8))…", category: "SessionInit")
                }
            }
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            await self.sendSessionPing(to: peer)
        }
    }

    /// Legacy tie-break ping (superseded by SESSION_RESET_INIT; survives only in the SRI fallback).
    /// Dual-send: typed `.sessionPing` for new consumers, `.e2EeSignal` + magic string otherwise.
    private func sendSessionPing(to peer: PeerAddress) async {
        await sendSessionControlCore(
            codecOp: .ping,
            contentType: .unspecified,  // the ping's type is in the frame; the wire says nothing
            to: peer, maxAttempts: pingMaxAttempts, logTag: "tie_break_ping"
        )
    }

    /// RESPONDER → INITIATOR ack after a successful `initReceivingSession` (phase 2 of the two-phase
    /// handshake): lets the INITIATOR cancel its watchdog and flush. Single attempt (no retry).
    /// Dual-send: typed `.sessionReady` for new consumers, `.e2EeSignal` + magic string otherwise.
    private func sendSessionReady(to peer: PeerAddress) async {
        await sendSessionControlCore(
            codecOp: .ready,
            contentType: .unspecified,  // the ready's type is in the frame; the wire says nothing
            to: peer, maxAttempts: 1, logTag: "session_ready"
        )
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
        case .reaction:
            // A reaction is metadata, not a transcript row. Do not persist empty plaintext
            // the way `.edit` currently falls through — that would be a blank bubble.
            Log.info("Session-init carrier is a reaction — not persisting as a chat row", category: "SessionCoordinator")
            return
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
            in: context
        ) {
            return
        }

        // Session-handshake ops additionally drive this coordinator's own queues, so they are
        // re-read here after the router has had its turn. Frame first, envelope second, for the
        // reason above. The watchdogs they used to cancel are the machine's phase; what cancels
        // them is the `releaseConfirmGate` beside each case.
        let frameOp = ChunkedMessageCodec.controlFrame(decryptedBytes)
            .flatMap { SessionControlCodec.op(forContentType: Int($0.contentType)) }
        if let op = frameOp ?? SessionControlCodec.op(forContentType: Int(messageData.contentType)) {
            let peerId = messageData.from
            switch op {
            case .resetInit:
                Log.info("SESSION_RESET_INIT payload discarded (not user-visible, content_type=24)", category: "SessionCoordinator")
                // Their own X3DH carrier. It cannot acknowledge ours — they may never have seen
                // it — but it makes ours moot: their init replaces the ratchet either way, so a
                // window still waiting on an answer to ours is waiting for one that cannot come.
                // Before the machine this site cancelled the retry and left the gate to lapse
                // 75 s later, which is the same end reached the slow way.
                releaseConfirmGate(PeerAddress(account: peerId, device: messageData.senderDeviceId))
                return
            case .ping:
                Log.info("SESSION_STATE[ping_received]: session established as RESPONDER (ping discarded, content_type=25)", category: "SessionCoordinator")
                // A RESPONDER session now exists. If we were also waiting on our own
                // INITIATOR session_ready, that confirmation will never arrive (the peer is the
                // INITIATOR here) — release the stale pending flag and flush both buffers
                // so sends stop deadlocking on a session_ready that won't come.
                releaseConfirmGate(PeerAddress(account: peerId, device: messageData.senderDeviceId))
                return
            case .ready:
                Log.info("SESSION_STATE[session_ready_received]: RESPONDER \(peerId.prefix(8))… confirmed (content_type=26)", category: "SessionCoordinator")
                markActive(.forAccount(peerId))
                releaseConfirmGate(PeerAddress(account: peerId, device: messageData.senderDeviceId))
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
            // See the typed case above: their carrier makes ours moot.
            releaseConfirmGate(PeerAddress(account: messageData.from, device: messageData.senderDeviceId))
            return
        }

        // Silently discard session establishment pings — they are sent after a tie-break win
        // purely to trigger RESPONDER session init on the peer and must not appear in chat.
        // Format: "__session_ping_<UUID>__" (legacy: "__session_ping__").
        if plaintext.hasPrefix("__session_ping") && plaintext.hasSuffix("__") {
            Log.info("SESSION_STATE[ping_received]: session established as RESPONDER (ping discarded)", category: "SessionCoordinator")
            // See the typed-ping case above: a RESPONDER session exists, so release any stale
            // INITIATOR-pending buffer instead of waiting for a session_ready that won't arrive.
            releaseConfirmGate(PeerAddress(account: messageData.from, device: messageData.senderDeviceId))
            return
        }

        // Phase 2 of two-phase handshake: RESPONDER sends __session_ready__ after its
        // initReceivingSession succeeds. We are the INITIATOR receiving confirmation.
        // Also handle legacy format without __ markers (older client versions).
        if plaintext.hasPrefix("__session_ready") || plaintext.hasPrefix("session_ready_") {
            let peerId = messageData.from
            Log.info("SESSION_STATE[session_ready_received]: RESPONDER \(peerId.prefix(8))… confirmed — session established both sides", category: "SessionCoordinator")
            markActive(.forAccount(peerId))
            // The same release as the typed twin above. This site used to drop the gate and flush
            // only the outgoing side, leaving held incoming carriers behind — the two flushes are
            // one call precisely so they cannot drift apart again.
            releaseConfirmGate(PeerAddress(account: peerId, device: messageData.senderDeviceId))
            return
        }

        // Canonical row id: sender's E2E id from the KNST header when present (see
        // MessageRouter.saveMessage — the server reassigns envelope ids on the sealed path).
        let canonicalId = (e2eMessageId ?? messageData.id).lowercased()
        let fetchRequest = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id ==[c] %@", canonicalId)
        fetchRequest.fetchLimit = 1

        if let existing = try? context.fetch(fetchRequest).first {
            var changed = false
            if let serverOrderKey = messageData.serverOrderKey,
               existing.serverOrderKey != serverOrderKey {
                existing.serverOrderKey = serverOrderKey
                changed = true
            }
            if existing.fromUserId == messageData.from, !existing.hasDecryptedContent {
                existing.applyStoredEncryption(plaintext: plaintext, contactId: messageData.from)
                changed = true
            }
            if changed {
                context.saveAndLog()
            }
            return
        }

        let message = Message(context: context)
        message.id = canonicalId
        message.fromUserId = messageData.from
        message.toUserId = messageData.to
        message.timestamp = Date.fromRemoteTimestamp(messageData.timestamp)
        message.serverOrderKey = messageData.serverOrderKey
            ?? ServerMessageOrder.local(timestamp: message.timestamp, messageId: canonicalId)
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
