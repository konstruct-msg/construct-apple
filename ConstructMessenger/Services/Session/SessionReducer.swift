//
//  SessionReducer.swift
//  Construct Messenger
//
//  Phase 1 / 1.5 of SESSION_COORDINATOR_REFACTOR_SPEC: the pure, deterministic core of
//  the per-contact session state machine, extracted out of SessionCoordinator's ad-hoc
//  `ContactSessionState` dictionary + the queue disposition that lived inline in
//  MessageRouter.handleFirstMessage.
//
//  Mirrors the proven TransportReducer pattern: side-effect-free functions that return
//  the next state plus a list of effects an effector performs. The reducer NEVER does I/O —
//  no crypto, no gRPC, no Keychain, no Task scheduling, no Date(). All time is injected.
//
//  Two concerns, kept separate on purpose:
//   • `reduce` — the session *phase* lifecycle (initializing / active). SessionCoordinator
//     owns the phase and performs the resulting queue effects.
//   • `incomingDisposition` — the *queue disposition* for an incoming message, a pure
//     decision fed by the authoritative facts MessageRouter holds (Rust session existence +
//     whether init is already underway). It is stateless: the `.initializing` transition
//     stays owned by the init executor (handlePublicKeyBundleNeeded), so it never trips
//     that executor's reentrancy guard.
//
//  Because the logic is pure, it is exercised directly by SessionRaceConditionTests —
//  the tests drive these production functions, not a parallel reimplementation.
//

import Foundation

enum SessionReducer {

    /// Lifecycle phase of the session with a single peer. Absence of an entry (`nil`)
    /// means *no session and none in flight* — the implicit `.absent` state.
    enum Phase: Equatable {
        /// A session init / heal / key-sync is in flight for this peer.
        case initializing
        /// A session is established. `establishedAt` is Unix seconds (injected, not read here).
        case active(establishedAt: UInt64)
    }

    /// Phase-lifecycle inputs. These map 1:1 onto the calls SessionCoordinator makes today
    /// (`beginInit`, the closure it returns, `markActive`) plus the success/failure/teardown
    /// transitions that drive the pending-queue drain/clear effects.
    enum Event: Equatable {
        /// An init/heal/key-sync was started (prewarm, KEY_SYNC, heal, fallback, first message).
        case initStarted
        /// The init scope ended (mirrors the closure returned by `beginInit`). Clears the
        /// `.initializing` marker, but only if still initializing — never clobbers `.active`
        /// set by a success path that ran inside the same init scope.
        case initEnded
        /// Session init/heal completed successfully at the given Unix-seconds timestamp.
        case initSucceeded(at: UInt64)
        /// Session init/heal failed terminally.
        case initFailed
        /// END_SESSION was received / the session was torn down.
        case endSessionReceived
        /// Mark the session active at the given timestamp without draining the queue
        /// (used where establishment is confirmed out-of-band, e.g. RESPONDER `session_ready`,
        /// or a heal that intentionally does not reset establishment time).
        case markActive(at: UInt64)
    }

    /// Side effects the effector performs. The reducer only *names* them.
    enum Effect: Equatable {
        /// Begin session initialisation (fetch bundle + init) for this peer.
        case startInit
        /// Buffer the incoming message until the session is ready.
        case queueMessage
        /// Process the incoming message immediately (session already active).
        case processMessage
        /// Drain and process every buffered message for this peer.
        case drainQueuedMessages
        /// Discard every buffered message for this peer (no orphans).
        case clearQueuedMessages
    }

    /// Phase-lifecycle transition. Pure: `(phase, event) -> (phase', effects)`.
    ///
    /// - Parameters:
    ///   - phase: current phase for the peer, or `nil` for the implicit `.absent` state.
    ///   - event: the input.
    /// - Returns: the next phase (`nil` == absent) and the ordered effects to perform.
    static func reduce(_ phase: Phase?, on event: Event) -> (Phase?, [Effect]) {
        switch event {

        case .initStarted:
            return (.initializing, [])

        case .initEnded:
            // Only clear the marker if still initializing; never clobber an .active set
            // by a success path that completed inside the same init scope.
            if case .initializing = phase { return (nil, []) }
            return (phase, [])

        case .initSucceeded(let at):
            return (.active(establishedAt: at), [.drainQueuedMessages])

        case .initFailed:
            return (nil, [.clearQueuedMessages])

        case .endSessionReceived:
            return (nil, [.clearQueuedMessages])

        case .markActive(let at):
            return (.active(establishedAt: at), [])
        }
    }

    /// Pure disposition for an incoming message, fed by the authoritative facts MessageRouter
    /// holds. Stateless on purpose (no phase mutation) so it can never trip the init
    /// executor's reentrancy guard.
    ///
    /// - Parameters:
    ///   - hasActiveSession: a decryptable DR session exists in the Rust core right now.
    ///   - isInitInFlight: init for this peer is already underway (a message is already queued).
    /// - Returns: the effects to perform — exactly one of: process now / queue only /
    ///   start init + queue.
    static func incomingDisposition(hasActiveSession: Bool, isInitInFlight: Bool) -> [Effect] {
        if hasActiveSession { return [.processMessage] }
        if isInitInFlight  { return [.queueMessage] }
        return [.startInit, .queueMessage]
    }

    /// Decide whether to proactively prewarm a session with a peer.
    ///
    /// Regression guard for the prewarm-vs-restore race (see
    /// `2026-06-16-prewarm-restore-race`): while the crypto core is **not ready**, every
    /// peer reads as "no session" — prewarming in that window sends a destructive
    /// END_SESSION + fresh re-init over a healthy, not-yet-restored session, discarding the
    /// ratchet and breaking the peer's in-flight messages. So: never prewarm unless the core
    /// is ready; then only where we are the natural INITIATOR and no session exists or can be
    /// restored from Keychain.
    static func shouldPrewarm(coreReady: Bool, isNaturalInitiator: Bool, sessionExistsOrRestorable: Bool) -> Bool {
        guard coreReady else { return false }
        return isNaturalInitiator && !sessionExistsOrRestorable
    }

    /// Per-peer END_SESSION rate limit. Returns true iff enough time has elapsed since the
    /// last send (or none was ever sent) to send again.
    ///
    /// Cooldown is intentionally NOT a `Phase` variant: it coexists with `.active` /
    /// `.initializing` (a peer can have a live session AND be in END_SESSION cooldown), so it
    /// is a separate decision rather than a mutually-exclusive state. This is the single
    /// authority storm-prone END_SESSION paths consult so repeats can't ping-pong.
    static func shouldSendEndSession(lastSentAt: Date?, now: Date, cooldown: TimeInterval) -> Bool {
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= cooldown
    }

    /// Whether the local teardown that follows a sent END_SESSION still applies to the session we
    /// condemned, identified by its `SessionEpoch`.
    ///
    /// The teardown runs *after* a network round-trip, and `archiveSession` destroys whatever
    /// session exists at that moment — not necessarily the one the caller decided to end. If a
    /// heal or an incoming carrier established a new session inside that window, tearing it down
    /// throws away a healthy ratchet and, because `clearArchivedSessions` follows, leaves no
    /// archive to recover from. Observed 2026-08-02: a RESPONDER init completed with the PQ
    /// contribution applied and 462 B persisted, and was destroyed under a second later by an
    /// END_SESSION issued before it existed; flights of 3 s were seen on the mobile path.
    ///
    /// A differing epoch on either side means "not the same session", including the
    /// already-torn-down case (`current == nil`) — there the archive belongs to whoever tore it
    /// down, and this call has no claim on it.
    ///
    /// Until 2026-08-05 the identity here was `establishedAt`, whole seconds, so a condemned
    /// session and its replacement established inside the same second read as identical and the
    /// teardown proceeded anyway. `SessionEpoch` closes that residual: it descends from the
    /// handshake, not from the clock, so a replacement is a different epoch however fast it arrives.
    static func shouldTearDownAfterEndSession(condemned: SessionEpoch?, current: SessionEpoch?) -> Bool {
        condemned == current
    }

    /// What to do about END_SESSION after a RESPONDER `initReceivingSession` failure — the single
    /// authority for the grace/otpk/plain branch that used to be nested inline `if`s in
    /// `SessionCoordinator`. Cooldown is still applied separately by `shouldSendEndSession` at the
    /// send site; this only chooses the *branch*.
    enum InitFailureAction: Equatable {
        /// Plain AEAD fail right after we *received* END_SESSION — usually a stale-wire race.
        /// Do not amplify the reset storm; wait for the peer's SRI / next msg0 (responder
        /// fallback still covers a stuck INITIATOR).
        case suppressWithinGrace
        /// Peer used a 4-DH OTPK we cannot reproduce → send a typed END_SESSION carrying
        /// `.otpkUnreproducible` so they re-init WITHOUT one (3-DH is always reproducible,
        /// breaking the 4-DH retry loop). Bypasses the inbound grace — the hint must reach them.
        case sendTypedOtpk
        /// Plain init failure outside the inbound-END_SESSION grace → ordinary rate-limited
        /// END_SESSION so the peer re-inits.
        case sendPlain
    }

    static func initFailureAction(
        otpkUnreproducible: Bool,
        withinInboundGrace: Bool
    ) -> InitFailureAction {
        if otpkUnreproducible { return .sendTypedOtpk }
        if withinInboundGrace { return .suppressWithinGrace }
        return .sendPlain
    }

    /// What to do when an END_SESSION is *received* from a peer — the single branch authority for
    /// `SessionCoordinator.messageRouter(_:receivedEndSession:)`.
    enum EndSessionReceiptAction: Equatable {
        /// We are the natural RESPONDER (lower userId): don't re-init, wait for the INITIATOR's
        /// fresh X3DH (responder fallback covers a stuck INITIATOR).
        case waitAsResponder
        /// We are the natural INITIATOR but a debounced re-init is already pending — a server
        /// backlog flush delivers several END_SESSIONs at once; one pending re-init per peer is
        /// enough (each extra one destroyed the session the previous just created → storm).
        case coalesce
        /// We are the natural INITIATOR with no pending re-init: schedule the debounced re-init.
        case scheduleReinit
    }

    static func endSessionReceiptAction(
        isNaturalInitiator: Bool,
        hasPendingReinit: Bool
    ) -> EndSessionReceiptAction {
        guard isNaturalInitiator else { return .waitAsResponder }
        return hasPendingReinit ? .coalesce : .scheduleReinit
    }

    /// After the END_SESSION re-init debounce elapses: only proceed if no session exists yet.
    /// A session present NOW was established *after* the END_SESSION (typically the peer's fresh
    /// init from the same stream flush made us RESPONDER); re-initing over it would destroy a
    /// working session and re-open the desync it just closed.
    static func endSessionReinitStillNeeded(hasSession: Bool) -> Bool { !hasSession }

    /// Receive-side control-message coalesce. Server offline queues re-deliver batches of
    /// END_SESSION / SESSION_RESET_INIT for the same peer; acting on each one re-archives
    /// Keychain + requeues + reopens streams. After the first handled control message in a
    /// window, further ones for that peer should only be ACK'd.
    static func shouldHandleInboundControl(
        lastHandledAt: Date?,
        now: Date,
        cooldown: TimeInterval
    ) -> Bool {
        guard let lastHandledAt else { return true }
        return now.timeIntervalSince(lastHandledAt) >= cooldown
    }

    // MARK: - Tie-break role (the single Swift authority)

    /// Role in a concurrent-init tie-break.
    enum Role: Equatable { case initiator, responder }

    /// Deterministic tie-break role, **matching the Rust core byte-for-byte**
    /// (`construct-core` `message_router.rs::tie_break_role`): plain string comparison of the two
    /// `ServerUserId`s, **higher id = INITIATOR**. Both peers compute this independently over the
    /// same pair, so any disagreement means both-initiator / both-responder → permanent deadlock.
    /// This is why it must be one authority and must not normalise (lowercasing here would diverge
    /// from Rust). For canonical lowercase dashed UUIDs, string order == UUID-byte order, so this
    /// supersedes the old `DeviceIdOrdering` UUID-byte compare (which diverged from Rust only on
    /// non-canonical / mixed-case ids — a latent fragility, now removed).
    ///
    /// - Note: operands are `ServerUserId`s (36-char UUID), **not** `CryptoDeviceId`s — the old
    ///   "deviceId" naming was a misnomer; the AD and the Rust rule both key on userId.
    static func tieBreakRole(myId: String, peerId: String) -> Role {
        myId > peerId ? .initiator : .responder
    }

    /// Whether we are the natural INITIATOR (higher userId) for this peer — the proactive-prewarm
    /// and responder-fallback predicate. Equal ids (self / echo) are not an initiator.
    static func isNaturalInitiator(myId: String, peerId: String) -> Bool {
        myId != peerId && tieBreakRole(myId: myId, peerId: peerId) == .initiator
    }

    // MARK: - Confirmation gate (INITIATOR awaiting RESPONDER session_ready)

    /// A handshake control op, modelled dependency-free (the proto `SessionControlOp` maps 1:1).
    /// Kept local so the reducer stays pure — no proto/gRPC imports.
    enum ControlOp: Equatable {
        case resetInit  // ct24 — X3DH carrier for a session reset
        case ping       // ct25 — "I am now a RESPONDER for you"
        case ready      // ct26 — "my RESPONDER session is confirmed"
        case endSession // teardown
        case other
    }

    /// The INITIATOR (tie-break winner) buffers outgoing and holds the peer's msgNum=0 while
    /// awaiting the RESPONDER's `session_ready`. This gate is a **hint, never a permanent lock**:
    /// it self-releases after `confirmWindow` so a lost SESSION_RESET_INIT / lost ping / lost
    /// session_ready can't deadlock (the class fixed piecemeal in `3f166e61` + `04f16211`, now a
    /// single tested decision `SessionConfirmationTracker` delegates to).
    ///
    /// - Returns: true iff a pending mark exists AND the confirm window has not elapsed — i.e.
    ///   outgoing should still buffer and the peer's msgNum=0 should still be held
    ///   (`MessageRouter.holdUntilConfirmResolves`, replayed when the gate falls).
    static func isConfirmBuffering(pendingSince: Date?, now: Date, confirmWindow: TimeInterval) -> Bool {
        guard let pendingSince else { return false }
        return now.timeIntervalSince(pendingSince) < confirmWindow
    }

    /// What the tie-break confirm gate does with an *incoming* message.
    enum ConfirmGateAction: Equatable {
        /// Route normally.
        case route
        /// Buffer until the gate resolves, then replay (`MessageRouter.replayHeldMessages`).
        case hold
    }

    /// The gate's disposition for one incoming message — the single authority for both points at
    /// which the question is asked: before decryption (a peer msgNum=0) and after it (the core
    /// answered `sendEndSession`).
    ///
    /// Both must **hold**, never discard. Inside our own confirm window we are the side that
    /// replaced the session, so a peer init that cannot be read and a decrypt failure are both
    /// consequences of our own re-init, not evidence about the peer. Answering either with a
    /// discard cost a user message on 2026-08-04: the peer's live init was marked processed (so
    /// the server never redelivered it) and the message that followed it one second later tore the
    /// session down and went with it.
    ///
    /// Control carriers are exempt. END_SESSION and SESSION_RESET_INIT are what drives the
    /// convergence the gate is waiting for — holding them would make the gate wait on itself.
    static func confirmGateAction(
        isPending: Bool,
        isControlCarrier: Bool,
        isPeerInit: Bool,
        decryptFailed: Bool
    ) -> ConfirmGateAction {
        guard isPending, !isControlCarrier else { return .route }
        return (isPeerInit || decryptFailed) ? .hold : .route
    }

    /// Whether a handshake-control retry may still speak for the session it was created to
    /// announce. Sibling of `shouldTearDownAfterEndSession`, and the same defect: a decision made
    /// before a network round-trip, applied after one, against whatever session exists by then.
    ///
    /// Observed 2026-08-04: SESSION_RESET_INIT attempts 1-2 failed on `StealthDowngradeBlocked`,
    /// the peer's own SRI arrived in the gap and made us the RESPONDER on a new session, and
    /// attempt 3 announced a session that had been gone for a second. The peer answered by tearing
    /// down a healthy ratchet.
    ///
    /// `hasSession` is kept alongside the epoch rather than folded into it: `current == nil` also
    /// covers "the core is not ready", and abandoning a retry because the core was mid-restore
    /// would be a different decision than abandoning it because the session is gone.
    static func shouldContinueControlRetry(announced: SessionEpoch?, current: SessionEpoch?, hasSession: Bool) -> Bool {
        guard hasSession else { return false }
        return announced == current
    }

    /// What to do with a message the confirm gate held, at the moment the gate comes down.
    enum HeldReplayDisposition: Equatable {
        /// Still meaningful against the session we have now.
        case replay
        /// Belongs to a peer session that a later handshake replaced. Acknowledge and drop.
        case superseded
    }

    /// §1c applied to the confirm gate's own buffer: **a held message must carry the identity of
    /// the session it was held against.**
    ///
    /// The 2026-08-05 build-579 log is the third instance of this shape and the first one I wrote
    /// myself. The gate correctly held peer inits instead of discarding them (§1d) — but the replay
    /// was unconditional, so when the 75s window lapsed we re-routed inits belonging to peer
    /// sessions that a *later* handshake had already replaced. The stale one cannot decrypt, the
    /// core answers `heal`, and healing does `manual_reset`: the healthy session established
    /// seconds earlier is archived and deleted. Three times in one hour, each followed by
    /// "the encrypted session with this contact is out of sync" on screen:
    ///
    ///     15:23:27  confirm_replay: re-routing 2 held message(s)
    ///     15:23:27  heal_triggered: becoming RESPONDER
    ///     15:23:27  Archiving session … reason: manual_reset      ← a 60-second-old good session
    ///
    /// Only a peer *init* is dropped. A payload (`messageNumber > 0`) is replayed whatever its
    /// age: dropping user content on a guess is the failure §1d exists to prevent, and a payload
    /// that cannot decrypt is a question for the healing path, not for this one.
    static func heldReplayDisposition(
        heldAgainst: SessionEpoch?,
        current: SessionEpoch?,
        isPeerInit: Bool
    ) -> HeldReplayDisposition {
        guard isPeerInit else { return .replay }
        // No session now: nothing has superseded it, and it may be the very handshake that
        // establishes one.
        guard current != nil else { return .replay }
        // Any other epoch than the one it was held against — including "held while we had no
        // session, and one exists now" — means a handshake concluded in the meantime and this init
        // is a step of it. Equality, not ordering: epochs are identities, and the timestamps this
        // replaced could not tell a replacement inside the same second from the original.
        return heldAgainst == current ? .replay : .superseded
    }

    // MARK: - Handshake control emission (the send-side authority)

    /// A handshake transition that emits control message(s) to the peer.
    enum HandshakeTransition: Equatable {
        /// We kept the INITIATOR session after a tie-break win → announce it so the loser can
        /// atomically become RESPONDER.
        case tieBreakWin
        /// We just established the RESPONDER session (`initReceivingSession` ok) → acknowledge so
        /// the INITIATOR cancels its watchdog and flushes.
        case becameResponder
    }

    /// Which control op(s) to emit on a handshake transition — the single authority for the
    /// handshake's *send* side (the *receive* side is `confirmReleases` + the transition table in
    /// SESSION_COORDINATOR_REFACTOR_SPEC §"Confirm protocol"). INITIATOR announces via
    /// SESSION_RESET_INIT; RESPONDER acknowledges via session_ready. `.ping` is **not** in the
    /// canonical set — it survives only as the SRI two-step fallback (a legacy trigger), so it is
    /// emitted by that fallback directly, not prescribed here.
    static func controlsToEmit(on transition: HandshakeTransition) -> [ControlOp] {
        switch transition {
        case .tieBreakWin:     return [.resetInit]
        case .becameResponder: return [.ready]
        }
    }

    // MARK: - OTPK-unreproducible recovery (the 3-DH loop-breaker)

    /// DH mode for a session init. 4-DH mixes a one-time prekey (OTPK) into X3DH; 3-DH omits it.
    enum DHMode: Equatable { case fourDH, threeDH }

    /// The DH mode for the *next* INITIATOR init. Normally 4-DH; but when a force-3-DH hint is
    /// pending — the peer, as our RESPONDER, told us via END_SESSION(`.otpkUnreproducible`) that it
    /// could not reproduce the 4-DH one-time-prekey our last X3DH used — the recovery init MUST drop
    /// the OTPK and use 3-DH. **This is the loop-breaker:** re-fetching another OTPK (4-DH) would
    /// hand the responder yet another key it also cannot back, looping forever; 3-DH derives from
    /// identity + signed prekey only, which the responder can always reproduce. The hint is consumed
    /// once (a later clean init uses 4-DH again). See `SessionReinitHintStore` / L2 of the
    /// otpk-session-init-deadlock fix.
    static func nextInitDHMode(forceThreeDHHintPending: Bool) -> DHMode {
        forceThreeDHHintPending ? .threeDH : .fourDH
    }

    /// Responder-fallback override gate — the mirror of the tie-break watchdog. The two are the
    /// role-split halves of one liveness guarantee ("a stalled handshake gets re-driven by
    /// *someone*"): the INITIATOR re-sends SRI (`tieBreakWatchdogTick`); the natural RESPONDER, if
    /// the INITIATOR stays silent past the fallback timeout, **overrides** the tie-break and takes
    /// the INITIATOR role itself. They are mutually exclusive by role, so they never dueling-init.
    ///
    /// Override iff, when the fallback fires, there is still no session and none in flight — i.e. the
    /// INITIATOR never showed up. If either is true the handshake already progressed; stand down.
    static func shouldResponderOverride(hasSession: Bool, isInitializing: Bool) -> Bool {
        !hasSession && !isInitializing
    }

    /// What the tie-break watchdog should do on a tick.
    enum WatchdogTick: Equatable {
        /// Re-send SESSION_RESET_INIT — still within the confirm window, RESPONDER hasn't acked.
        case retry
        /// The confirm window has lapsed — stop retrying, release the gate, flush the buffer.
        case giveUp
    }

    /// Tie-break watchdog policy: after the INITIATOR sends SESSION_RESET_INIT it waits for the
    /// RESPONDER's ack (ready/ping); if none comes it re-sends the SRI — but only while still within
    /// the confirm window (`isConfirmBuffering`). This makes the watchdog **re-arming and bounded**;
    /// it was previously single-shot (one retry at 30 s, then silence forever — the confirm-deadlock
    /// root, patched piecemeal in `04f16211`). Folding the retry lifetime onto the confirm window
    /// keeps the two liveness mechanisms coherent: they give up together, and give-up proactively
    /// releases the gate + flushes instead of waiting for a lazy TTL read / the next reconnect.
    static func tieBreakWatchdogTick(pendingSince: Date?, now: Date, confirmWindow: TimeInterval) -> WatchdogTick {
        isConfirmBuffering(pendingSince: pendingSince, now: now, confirmWindow: confirmWindow) ? .retry : .giveUp
    }

    /// Does receiving this control op release the confirm gate (RESPONDER acknowledged)?
    /// PING and READY both prove a bidirectional session exists (see the transition table in
    /// SESSION_COORDINATOR_REFACTOR_SPEC §"Confirm protocol"); RESET_INIT only cancels the
    /// watchdog, it is not itself an acknowledgement.
    static func confirmReleases(on op: ControlOp) -> Bool {
        op == .ping || op == .ready
    }

    /// Whether a received END_SESSION pre-dates our established session and should be discarded.
    ///
    /// `establishedAt` is now persisted per-peer in the Keychain (see
    /// `SessionCoordinator.apply` / `KeychainManager.saveSessionEstablishedAt`) and restored on
    /// launch, so this can filter a re-delivered old END_SESSION even right after a cold start —
    /// the case that used to tear down a healthy restored session and trigger SESSION_RESET_INIT
    /// churn. `nil` only remains for sessions established by a build predating that persistence
    /// (one-time gap, resolved on their next re-establishment); there this returns `false`.
    static func isEndSessionStale(establishedAt: UInt64?, timestamp: UInt64, fudgeSeconds: UInt64) -> Bool {
        guard let establishedAt else { return false }
        return timestamp + fudgeSeconds < establishedAt
    }

    /// Whether a received SESSION_RESET_INIT is *superseded* by our current session and should be
    /// coalesced (ACK-only), versus applied (archive old session + RESPONDER re-init).
    ///
    /// This is the SESSION_RESET_INIT sibling of `isEndSessionStale`, and it is deliberately a
    /// *distinct* predicate, not a reuse — the two control types must NOT be filtered identically:
    ///
    /// - `END_SESSION` carries no ratchet material, so a re-delivered one is idempotent; filtering
    ///   is purely "is it older than my session?".
    /// - `SESSION_RESET_INIT` carries a fresh X3DH init (new ephemeral + one-time prekey). A *newer*
    ///   one is a live re-init the INITIATOR made after our current session was built (tie-break
    ///   re-announce / dr-diverge / watchdog), so it MUST be applied **even while a session is
    ///   active** — the INITIATOR has ratcheted onto the new session and its next `msgNum≥1` will
    ///   only decrypt against it. Dropping it (as the old blanket 45s inbound-control time-window
    ///   did) strands the RESPONDER on a dead ratchet → AEAD-fail → DR-diverge → END_SESSION storm
    ///   (the 2026-07-26 two-device desync).
    ///
    /// So we coalesce ONLY inits that pre-date or exactly match the current establishment (a server
    /// backlog replay re-delivered on reconnect): boundary is `<=` (an exact redelivery of the
    /// establishing init is idempotent → coalesce), and the fudge errs toward *applying* (a
    /// near-boundary init is applied, never stranding — a redundant re-init is cheap and
    /// self-limiting, a dropped live init is a permanent storm). `nil` establishment → apply.
    /// `alreadyApplied` — we have already acted on **this exact init**, identified by its X3DH
    /// ephemeral public key. Build 579, 15:22:04, one second apart:
    ///
    ///     ts=1785943323 established=1785943288 → fresh (apply re-init)
    ///     ts=1785943323 established=1785943288 → fresh (apply re-init)   ← the same message
    ///     No session for a7bf9efc but messageNumber=1 — requesting END_SESSION
    ///
    /// The second application archived the session the first had just rebuilt, and the payload
    /// that arrived in the gap asked the peer to start over. The predicate compared *time* where it
    /// needed *identity*, and two copies of one init carry the same time (§1c). The first remedy
    /// was `lastAppliedAt`, a second timestamp — which failed the same way, because the establishment
    /// record it raced is stamped only when the re-init completes. The ephemeral key is the init's
    /// own identity: two copies of one message carry the same key, and a genuine peer retry
    /// generates a new one, so the answer no longer depends on when anything happened.
    ///
    /// ## Why this one cannot use `SessionEpoch`
    ///
    /// The other four checks became epoch equality (`decisions/session-epoch-before-mls.md`). This
    /// one cannot, and the reason is structural rather than an omission: **the decision to apply an
    /// SRI is made before anything it carries can be decrypted.** An epoch identifies a session we
    /// have; to learn which session the *sender* is replacing we would have to read a field they
    /// sent, and the only pre-decryption surface is the envelope — where the server would see it,
    /// handing it a stable pairwise identifier for free. So the epoch cannot gate an SRI, and the
    /// ephemeral public key, already in the clear on the envelope and already unique per init, is
    /// the strongest identity available at this point.
    ///
    /// The `establishedAt` comparison therefore stays, for the one question the ephemeral key
    /// cannot answer: whether an init we have *never* applied pre-dates the session we now hold (a
    /// server backlog replay from before we re-established). There is no pre-decryption ordering
    /// primitive but the peer's clock, so this keeps its fudge, and the fudge keeps erring toward
    /// *applying* — a redundant re-init is cheap and self-limiting, a dropped live init is a
    /// permanent storm. `nil` establishment → apply.
    static func isResetInitSuperseded(
        alreadyApplied: Bool,
        establishedAt: UInt64?,
        timestamp: UInt64,
        fudgeSeconds: UInt64
    ) -> Bool {
        if alreadyApplied { return true }
        guard let establishedAt else { return false }
        return timestamp + fudgeSeconds <= establishedAt
    }
}
