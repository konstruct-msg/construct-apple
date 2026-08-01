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
}
