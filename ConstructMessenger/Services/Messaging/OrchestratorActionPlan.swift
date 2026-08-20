//
//  OrchestratorActionPlan.swift
//  ConstructMessenger
//
//  What the router must do with an orchestrator action list, beyond following its routing verdict.
//
//  `handleOrchestratorEvent` returns a SET of instructions, not a single verdict, and the set's
//  size varies with the message: the core prepends `applyPqContribution` for every incoming X3DH
//  carrier (non-empty KEM ciphertext) and appends `checkAckInDb` whenever its in-memory ACK cache
//  misses. Reading that list by position or length is therefore a bug waiting for the first
//  message that carries both — which is exactly what happened: `actions.count == 1` gated the
//  `checkAckInDb` round-trip, so a carrier arriving after a restart was ACKed as delivered
//  without ever being decrypted, and the peer's next message diverged the ratchet.
//
//  Extracted so that reading is a named, testable operation rather than an inline scan.
//

import Foundation

/// The instructions `MessageRouter` fulfils itself, recovered from an orchestrator action list.
///
/// Both fields are independent: a list may carry either, both, or neither, in any order, and
/// alongside any number of actions the generic `SessionActionExecutor` handles.
struct OrchestratorActionPlan {

    /// ML-KEM ciphertext the core wants decapsulated, from `applyPqContribution`.
    ///
    /// The action field is named `kemSs`, but the core passes the CIPHERTEXT — "platform
    /// decapsulates, feeds ss back" (`orchestrator.rs`). Applying it is the caller's job and
    /// must happen after the carrier decrypts.
    let kemCiphertext: Data?

    /// Message id whose persisted ACK state the core is asking about, from `checkAckInDb`.
    ///
    /// The core buffers the message and decides decrypt-vs-drop only once Swift answers with
    /// `ackDbResult`. Failing to answer strands the message: no decrypt, no routing decision.
    let ackCheckMessageId: String?

    init(actions: [CfeAction]) {
        var kemCiphertext: Data?
        var ackCheckMessageId: String?
        for action in actions {
            switch action {
            case .applyPqContribution(_, let kemSs):
                kemCiphertext = kemSs
            case .checkAckInDb(let messageId):
                ackCheckMessageId = messageId
            default:
                break
            }
        }
        self.kemCiphertext = kemCiphertext
        self.ackCheckMessageId = ackCheckMessageId
    }

    /// The routing verdict the incoming-message loop must follow. Independent of the
    /// platform-side actions (`scheduleTimer`, `saveSessionToSecureStore`, …) that ride
    /// alongside it: those are executed, not classified.
    ///
    /// First matching action in list order wins — the same scan `MessageRouter` used to
    /// do inline. `scheduleTimer` and `healSuppressed` arriving together must yield
    /// `.healSuppressed`, not `.none`: treating that pair as "no decision" (device logs
    /// 2026-08-19) skipped the timer, advanced the cursor past an un-ACKed message, and
    /// let re-init fire without the cooldown the core had just asked for.
    static func routingVerdict(from actions: [CfeAction]) -> IncomingRoutingVerdict {
        for action in actions {
            switch action {
            case .messageDecrypted:
                return .decrypted
            case .callSignalDecrypted:
                return .callSignalDecrypted
            case .sessionHealNeeded(let contactId, let role):
                return .sessionHealNeeded(contactId: contactId, role: role)
            case .sendEndSession(let contactId):
                return .sendEndSession(contactId: contactId)
            case .fetchPublicKeyBundle(let userId):
                return .fetchPublicKeyBundle(userId: userId)
            case .endSessionSuppressed(let contactId, let retryAfterMs):
                return .endSessionSuppressed(contactId: contactId, retryAfterMs: retryAfterMs)
            case .healSuppressed(let contactId, let retryAfterMs):
                return .healSuppressed(contactId: contactId, retryAfterMs: retryAfterMs)
            case .messageQueuedPendingInit(let contactId, let queuedCount):
                return .messageQueuedPendingInit(contactId: contactId, queuedCount: queuedCount)
            default:
                continue
            }
        }
        return .none
    }
}

/// What `MessageRouter` does with an orchestrator action list after the ACK round-trip.
///
/// A non-empty list is not automatically a routing verdict: the core prepends/appends
/// platform chores (`scheduleTimer`, `applyPqContribution`, `persistAck`) around the
/// named decision. Reading those chores as "unknown" and falling through to ERROR is
/// how a cooldown the core had decided became a storm.
enum IncomingRoutingVerdict: Equatable {
    case decrypted
    case callSignalDecrypted
    case sessionHealNeeded(contactId: String, role: String)
    case sendEndSession(contactId: String)
    case fetchPublicKeyBundle(userId: String)
    case endSessionSuppressed(contactId: String, retryAfterMs: UInt64)
    case healSuppressed(contactId: String, retryAfterMs: UInt64)
    case messageQueuedPendingInit(contactId: String, queuedCount: UInt32)
    case none
}

/// What the core meant by the action list it returned from an answered `checkAckInDb`.
///
/// The round-trip has the same hazard as the list above, one level down: the core encodes a
/// *verdict* as an empty `Vec<Action>`, and an empty list also reads as "nothing came back".
/// `MessageRouter` took the second reading — `if !followup.isEmpty { actions = followup }` — so a
/// duplicate the core had definitively dropped left `actions` holding the pre-round-trip
/// `[checkAckInDb]`, and the fallthrough logged it as "no routing decision … NOT acked", naming
/// the one action it had just answered. 6296 of 6302 such log lines in the 2026-08-04 run.
///
/// Empty is overloaded three ways in `decision_to_actions` (`orchestrator.rs`): duplicate, init
/// lock held, END_SESSION cooldown. Our own answer disambiguates it exactly, because
/// `resume_after_ack_check` returns `Duplicate` on `is_processed = true` before either other
/// branch is reachable (`message_router.rs:271`) — no core change needed to tell them apart.
enum AckCheckOutcome: Equatable {

    /// The core confirmed a duplicate. Terminal and benign: the row already exists, which is how
    /// we were able to answer "processed" in the first place.
    case duplicate

    /// Empty verdict although we answered *not* processed — init lock held or END_SESSION
    /// cooldown. The message is dropped and returns only by redelivery.
    case droppedPendingRedelivery

    /// A real action list came back; routing continues with it.
    case routable

    /// - Parameters:
    ///   - followupIsEmpty: whether the core's post-answer action list was empty.
    ///   - weAnsweredProcessed: the `is_processed` value we fed back.
    static func resolve(followupIsEmpty: Bool, weAnsweredProcessed: Bool) -> AckCheckOutcome {
        guard followupIsEmpty else { return .routable }
        return weAnsweredProcessed ? .duplicate : .droppedPendingRedelivery
    }
}
