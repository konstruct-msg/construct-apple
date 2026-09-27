//
//  SessionReducer.swift
//  Construct Messenger
//
//  Phase 1 / 1.5 of SESSION_COORDINATOR_REFACTOR_SPEC: the pure, deterministic core of
//  the per-contact session state machine, extracted out of SessionCoordinator's ad-hoc
//  `ContactSessionState` dictionary + the queue disposition that lived inline in
//  MessageRouter.handleFirstMessage (removed 2026-09-26 with the queue it decided for).
//
//  Mirrors the proven TransportReducer pattern: side-effect-free functions that return
//  the next state plus a list of effects an effector performs. The reducer NEVER does I/O —
//  no crypto, no gRPC, no Keychain, no Task scheduling, no Date(). All time is injected.
//
//  `reduce` is the session *phase* lifecycle (initializing / active), owned by
//  SessionCoordinator. It used to name queue effects too (drain / clear) and a queue
//  disposition for incoming messages (`incomingDisposition`); both went on 2026-09-26 with the
//  platform's queue — messages waiting for a session wait in the core's
//  (`decisions/first-contact-queue-keyed-by-claimed-device.md`).
//
//  Because the logic is pure, it is exercised directly by SessionRaceConditionTests —
//  the tests drive these production functions, not a parallel reimplementation.
//

import Foundation

/// The core's classification rule, reachable from inside `SessionReducer`.
///
/// Needed only because of name resolution: `SessionReducer.receivingInitKind` shadows the core's
/// free function of the same base name, and Swift refuses the call rather than falling through to
/// module scope. Qualifying by module is not the fix either — the module is `Construct_Messenger`
/// on iOS and `Construct_Desktop` on macOS, and this file is compiled into both, so a hardcoded
/// module name builds on one target and breaks the other.
///
/// At file scope there is no member to shadow, so the name resolves to the core.
private func coreReceivingInitKind(_ carrier: ReceivingInitCarrier) -> ReceivingInitKind {
    receivingInitKind(carrier: carrier)
}

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
        /// Session init completed successfully at the given Unix-seconds timestamp.
        case initSucceeded(at: UInt64)
        /// Session init failed terminally.
        case initFailed
        /// END_SESSION was received / the session was torn down.
        case endSessionReceived
        /// Mark the session active at the given timestamp without draining the queue
        /// (used where establishment is known out-of-band, e.g. a session restored at launch).
        case markActive(at: UInt64)
    }

    /// Phase-lifecycle transition. Pure: `(phase, event) -> phase'`.
    ///
    /// - Parameters:
    ///   - phase: current phase for the peer, or `nil` for the implicit `.absent` state.
    ///   - event: the input.
    /// - Returns: the next phase (`nil` == absent).
    static func reduce(_ phase: Phase?, on event: Event) -> Phase? {
        switch event {

        case .initStarted:
            return .initializing

        case .initEnded:
            // Only clear the marker if still initializing; never clobber an .active set
            // by a success path that completed inside the same init scope.
            if case .initializing = phase { return nil }
            return phase

        case .initSucceeded(let at):
            return .active(establishedAt: at)

        case .initFailed, .endSessionReceived:
            return nil

        case .markActive(let at):
            return .active(establishedAt: at)
        }
    }

    /// What a message is, for the purpose of opening a receiving session: whether it carries the
    /// initiator's handshake header. Since 2026-09-27 that is the KEM ciphertext, at any message
    /// number — the first flight repeats it (`decisions/sessions-renew-by-sending.md`).
    enum ReceivingInitKind: Equatable {
        /// Carries the handshake header: this message can open a session.
        case handshake
        /// Carries none: it decrypts on a state we hold or not at all.
        case midRatchet
    }

    /// What to do with an envelope from a peer the server said does not exist.
    enum VanishedPeerAction: Equatable {
        /// Not marked, or the mark is old enough to be worth re-testing. Ordinary handling —
        /// which means a bundle fetch, whose answer is the only thing that can settle it.
        case proceed
        /// Marked and still fresh: this is more of their replayed backlog. Resolve it and move
        /// on, because no session can be built and queueing it holds the stream cursor.
        case discard
    }

    /// How long a `notFound` verdict stands before one more bundle fetch is allowed.
    ///
    /// The mark has to expire somehow, because an account can be re-registered and nothing else
    /// would ever ask again. An hour is chosen against the cost of being wrong in each direction:
    /// too long and a returning contact waits, too short and we hammer the key service — which we
    /// measured, `resourceExhausted: "Too many bundle requests"`, 2026-08-20.
    static let vanishedPeerRetryAfter: TimeInterval = 60 * 60

    /// - Parameter markedAt: when the server last answered `notFound` for this peer, or nil if
    ///   it never has.
    ///
    /// **Deliberately blind to the envelope.** The first version revived a peer on a handshake,
    /// which read plausibly and was wrong: `receivingInitKind` cannot tell a classic 3-DH
    /// handshake from a classic leftover (documented hole), and a deleted account's backlog is
    /// full of `msgNum=0` leftovers. Every one of them revived the peer, so the mark oscillated
    /// on a 20-second cycle — marked 17:45:33, cleared 17:45:53, marked 17:45:55, cleared
    /// 17:45:58 — and the cursor never moved. Only the server can say an account exists, so only
    /// the server's answer clears the mark: `KeyServiceClient` on a successful fetch, or this
    /// window lapsing and letting one fetch through to ask again.
    static func vanishedPeerAction(markedAt: Date?, now: Date = Date()) -> VanishedPeerAction {
        guard let markedAt else { return .proceed }
        return now.timeIntervalSince(markedAt) < vanishedPeerRetryAfter ? .discard : .proceed
    }

    /// Classify an incoming envelope for the receiving open.
    ///
    /// **The rule itself lives in the core** (`orchestration::receiving_init_plan`). This is a
    /// forwarder plus a type adapter, not a second implementation: two clients that classify a
    /// carrier differently do not produce an error, they produce a message that never appears.
    static func receivingInitKind(
        messageNumber: UInt32,
        oneTimePreKeyId: UInt32,
        kemCiphertextBytes: Int,
        pqMessageEpoch: UInt32
    ) -> ReceivingInitKind {
        let carrier = ReceivingInitCarrier(
            messageNumber: messageNumber,
            oneTimePrekeyId: oneTimePreKeyId,
            // The core takes a byte count, not the bytes: classifying a carrier must never require
            // holding its body.
            kemCiphertextBytes: UInt32(max(0, kemCiphertextBytes)),
            pqMessageEpoch: pqMessageEpoch
        )
        switch coreReceivingInitKind(carrier) {
        case .handshake:  return .handshake
        case .midRatchet: return .midRatchet
        }
    }

    /// Decide whether to proactively prewarm a session with a peer.
    ///
    /// Regression guard for the prewarm-vs-restore race (see
    /// `2026-06-16-prewarm-restore-race`): while the crypto core is **not ready**, every
    /// peer reads as "no session" — prewarming in that window sends a destructive
    /// END_SESSION + fresh re-init over a healthy, not-yet-restored session, discarding the
    /// ratchet and breaking the peer's in-flight messages. So: never prewarm unless the core
    /// is ready; then only where no session exists or can be restored from Keychain. It used to
    /// be the natural INITIATOR only; nothing is ranked since 2026-09-27.
    static func shouldPrewarm(coreReady: Bool, sessionExistsOrRestorable: Bool) -> Bool {
        guard coreReady else { return false }
        return !sessionExistsOrRestorable
    }

    /// Why a chat is being opened. The two differ in exactly one thing — whether whatever session
    /// state already exists is still meant to be used.
    enum ChatStartOrigin {
        /// Tapping a contact, a search result, a push. The session, if any, is the one to keep.
        case existingContact
        /// A scanned QR or an invite link was redeemed.
        case inviteRedeem
    }

    /// Whether starting a chat means retiring whatever session already exists with that peer.
    ///
    /// Redeeming an invite is a statement that the two sides are establishing a session now — it
    /// is the one place where an existing ratchet is evidence of the *past*, not of a working
    /// present. `shouldPrewarm` cannot tell those apart: it asks "does a session exist or can one
    /// be restored", and a session left over from a deleted contact answers yes.
    ///
    /// That is what happened on 2026-08-17. The peer had deleted the contact, so his side had no
    /// session; hers survived in the Keychain. The redeem restored it, `shouldPrewarm` saw a
    /// session and skipped, and her first message went out on a ratchet he had thrown away:
    ///
    ///     annie 12:11:52  Cleared all archived sessions for ffeeddc6…
    ///     annie 12:11:52  Restored session (CFE): ffeeddc6…      ← the orphan, back
    ///     annie 12:11:59  "Пупу" sent                            status=sent
    ///     Max   12:12:00  initReceivingSession failed: All 1 prekey(s) failed
    ///     annie 12:12:01  END_SESSION: skipped 1 message(s) — already accepted by server
    ///
    /// The message was never resent and never arrived, and it read as delivered to her. Note the
    /// order of the first two lines: the archives — the only thing that could have decrypted
    /// anything old — were cleared, and the one item that breaks the new session was kept.
    ///
    /// Retiring is archiving, not deleting: an in-flight message from the old session can still
    /// be read from the archive by the fallback-decrypt path.
    static func chatStartRetiresExistingSession(origin: ChatStartOrigin) -> Bool {
        origin == .inviteRedeem
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
    /// authority for the otpk/plain branch that used to be nested inline `if`s in
    /// `SessionCoordinator`. Whether the teardown may actually go out is asked separately, per
    /// device, at the send site — and it is the core's (`orchestration::session_machine`); this
    /// only chooses the *branch*, and with it the cause the send declares.
    ///
    /// There was a third case, `suppressWithinGrace`, for a plain AEAD failure right after the
    /// peer tore down — a stale-wire race that must not be answered with a teardown. It did not
    /// disappear: `.sendPlain` declares itself `Blind` at the send site, and the machine answers
    /// it with `EndSessionNotNeeded` for exactly that window. The difference is that the typed
    /// branch is no longer folded in with it.
    enum InitFailureAction: Equatable {
        /// Peer used a 4-DH OTPK we cannot reproduce → send a typed END_SESSION carrying
        /// `.otpkUnreproducible` so they re-init WITHOUT one (3-DH is always reproducible,
        /// breaking the 4-DH retry loop). Bypasses the inbound grace — the hint must reach them.
        case sendTypedOtpk
        /// Plain init failure outside the inbound-END_SESSION grace → ordinary rate-limited
        /// END_SESSION so the peer re-inits.
        case sendPlain

        /// Whether this branch has **evidence** that the peer is talking on a session we cannot
        /// read, which is what `plan_teardown` needs to turn a device we hold no session with
        /// from `.skip` into `.sendOnly`.
        ///
        /// Both sending branches have it, and for the same reason: they are only reached because
        /// a message arrived and no session could be built for it. Dropping the flag is not a
        /// smaller signal, it is silence — after a failed RESPONDER init we hold no session with
        /// *any* of the peer's devices, so every one of them plans as `.skip` and nothing is sent.
        /// Measured 2026-09-06: six rounds of `otpk_unreproducible` in four minutes, each ending
        /// `2 device(s) all skipped`, no END_SESSION on the wire, and the peer re-sending the same
        /// unreadable message throughout. The recovery request was suppressed by the very
        /// condition that made it necessary.
        ///
        /// It lives here rather than as a literal at the three send sites because this enum is
        /// already the branch authority, and a policy repeated at call sites is the shape that
        /// drifts — the otpk site and the heal-exhausted site are in different functions 300 lines
        /// apart and were already inconsistent with `session_out_of_sync`, which passes it.
        var peerOnDeadSession: Bool {
            switch self {
            case .sendTypedOtpk, .sendPlain: return true
            }
        }

        /// What this teardown **knows**, which is what the machine holds it to.
        ///
        /// Beside `peerOnDeadSession` and deliberately not derived from it: that one answers
        /// `plan_teardown` ("is there a device we hold no session with that must still be told"),
        /// this one answers the window ("may an envelope go out now"). Both are true of both
        /// branches for the first question and differ on the second, which is how one `Bool`
        /// standing for both made a blind teardown and an explained one indistinguishable.
        ///
        /// Here rather than at the send sites for the reason the neighbour gives: a policy
        /// repeated at call sites is the shape that drifts. Getting this wrong is not visible —
        /// `.blind` on the typed branch would be silently swallowed inside the peer's quiet, and
        /// the 4-DH retry loop it exists to break would simply continue.
        var cause: CfeTearDownCause {
            switch self {
            // The peer cannot work out for itself that the one-time pre-key it chose is
            // unreproducible. Silence is the loop continuing, so this is never silenced.
            case .sendTypedOtpk: return .explained
            // A plain AEAD failure right after the peer tore down is a stale-wire race, and a
            // teardown back at them repeats what they just said. This is the branch the 20 s
            // inbound grace existed for.
            case .sendPlain: return .blind
            }
        }
    }

    /// The inbound grace used to be the second line of this function, as a `Bool` the caller
    /// computed from its own 20 s map. It is the machine's now — asked per device, inside the
    /// send, as `CfeTearDownCause` — because the answer differs between the two branches left
    /// here and a `Bool` checked before the branch could not tell them apart: a plain teardown
    /// after the peer tore down repeats what they said, while the typed one carries the reason
    /// their next attempt needs. See `decisions/session-is-one-state-machine.md`, step 2.
    static func initFailureAction(otpkUnreproducible: Bool) -> InitFailureAction {
        otpkUnreproducible ? .sendTypedOtpk : .sendPlain
    }

    /// Receive-side control-message coalesce. Server offline queues re-deliver batches of
    /// END_SESSION for the same peer; acting on each one re-archives
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

    // The tie-break role, the confirmation gate, the handshake controls (SESSION_RESET_INIT,
    // ping, session_ready) and the retry that announced them lived here until 2026-09-27. A
    // session record keeps its previous states and any message with the handshake header opens,
    // so there is nothing to rank, announce or confirm (`decisions/sessions-renew-by-sending.md`).

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

    /// Whether a received END_SESSION pre-dates our established session and should be discarded.
    ///
    /// `establishedAt` is persisted per-peer (see `SessionEstablishment`) and restored on launch,
    /// so this can filter a re-delivered old END_SESSION even right after a cold start — the case
    /// that used to tear down a healthy restored session and trigger SESSION_RESET_INIT churn.
    ///
    /// The claim that `nil` "only remains for sessions established by a build predating that
    /// persistence" was wrong, and build 585 disproved it: an INITIATOR recorded nothing until the
    /// peer's `session_ready` came back, so every freshly built session was undatable for as long
    /// as confirmation took. Fixed by recording at creation; `nil` now means no session on record.
    ///
    /// **This predicate cannot settle a crossing teardown.** `timestamp` is the *peer's* clock,
    /// which is why the fudge exists, and any teardown sent within the fudge of our establishment
    /// reads as current. Build 585 lost a session built at 10:54:07 to an END_SESSION stamped
    /// 10:54:03 — four seconds, inside the five-second tolerance. Widening the fudge is not the
    /// answer (it eats genuine teardowns); naming the condemned session on the wire is.
    static func isEndSessionStale(establishedAt: UInt64?, timestamp: UInt64, fudgeSeconds: UInt64) -> Bool {
        guard let establishedAt else { return false }
        return timestamp + fudgeSeconds < establishedAt
    }
}
