//
//  SessionControlCodec.swift
//  Construct Messenger
//
//  Single byte-sniff seam for session-handshake control signals.
//

import Foundation

/// Decodes session-handshake control signals from an incoming message, recognising both
/// the typed wire form (Envelope `content_type` + `SessionControl` payload) and the legacy
/// plaintext magic strings (`__session_ping_<UUID>__`, `__session_ready_<UUID>__`,
/// `__session_reset_init_<UUID>__`). This is the consumer-first half of the migration:
/// new clients understand the opcode; old peers still send strings, so we keep the fallback.
///
/// See `decisions/binary-control-message-format.md`.
enum SessionControlCodec {

    typealias Op = Shared_Proto_Messaging_V1_SessionOp

    /// Map an Envelope `content_type` to the control op it represents (typed producers).
    /// Returns nil for non-control content types.
    static func op(forContentType contentType: Int) -> Op? {
        switch contentType {
        case 25: return .ping        // CONTENT_TYPE_SESSION_PING
        case 26: return .ready       // CONTENT_TYPE_SESSION_READY
        case 24: return .resetInit   // CONTENT_TYPE_SESSION_RESET_INIT
        case 21: return .end         // CONTENT_TYPE_SESSION_RESET (END_SESSION)
        default: return nil
        }
    }

    /// Legacy fallback: detect a control op from a decrypted plaintext magic string.
    /// Kept until the fleet has upgraded past the typed-producer phase.
    static func legacyOp(plaintext: String) -> Op? {
        if plaintext.hasPrefix("__session_ping") { return .ping }
        if plaintext.hasPrefix("__session_ready") || plaintext.hasPrefix("session_ready_") { return .ready }
        if plaintext.hasPrefix("__session_reset_init") || plaintext.hasPrefix("session_reset_init_") { return .resetInit }
        return nil
    }

    /// Parse a typed `SessionControl` payload (Phase 2+ producers). Returns nil if the bytes
    /// are not a valid SessionControl or carry an unspecified op (forward-compat: a future
    /// producer that sets only `content_type` with an empty/other payload is still dispatched
    /// by `op(forContentType:)`; this is only for reading `nonce`/extra fields).
    static func decode(_ payload: Data) -> Shared_Proto_Messaging_V1_SessionControl? {
        guard let control = try? Shared_Proto_Messaging_V1_SessionControl(serializedBytes: payload),
              control.op != .unspecified else { return nil }
        return control
    }

    // MARK: - Producer

    /// Build the encrypted inner payload for an outgoing control signal (producer half).
    ///
    /// S3 (`binarySessionControlPayload` ON, destructive): a serialized `SessionControl{op, nonce}` —
    /// the magic string is dropped; new consumers dispatch on the typed `content_type` and read the
    /// payload only for `nonce`. This breaks pre-S1 peers and must wait until the typed consumer is
    /// fleet-wide.
    ///
    /// S2 / default (`binarySessionControlPayload` OFF): the legacy magic string, so peers that
    /// predate the typed consumer dispatch (`legacyOp`) still recognise the signal. In S2 dual-send
    /// the typed signal still rides in the Envelope `content_type` (gated by `typedSessionControl`,
    /// default ON) — this is the backward-safe "binary first, string fallback" wire form.
    ///
    /// See `decisions/binary-control-message-format.md`.
    static func encodePayload(op: Op, nonce: String) -> Data {
        if FeatureFlags.binarySessionControlPayload {
            var control = Shared_Proto_Messaging_V1_SessionControl()
            control.op = op
            control.nonce = nonce
            if let data = try? control.serializedData(), !data.isEmpty {
                return data
            }
            // Serialization should never fail; fall through to the legacy form if it somehow does
            // so a control signal still goes out rather than nothing.
        }
        return Data(legacyString(op: op, nonce: nonce).utf8)
    }

    /// The legacy plaintext magic string for an op, e.g. `__session_ping_<nonce>__`. Kept as the
    /// flag-OFF wire form and matched by `legacyOp` on the consumer side.
    static func legacyString(op: Op, nonce: String) -> String {
        switch op {
        case .ping:      return "__session_ping_\(nonce)__"
        case .ready:     return "__session_ready_\(nonce)__"
        case .resetInit: return "__session_reset_init_\(nonce)__"
        default:         return "__session_\(nonce)__"
        }
    }
}
