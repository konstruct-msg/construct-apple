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

    /// Content types that participate in the sealed round-trip invariant tests.
    /// Exhaustive over control kinds that ride inside SealedInner under stealth.
    static var sealedControlContentTypes: [UInt8] {
        [
            21, // sessionReset / END_SESSION
            24, // sessionResetInit
            25, // sessionPing
            26, // sessionReady
            12, // callSignal
            14, // deliveryReceipt
            1,  // e2EeSignal (regular body — baseline)
        ]
    }
}
