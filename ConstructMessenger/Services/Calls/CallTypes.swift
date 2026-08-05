//
//  CallTypes.swift
//  Construct Messenger
//

import Foundation

struct CallSession: Equatable {
    enum Direction: Equatable {
        case incoming
        case outgoing
    }

    let id: String
    let uuid: UUID
    let peerUserId: String
    let peerName: String
    let direction: Direction
}

enum CallEndReason: Equatable {
    case hangup(Shared_Proto_Signaling_V1_HangupReason)
    case error(Shared_Proto_Signaling_V1_SignalErrorCode)
    case local(String)
}

/// What to do with an incoming SDP offer.
///
/// The pure part of `CallManager.handleIncomingCallOffer`, split out so it can be tested: three
/// separate defects lived in this one decision on 2026-08-05, and none of them was reachable from
/// a test while it was a chain of `if let active` inside a `@MainActor` singleton wired to CallKit.
enum CallOfferDisposition: Equatable {
    /// The call is already over. Drop the offer — do not ring CallKit for it.
    case ignoreCallEnded
    /// The user already answered and `answer()` has run with nothing to apply. Attach the SDP and
    /// *finish the answer*.
    case resumeAnswer
    /// The call is ringing and unanswered. Attach the SDP for `answer()` to consume.
    case storeForAnswer
    /// Nothing matches this call id — a genuinely new incoming call.
    case reportNewCall
}

/// Decide what an arriving offer means.
///
/// "There is an incoming call" and "here is its SDP" travel on separate channels — the VoIP push
/// (fast, call id only) and the E2EE message stream (slow, carries the SDP) — and CallKit is driven
/// by the first. Every ordering of those two is reachable, and on 2026-08-05 the unhandled ones
/// cost a call each way: the offer arrived 30 s after the user answered and nothing consumed it,
/// then arrived again 8 s after the call ended and rang CallKit for a call nobody was making.
///
/// Glare (an *outgoing* call to the same peer) is deliberately not modelled here — it is resolved
/// by a userId tie-break in `handleIncomingCallOffer` and is a different question from this one.
func callOfferDisposition(
    hasRecentlyEnded: Bool,
    matchesActiveIncomingCall: Bool,
    awaitingOfferAfterAnswer: Bool
) -> CallOfferDisposition {
    if hasRecentlyEnded { return .ignoreCallEnded }
    guard matchesActiveIncomingCall else { return .reportNewCall }
    return awaitingOfferAfterAnswer ? .resumeAnswer : .storeForAnswer
}

enum CallState: Equatable {
    case idle
    case incoming(CallSession)
    case dialing(CallSession)
    case ringing(CallSession)
    case connecting(CallSession)
    case active(CallSession)
    case ended(CallSession, CallEndReason)
}

/// Coarse health signal derived from WebRTC ICE state. UI reads this without
/// importing or initializing WebRTC, which keeps SwiftUI previews lightweight.
enum CallQuality: Sendable, Equatable {
    case good
    case reconnecting
}

@MainActor
protocol CallUIManaging: AnyObject {
    var state: CallState { get }
    var lastError: String? { get }
    var callQuality: CallQuality { get }

    func clearLastError()
    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool) async
    func endCall()
    func setMuted(_ muted: Bool)
}

enum CallRuntimeProvider {
    @MainActor
    static func makeUIManager() -> (any CallUIManaging)? {
        guard CallsFeature.isEnabled else { return nil }
        return CallManager.shared
    }
}
