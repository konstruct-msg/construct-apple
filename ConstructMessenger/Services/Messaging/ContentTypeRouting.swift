//
//  ContentTypeRouting.swift
//  Construct Messenger
//
//  Single source of truth for mapping post-unseal `contentType` → routing kind.
//  Sealed sender masks the outer envelope type; after resolveSender the real
//  type lives only in SealedInner.contentType. All early-exit routing predicates
//  must agree with this mapping — see SEALED_CONTROL_CHANNEL_REMEDIATION.md.
//

import Foundation

/// Early-exit routing kind for control carriers. Derived from `contentType` after unseal
/// (or from an identified outer envelope at ingest). Never treat a free-form string as
/// authoritative on its own once a sealed delivery has been unsealed.
enum WireMessageKind: String, Codable, Equatable, CaseIterable {
    case direct = "DIRECT_MESSAGE"
    case endSession = "CONTROL_MESSAGE"
    case senderSync = "SENDER_SYNC"
    case sessionResetInit = "SESSION_RESET_INIT"

    /// Liveness probe for a session that has been silent. Not a `WireMessageKind` case: it is
    /// never a routing *kind* — the receiver discards it — and it has no counterpart on the outer
    /// envelope any more, so there is nothing for `kind(for:)` to map. Named here because two
    /// files need the same byte and neither should spell it `13`.
    static let heartbeatContentType: UInt8 = 13

    /// Canonical proto content-type byte for this kind (0 = regular / non-control).
    var canonicalContentType: UInt8 {
        switch self {
        case .direct:            return 0
        case .endSession:        return 21  // CONTENT_TYPE_SESSION_RESET
        case .senderSync:        return 23  // CONTENT_TYPE_SENDER_SYNC
        case .sessionResetInit:  return 24  // CONTENT_TYPE_SESSION_RESET_INIT
        }
    }
}

/// Everything a sealed envelope is allowed to declare in `SealedInner.content_type` — the whole set.
///
/// That field is server-visible: `SealedInner` is a plaintext proto the relay parses. So every type
/// that moved into KNST byte 5 must leave it at `.generic`, which maps to `UNSPECIFIED` = 0 — proto3
/// omits a zero enum, so the field is *absent* from the wire rather than present and vague.
///
/// This is a closed type rather than a `Shared_Proto_Core_V1_ContentType` argument because the
/// argument allowed two spellings of "generic" to coexist: call signals, receipts and session pings
/// passed `.unspecified`, message bodies and retries passed `.e2EeSignal`. Both route as `.direct`
/// on receipt (`kind(for:)` defaults there), so nothing ever failed — but on the wire one is absent
/// and the other present, and that difference told the server, on every sealed send, whether the
/// envelope was conversation or control. Found 2026-08-17 by asking why a value meaning "nothing"
/// had two forms.
enum SealedEnvelopeType: CaseIterable {
    /// Everything whose real type rides in KNST byte 5: message bodies, delivery receipts, call
    /// signals, heartbeat, session ping/ready.
    case generic
    /// 21 — carries no ciphertext to hide a frame in.
    case sessionReset
    /// 24 — wire-identical to an ordinary X3DH carrier; the receiver must know before it decrypts.
    case sessionResetInit

    var proto: Shared_Proto_Core_V1_ContentType {
        switch self {
        case .generic:          return .unspecified
        case .sessionReset:     return .sessionReset
        case .sessionResetInit: return .sessionResetInit
        }
    }

    /// Narrow a wire content type to what a sealed envelope may declare.
    ///
    /// Anything but the two structural exceptions collapses to `.generic`, deliberately: a content
    /// type added later stays off the sealed wire by default, rather than appearing on it because
    /// nobody remembered this boundary existed.
    init(declaring contentType: Shared_Proto_Core_V1_ContentType) {
        switch contentType {
        case .sessionReset:     self = .sessionReset
        case .sessionResetInit: self = .sessionResetInit
        default:                self = .generic
        }
    }
}

/// Named mapping used at the unseal boundary and by ingest parsers.
/// Phase-1 hotfix + Phase-2 sole classifier — do not duplicate these cases inline.
enum ContentTypeRouting {

    /// Derive routing kind from an authoritative `contentType` (post-unseal or identified outer).
    static func kind(for contentType: UInt8) -> WireMessageKind {
        switch contentType {
        case 21: return .endSession
        case 23: return .senderSync
        case 24: return .sessionResetInit
        default: return .direct
        }
    }

    static func kind(for contentType: Shared_Proto_Core_V1_ContentType) -> WireMessageKind {
        kind(for: UInt8(clamping: contentType.rawValue))
    }

    // Removed with `ChatMessage.messageType` on 2026-08-02:
    //   • `messageType(for:) -> String` (both overloads) — a String form of the kind is the same
    //     duplicate in another shape; for logging use `kind(for:).rawValue` at the call site so
    //     the derivation stays visible.
    //   • `kind(fromLegacyMessageType:)` — the only caller was a Codable compat read for rows
    //     persisted before `contentType` existed. The app has never shipped, so no such rows do.
    // The content type has exactly one representation now: the byte.

    /// Control / signal content types that must never fall through to
    /// "handleEvent produced no routing decision" as a silent INFO.
    /// Includes session-control ops plus late-routed signal types (call, receipt).
    static func isKnownControlContentType(_ contentType: UInt8) -> Bool {
        if SessionControlCodec.op(forContentType: Int(contentType)) != nil { return true }
        switch contentType {
        case 12, 14, 23: return true  // callSignal, deliveryReceipt, senderSync
        default: return false
        }
    }

    /// Content types that still ride on `SealedInner.content_type` under stealth.
    ///
    /// Narrowed on 2026-08-03 to the two that genuinely cannot be moved: END_SESSION carries no
    /// ciphertext to hide a frame in, and SESSION_RESET_INIT is wire-identical to an ordinary
    /// X3DH carrier — both must be recognised *before* decryption. Call signal (12), delivery
    /// receipt (14) and ping/ready (25/26) now carry their type in KNST byte 5, inside the
    /// ciphertext, so the server can no longer distinguish them.
    /// See decisions/sealed-content-type-inside-the-plaintext-frame.md.
    ///
    /// `1` (e2EeSignal) was listed here as the "regular body baseline" until 2026-08-17. It was not
    /// a baseline: it was one of two values a generic sealed send could carry, and the server could
    /// read the difference. The baseline is now the field's absence — see `SealedEnvelopeType`.
    static var sealedControlContentTypes: [UInt8] {
        [
            21, // sessionReset / END_SESSION
            24, // sessionResetInit
        ]
    }
}
