//
//  SessionEpoch.swift
//  Construct Messenger
//
//  The identity of a Double Ratchet session.
//

import Foundation

/// The identity of a Double Ratchet session, as the crypto core derives it.
///
/// Until 2026-08-05 a session was identified by **the wall-clock second it was established**, and
/// every question of the form *"does this still concern the session I decided about?"* was a
/// timestamp comparison with a tolerance. Five such comparisons grew independently between
/// 2026-07-02 and 2026-08-05, two of them as fixes for the other three, and both of those were
/// themselves defective within 48 hours. See `decisions/session-epoch-before-mls.md`.
///
/// The epoch already existed; it was simply never surfaced. `construct-core` derives
///
///     session_id = HKDF(salt: root_key_x3dh,
///                       ikm:  "construct-session-id",
///                       info: "Construct-SessionID-v2\0" || min(id_a, id_b) || \0 || max(id_a, id_b),
///                       len:  16)
///
/// (`crypto/messaging/double_ratchet/mod.rs`). Three properties make it the right identity:
///
/// - **Shared without a round-trip.** Both sides hold `root_key_x3dh` after X3DH and the user IDs
///   are sorted, so INITIATOR and RESPONDER derive byte-identical values. A peer's epoch for our
///   shared session *is* our epoch — which is why this works across the wire and a locally-invented
///   counter would not.
/// - **Fresh per establishment.** It descends from the X3DH root key, so a re-init is necessarily a
///   new epoch. That is exactly what the timestamp was approximating.
/// - **Unforgeable.** It is bound into the AEAD associated data of every message
///   (`version || sender_id || receiver_id || session_id(16B) || dh_pub || msg_num`), so unlike the
///   peer clock we used to order by, it cannot be lied about.
///
/// Comparison is **equality, not ordering**: two epochs are either the same session or different
/// ones. There is no "newer", no fudge factor and no clock.
///
/// > Not to be confused with the `sessionId` parameter of `encryptMessage`/`decryptMessage` at the
/// > FFI, which is a **contactId** wearing this name (the core says so itself). The real epoch
/// > surfaces only through `getSessionHealth`.
struct SessionEpoch: Equatable, Hashable {

    /// 32 hex characters — the core's own encoding, kept verbatim so nothing can re-encode it
    /// into disagreement.
    let rawValue: String

    /// `nil` for an empty identifier: a session with no epoch is not a session we can reason about,
    /// and letting `""` compare equal to `""` would make two different absences look like one
    /// shared identity.
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

extension SessionEpoch: CustomStringConvertible {
    /// Log form. The full value is not a secret (it is public associated data), but eight
    /// characters distinguish epochs at a glance and keep lines readable.
    var description: String { String(rawValue.prefix(8)) }
}

extension Optional where Wrapped == SessionEpoch {
    /// Log form for the absent case, so call sites don't each invent their own spelling of "none".
    var logDescription: String { self?.description ?? "none" }
}
