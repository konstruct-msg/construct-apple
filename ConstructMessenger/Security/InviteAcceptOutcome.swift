//
//  InviteAcceptOutcome.swift
//  Construct Messenger
//
//  Created 2026-08-16.
//
//  What the server said when it refused an `AcceptInvite`, as something the UI can act on.
//
//  The incident: revoking a link works — the server pre-burns the `jti` and refuses the
//  redeemer — but the person holding the link was shown
//
//      "Could not verify invite: The operation couldn’t be completed. (GRPCCore.RPCError error 1.)"
//
//  That string carries nothing. `error 1` is not a gRPC status: it is the code Swift gives
//  any struct bridged to `NSError`, so it is the same digit for every failure there will
//  ever be. Meanwhile the server had answered `invalidArgument: "Failed to accept invite:
//  Invite already used"` — the answer existed, was correct, and was thrown away one frame
//  above the label. The two states a person needs to tell apart — this link is dead, ask
//  for another / we never reached the server, try again — rendered identically.
//
//  So this type exists to make the server's answer survive the trip to the screen.
//

import Foundation
import GRPCCore

/// The verdict on a redeemed invite, once the server has been heard from.
enum InviteAcceptOutcome: Equatable {
    /// The `jti` is burned: redeemed by someone already, or revoked by the issuer.
    ///
    /// One case, not two, and deliberately: the server pre-burns on revoke precisely so a
    /// revoked link is indistinguishable from a spent one. Telling the redeemer which it
    /// was would leak that the issuer changed their mind about them.
    case alreadyUsed

    /// Past its TTL. The signature was fine; the clock was not.
    case expired

    /// The signature did not verify server-side, over the canonical string the server
    /// rebuilt. Practically always a truncated or edited link.
    case badSignature

    /// The server refused and named a reason we do not model. Carries the reason verbatim
    /// so the screen shows the server's words rather than a shrug.
    case refused(String)

    /// No verdict was reached — the call did not complete. The invite may be perfectly
    /// good, so the copy must not tell anyone to ask for a new one.
    case unreachable(String)
}

enum InviteAcceptClassification {

    /// Everything below is matched against the *message*, because the server does not yet
    /// put a typed code on the wire for these — `identity-service/src/main.rs` collapses
    /// every `accept_invite` failure into `Status::invalid_argument(format!("Failed to
    /// accept invite: {}", e))`, where `e` is the `thiserror` Display string.
    ///
    /// Matching prose is fragile and is not the intended end state: server spec item 5
    /// gives `AcceptInvite` the typed `error_code()` the HTTP path has carried all along
    /// (`INVITE_ALREADY_USED`, …). `classify` reads the typed code first and falls back to
    /// prose, so the day the server deploys, this file needs no change — only the prose
    /// arm becomes dead and can go.
    private enum ServerPhrase {
        static let alreadyUsed = "Invite already used"
        static let expired = "Invite expired"
        static let badSignature = "Invalid invite signature"
    }

    /// Typed codes, as `AppError::error_code()` spells them server-side.
    private enum ServerCode {
        static let alreadyUsed = "INVITE_ALREADY_USED"
        static let expired = "INVITE_EXPIRED"
        static let badSignature = "INVITE_INVALID_SIGNATURE"
    }

    /// Classify a gRPC failure from `AcceptInvite`.
    ///
    /// Pure over `(code, message)` rather than over `Error` so the whole table is reachable
    /// from a test without a server, a channel, or a network condition to reproduce.
    static func outcome(code: RPCError.Code, message: String) -> InviteAcceptOutcome {
        if message.contains(ServerCode.alreadyUsed) || message.contains(ServerPhrase.alreadyUsed) {
            return .alreadyUsed
        }
        if message.contains(ServerCode.expired) || message.contains(ServerPhrase.expired) {
            return .expired
        }
        if message.contains(ServerCode.badSignature) || message.contains(ServerPhrase.badSignature) {
            return .badSignature
        }

        // No verdict was reached about the invite itself. `unavailable` and `deadlineExceeded`
        // are the transport giving up; `internal` and `unknown` are the server falling over.
        // All four leave the invite's state unknown, and the copy must not claim otherwise.
        switch code {
        case .unavailable, .deadlineExceeded, .internalError, .unknown, .cancelled, .aborted:
            return .unreachable(describe(code: code, message: message))
        default:
            return .refused(describe(code: code, message: message))
        }
    }

    /// Convenience over an arbitrary `Error`, for the call site that has one.
    ///
    /// A non-`RPCError` is `unreachable`, never `refused`: if the failure did not come back
    /// as a gRPC status, the server never rendered a verdict on this invite.
    static func outcome(from error: Error) -> InviteAcceptOutcome {
        guard let rpc = error as? RPCError else {
            return .unreachable(error.localizedDescription)
        }
        return outcome(code: rpc.code, message: rpc.message)
    }

    /// The status as a human can read it — the substitute for the bridged `NSError`
    /// description, which names neither the code nor the message.
    static func describe(code: RPCError.Code, message: String) -> String {
        message.isEmpty ? "\(code)" : "\(code): \(message)"
    }
}
