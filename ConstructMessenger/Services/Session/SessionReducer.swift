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

    /// Whether a received END_SESSION pre-dates our established session and should be discarded.
    ///
    /// Known limitation (Phase 3 target): `establishedAt` is in-memory only today, so it is `nil`
    /// right after launch — and this returns `false` (cannot filter), which lets a re-delivered
    /// old END_SESSION reset a healthy session. Persisting establishment time fixes that; until
    /// then this is the decision device logs are instrumented around.
    static func isEndSessionStale(establishedAt: UInt64?, timestamp: UInt64, fudgeSeconds: UInt64) -> Bool {
        guard let establishedAt else { return false }
        return timestamp + fudgeSeconds < establishedAt
    }
}
