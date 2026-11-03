//
//  SessionControlCodec.swift
//  Construct Messenger
//
//  Single byte-sniff seam for session-handshake control signals.
//

import Foundation
import SwiftProtobuf

/// Names the session-control content types (21, 24, 25, 26) and reads a typed `SessionControl`
/// payload. Nothing sends any of them since 2026-09-27; they are recognised only so a message
/// from an older build is acknowledged and dropped (`RetiredSessionControl`).
///
/// See `decisions/binary-control-message-format.md`.
enum SessionControlCodec {

    typealias Op = Shared_Proto_Messaging_V1_SessionOp

    /// Map an Envelope `content_type` to the control op it represents (typed producers).
    /// Returns nil for non-control content types.
    static func op(forContentType contentType: Int) -> Op? {
        switch Shared_Proto_Core_V1_ContentType(rawValue: contentType) ?? .UNRECOGNIZED(contentType) {
        case .sessionPing:      return .ping
        case .sessionReady:     return .ready
        case .sessionResetInit: return .resetInit
        case .sessionReset:     return .end     // END_SESSION
        default:                return nil
        }
    }

    /// The content type an op puts in KNST byte 5, or nil when the op must stay readable
    /// *before* decryption and therefore keeps its hint on `SealedInner`.
    ///
    /// ping / ready are pure post-decrypt signals: nothing acts on them until the payload is
    /// open, so the server never needs to know. END_SESSION (21) has no ciphertext to hide a
    /// frame in, and SESSION_RESET_INIT (24) is wire-identical to an ordinary X3DH carrier —
    /// framing either would make it unroutable. See
    /// decisions/sealed-content-type-inside-the-plaintext-frame.md.
    static func frameContentType(for op: Op) -> UInt8? {
        switch op {
        case .ping:  return Shared_Proto_Core_V1_ContentType.sessionPing.byte
        case .ready: return Shared_Proto_Core_V1_ContentType.sessionReady.byte
        default:     return nil
        }
    }

    // Removed on 2026-08-03, once the frame became the only carrier of the type:
    //   • `legacyOp(plaintext:)` / `legacyOp(plaintextData:)` — sniffed `__session_ping…` and
    //     friends out of decrypted text. A second way to answer "what is this message", disagreeing
    //     with `contentType` in silence. Nothing produces those strings any more.
    //   • `isBinaryInitSentinel` — a discard-only marker for a UTF-8 decode failure that the
    //     binary pipeline cannot produce.
    //   • `isLegacyControlPlaintext` — the union of the two plus the END_SESSION marker.
    // A control signal is now identified by KNST byte 5 and nothing else.


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

    /// Build the encrypted inner payload for an outgoing control signal (producer half):
    /// a serialized `SessionControl{op, nonce}`. Consumers dispatch on the type — KNST byte 5 for
    /// ping/ready, `SealedInner.content_type` for the two that must be read before decryption —
    /// and open this payload only for `nonce`.
    ///
    /// The `binarySessionControlPayload` escape hatch and its `legacyString` wire form went with
    /// the string parser on 2026-08-03. Keeping a producer whose output no consumer understands is
    /// worse than having no escape hatch: the flag looked like a way back and was a way to make
    /// every handshake unreadable.
    ///
    /// See `decisions/binary-control-message-format.md`.
    static func encodePayload(op: Op, nonce: String) -> Data {
        var control = Shared_Proto_Messaging_V1_SessionControl()
        control.op = op
        control.nonce = nonce
        return (try? control.serializedData()) ?? Data()
    }
}
