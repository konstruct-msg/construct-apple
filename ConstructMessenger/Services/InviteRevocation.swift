//
//  InviteRevocation.swift
//  Construct Messenger
//
//  Created 2026-08-16.
//
//  Killing an invite before anyone redeems it.
//
//  `RevokeInvite` has worked server-side since the invite system shipped and iOS never
//  called it. It pre-burns the `jti` through the same row that makes an invite one-time,
//  with a retention derived to outlive the invite it kills, so a revoked invite cannot come
//  back when the record expires. The contract is pinned in
//  construct-docs backend/INVITE_LIST_REVOKE_SERVER_SPEC.md §2.
//
//  Links only, for now. A QR sitting holds up to `ttlSeconds / qrRotateIntervalSeconds`
//  capabilities — 1440 at the current 12 h TTL — and the honest version of a button behind
//  that is 1440 requests. The fix is §4 of the same spec: give the QR its own, much shorter
//  TTL so a sitting holds ten codes instead of fourteen hundred. Until that lands the button
//  is not offered rather than offered and slow.
//

import Foundation

/// What we learned by asking the server to burn a `jti`.
///
/// The distinction between the last case and the other two is the entire point. "The server
/// said no" and "we never got an answer" are both non-success, and collapsing them tells the
/// user a live capability is dead — which is worse than an error, because an error makes
/// them look again and a false "revoked" makes them stop.
enum InviteRevokeOutcome: Equatable {
    /// The burn row was written. Nobody can redeem this invite now.
    case revoked
    /// The server refused because the `jti` was already burned — redeemed by someone, or
    /// revoked earlier. A normal answer, not a failure: the invite is not outstanding.
    case alreadyUsed
    /// No answer we can act on: transport failure, or `Status::internal`. The invite may
    /// still be perfectly good, and must keep being shown as such.
    case unconfirmed
}

enum InviteRevocationDecision {

    /// Whether the screen offers a revoke action for this act.
    static func canRevoke(kind: InviteIssuance.Kind) -> Bool {
        switch kind {
        case .link:      return true
        case .qrSession: return false
        }
    }

    /// Whether the act stops being outstanding.
    ///
    /// An unconfirmed attempt must leave the row exactly where it was. Dropping it would
    /// state, in the only place the user can check, that a capability which may still work
    /// is gone.
    static func removesFromJournal(_ outcome: InviteRevokeOutcome) -> Bool {
        switch outcome {
        case .revoked, .alreadyUsed: return true
        case .unconfirmed:           return false
        }
    }

    /// One verdict for an act made of several capabilities.
    ///
    /// Any single unconfirmed burn poisons the whole answer: an act is only dead when every
    /// one of its codes is known dead, and claiming otherwise is the same lie as above at a
    /// larger scale. `alreadyUsed` and `revoked` both mean "this one cannot be redeemed", so
    /// a mixture of them is a success — the act as a whole is no longer outstanding.
    static func combine(_ outcomes: [InviteRevokeOutcome]) -> InviteRevokeOutcome {
        // Nothing asked is nothing confirmed. An empty act reaching here is a bug upstream,
        // and answering `.revoked` for it would remove a row on the strength of no evidence.
        guard !outcomes.isEmpty else { return .unconfirmed }
        if outcomes.contains(.unconfirmed) { return .unconfirmed }
        if outcomes.allSatisfy({ $0 == .alreadyUsed }) { return .alreadyUsed }
        return .revoked
    }
}

/// Asks the server to burn every live capability in an act.
@MainActor
enum InviteRevocation {

    static func revoke(_ act: InviteIssuance, now: Date = Date()) async -> InviteRevokeOutcome {
        var outcomes: [InviteRevokeOutcome] = []
        for mint in act.liveMints(at: now) {
            outcomes.append(await revokeOne(jti: mint.jti))
        }
        return InviteRevocationDecision.combine(outcomes)
    }

    private static func revokeOne(jti: String) async -> InviteRevokeOutcome {
        do {
            // `success: false` is the server reporting that the burn row already existed.
            // It is an answer, so it is not an error path.
            return try await InviteServiceClient.shared.revokeInvite(jti: jti)
                ? .revoked
                : .alreadyUsed
        } catch {
            Log.error("InviteRevocation: revoke failed for jti=\(jti.prefix(8))…: \(error)",
                      category: "Invite")
            return .unconfirmed
        }
    }
}
