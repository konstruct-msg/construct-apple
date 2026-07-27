//
//  SessionControlCodec.swift
//  Construct Messenger
//
//  Single byte-sniff seam for session-handshake control signals.
//

import Foundation
import SwiftProtobuf

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
    /// Does **not** map `__binary_init_*` sentinels (those are discard-only, not a real op).
    static func legacyOp(plaintext: String) -> Op? {
        if plaintext.hasPrefix("__session_ping") { return .ping }
        if plaintext.hasPrefix("__session_ready") || plaintext.hasPrefix("session_ready_") { return .ready }
        if plaintext.hasPrefix("__session_reset_init") || plaintext.hasPrefix("session_reset_init_") { return .resetInit }
        return nil
    }

    // MARK: - Binary prefix match (E8 — sniff control without full-string work)

    /// ASCII magic prefixes for legacy control plaintext (matched on raw `Data`).
    private static let pingPrefix = Data("__session_ping".utf8)
    private static let readyPrefix = Data("__session_ready".utf8)
    private static let readyLegacyPrefix = Data("session_ready_".utf8)
    private static let resetInitPrefix = Data("__session_reset_init".utf8)
    private static let resetInitLegacyPrefix = Data("session_reset_init_".utf8)
    private static let binaryInitPrefix = Data("__binary_init_".utf8)
    private static let endSessionMarker = Data("__END_SESSION__".utf8)

    /// Detect legacy control op from decrypted **bytes** without allocating a String.
    /// Prefer this on receive paths that still hold `Data` (pre-reassembler / raw).
    static func legacyOp(plaintextData data: Data) -> Op? {
        if data.starts(with: pingPrefix) { return .ping }
        if data.starts(with: readyPrefix) || data.starts(with: readyLegacyPrefix) { return .ready }
        if data.starts(with: resetInitPrefix) || data.starts(with: resetInitLegacyPrefix) { return .resetInit }
        return nil
    }

    /// True when plaintext is the magic END_SESSION marker (or starts with it).
    static func isEndSessionMarker(_ data: Data) -> Bool {
        data == endSessionMarker || data.starts(with: endSessionMarker)
    }

    /// Discard-only legacy sentinel (failed UTF-8 decode of msgNum=0 init payload).
    static func isBinaryInitSentinel(_ data: Data) -> Bool {
        data.starts(with: binaryInitPrefix)
    }

    static func isBinaryInitSentinel(_ plaintext: String) -> Bool {
        plaintext.hasPrefix("__binary_init_")
    }

    /// True when decrypted bytes are known control / sentinel magic, not chat text.
    static func isLegacyControlPlaintext(_ data: Data) -> Bool {
        legacyOp(plaintextData: data) != nil
            || isEndSessionMarker(data)
            || isBinaryInitSentinel(data)
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
    /// S3 / default since 2026-07-17 (`binarySessionControlPayload` ON): a serialized
    /// `SessionControl{op, nonce}` — the magic string is dropped from the wire; consumers dispatch
    /// on the typed `content_type` and read the payload only for `nonce`. The string parser
    /// (`legacyOp`) stays as a consumer fallback, so string-producing peers are still understood.
    ///
    /// S2 fallback (`binarySessionControlPayload` explicitly OFF): the legacy magic string, for
    /// the case an ancient pre-S1 peer (no `content_type` dispatch) resurfaces. In S2 dual-send
    /// the typed signal still rides in the Envelope `content_type` (gated by `typedSessionControl`,
    /// default ON).
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
