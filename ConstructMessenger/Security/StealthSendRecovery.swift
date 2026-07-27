//
//  StealthSendRecovery.swift
//  Construct Messenger
//
//  One-shot recovery for sealed sends rejected by Privacy Pass enforcement.
//
//  Under MSG_STEALTH_TOKEN_POLICY=enforce the server rejects a sealed message whose
//  token fails redemption with FAILED_PRECONDITION "privacy_pass:{label}"
//  (messaging-service TokenRejected; labels: missing_token / invalid_token /
//  double_spent / decrypt_failed / redis_error / not_configured). The correct client
//  reaction is: force a wallet replenish (the rejection proves any cooldown stale),
//  rebuild the SealedInner — fresh token + fresh delivery tag; the Double-Ratchet
//  payload is reused, the ratchet does NOT advance — and retry the sealed path once.
//
//  INVARIANT (decisions/sealed-sender-anti-abuse-economics.md): NEVER downgrade to an
//  identified send on this rejection. If the server could force identified sends by
//  rejecting tokens, it could deanonymize any sender on demand — the rejection must
//  only ever cost anti-abuse budget or fail the send visibly, never anonymity.
//

import Foundation
import GRPCCore

/// Thrown when stealth is on but a message could not be sealed (no recipient identity key, or the
/// sender certificate is unavailable). The send MUST NOT fall back to an identified send — that is
/// the server-influence deanonymisation vector the sealed path exists to prevent
/// (decisions/sealed-sender-anti-abuse-economics.md). Callers hold the message queued and retry once
/// sealing becomes possible.
struct StealthDowngradeBlocked: Error {
    let reason: String
}

enum StealthSendRecovery {

    /// True when the error is the server's Privacy Pass enforce rejection.
    /// Sealed sends are unary RPCs, so the contract surface is RPCError only
    /// (the message stream carries no sealed envelopes — heartbeats and ACKs only).
    static func isPrivacyPassRejection(_ error: Error) -> Bool {
        rejectionLabel(error) != nil
    }

    /// The server-side rejection reason ("missing_token", "double_spent", …),
    /// or nil when the error is not a Privacy Pass rejection.
    static func rejectionLabel(_ error: Error) -> String? {
        guard let rpc = error as? RPCError,
              rpc.code == .failedPrecondition,
              rpc.message.hasPrefix("privacy_pass:") else { return nil }
        return String(rpc.message.dropFirst("privacy_pass:".count))
    }

    /// Run `send` with the given SealedInner; on enforce rejection replenish the wallet
    /// (bypassing cooldown), rebuild via `rebuild`, and retry exactly once. Any other
    /// error — and a second rejection — propagates to the caller's normal failure path.
    /// `rebuild` returning nil (e.g. identity key no longer available) rethrows the
    /// original rejection instead of retrying — never falls back to identified.
    static func sendSealed<R>(
        _ sealedInner: Data,
        rebuild: () async throws -> Data?,
        send: (Data) async throws -> R
    ) async throws -> R {
        do {
            return try await send(sealedInner)
        } catch {
            guard let label = rejectionLabel(error) else { throw error }
            Log.info("Stealth: sealed send rejected by enforce (\(label)) — replenishing and retrying once", category: "Stealth")
            PerformanceMetrics.shared.record(.stealthEnforceRejected, label: label)
            await BlindTokenService.shared.forceReplenish()
            guard let freshInner = try await rebuild() else { throw error }
            return try await send(freshInner)
        }
    }
}
