//
//  OrchestratorActionPlan.swift
//  ConstructMessenger
//
//  What the router must do with an orchestrator action list, beyond following its routing verdict.
//
//  `handleOrchestratorEvent` returns a SET of instructions, not a single verdict, and the set's
//  size varies with the message: the core appends `checkAckInDb` whenever its in-memory ACK cache
//  misses, and until PQXDH v2 it also prepended `applyPqContribution` for every incoming X3DH
//  carrier. Reading that list by position or length is therefore a bug waiting for the first
//  message that carries two — which is exactly what happened: `actions.count == 1` gated the
//  `checkAckInDb` round-trip, so a carrier arriving after a restart was ACKed as delivered
//  without ever being decrypted, and the peer's next message diverged the ratchet.
//
//  Extracted so that reading is a named, testable operation rather than an inline scan.
//

import Foundation

/// The instructions `MessageRouter` fulfils itself, recovered from an orchestrator action list.
///
/// It may come in any position, alongside any number of actions the generic
/// `SessionActionExecutor` handles. (There were two until PQXDH v2: the ML-KEM ciphertext of
/// `applyPqContribution`, which the core now decapsulates itself.)
struct OrchestratorActionPlan {

    /// Message id whose persisted ACK state the core is asking about, from `checkAckInDb`.
    ///
    /// The core buffers the message and decides decrypt-vs-drop only once Swift answers with
    /// `ackDbResult`. Failing to answer strands the message: no decrypt, no routing decision.
    let ackCheckMessageId: String?

    init(actions: [CfeAction]) {
        var ackCheckMessageId: String?
        for action in actions {
            if case .checkAckInDb(let messageId) = action {
                ackCheckMessageId = messageId
            }
        }
        self.ackCheckMessageId = ackCheckMessageId
    }

    /// The routing verdict the incoming-message loop must follow. Independent of the
    /// platform-side actions (`scheduleTimer`, `saveToSecureStore`, …) that ride
    /// alongside it: those are executed, not classified.
    ///
    /// First matching action in list order wins — the same scan `MessageRouter` used to
    /// do inline. `scheduleTimer` and a suppression arriving together must yield the
    /// suppression, not `.none`: treating that pair as "no decision" (device logs
    /// 2026-08-19) skipped the timer and advanced the cursor past an un-ACKed message.
    /// The core's `DECRYPT_FAILED` code (`orchestrator.rs`), attached to every refused decrypt.
    static let decryptFailedCode = "decrypt_failed"

    static func routingVerdict(from actions: [CfeAction]) -> IncomingRoutingVerdict {
        for action in actions {
            switch action {
            case .messageDecrypted:
                return .decrypted
            case .callSignalDecrypted:
                return .callSignalDecrypted
            case .controlFrameDecrypted:
                return .controlFrameDecrypted
            case .sendDecryptionError:
                return .unreadable
            // No error to send — an unsealed message names no writer to seal it to — but the core
            // still could not read it, and says why. What the device walk tries the next session on.
            case .notifyError(let code, _) where code == Self.decryptFailedCode:
                return .unreadable
            case .openReceiving(let contactId):
                return .openReceiving(contactId: contactId)
            case .messageQueuedPendingInit(let contactId, let queuedCount):
                return .messageQueuedPendingInit(contactId: contactId, queuedCount: queuedCount)
            case .duplicateDropped(let messageId):
                return .duplicate(messageId: messageId)
            case .malformedDropped(let messageId):
                return .malformed(messageId: messageId)
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
/// platform chores (`scheduleTimer`, `persistAck`) around the
/// named decision. Reading those chores as "unknown" and falling through to ERROR is
/// how a cooldown the core had decided became a storm.
enum IncomingRoutingVerdict: Equatable {
    case decrypted
    case callSignalDecrypted
    /// A silent control frame the core named from byte 5 of its KNST frame (core 0.30).
    case controlFrameDecrypted
    /// Nothing held reads it and it carries no handshake header. The core built a DECRYPTION_ERROR
    /// to its writer when it could (a sealed message) and recorded the message; the writer resends
    /// it on the state it opens next. Replaced `sendEndSession` / `endSessionSuppressed` on
    /// 2026-09-27 (`decisions/sessions-renew-by-sending.md`).
    case unreadable
    /// A message waits for a session with `contactId` and can open one — no bundle is fetched.
    case openReceiving(contactId: String)
    case messageQueuedPendingInit(contactId: String, queuedCount: UInt32)
    /// Already handled — ACK cache, our DB, or a ratchet position whose key is used. Named by the
    /// core since 2026-09-26 (`DuplicateDropped`); before, it was an empty list that also meant
    /// "no decision", and after a DB answer of "not processed" it held the stream cursor.
    case duplicate(messageId: String)
    /// Its payload does not parse — garbage, or a suite this build no longer reads — so it can
    /// never open. Named by the core since 0.28 (`MalformedDropped`); before, only a reason
    /// came back, which is no decision: the router logged "no routing decision … NOT acked" as an
    /// ERROR and wrote no processed record (the cursor still moved past it, so it did not return).
    case malformed(messageId: String)
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
/// Empty was overloaded three ways in `decision_to_actions` (`orchestrator.rs`): duplicate, init
/// lock held, END_SESSION cooldown (gone 2026-09-27). Our own answer disambiguates it exactly, because
/// `resume_after_ack_check` returns `Duplicate` on `is_processed = true` before either other
/// branch is reachable (`message_router.rs:271`) — no core change needed to tell them apart.
enum AckCheckOutcome: Equatable {

    /// The core confirmed a duplicate. Terminal and benign: the row already exists, which is how
    /// we were able to answer "processed" in the first place.
    case duplicate

    /// Empty verdict although we answered *not* processed. No current core answers so — its
    /// causes, the init lock and the END_SESSION cooldown, now have names or are gone — and it is
    /// kept so a new empty verdict is held for redelivery rather than passing silently.
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
