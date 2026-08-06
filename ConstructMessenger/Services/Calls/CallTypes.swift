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

/// What an SDP offer means for a call we are already tracking.
enum RemoteOfferDisposition: Equatable {
    /// The call is under way — this is the peer renegotiating (ICE restart, re-offer). Apply it;
    /// asking for consent again would drop a live call.
    case renegotiate
    /// An incoming call nobody has answered. Hold the SDP. Consent is what starts negotiation.
    case holdUntilAnswered
}

/// Whether an offer for a known call may be negotiated immediately, or must wait for the user.
///
/// `callOfferDisposition` above answers this correctly — and was reachable only when no `ActiveCall`
/// existed yet. When one did, `handleCallSignalProto` went to `handleRemoteOffer` instead: a third
/// implementation of "apply the offer and answer" that negotiates, marks `answeredAt`, and sets the
/// call `.active`, with no consent and without telling CallKit. Which of the two ran came down to a
/// race — whether the VoIP push (call id, fast) beat the E2EE offer (SDP, slow). The push usually
/// wins, so the usual path was the unguarded one. Build 583, 2026-08-06:
///
///     13:52:06  Incoming VoIP push — CallKit notified
///     13:52:06  WebRTC session created (role=callee)  ← negotiating already
///     13:52:06  Answer (proto) sent via E2EE          ← and answered, unasked
///     13:52:09  peerConnectionState → connected
///     13:52:13  CallKit answer                        ← the user accepts, seven seconds later
///     13:52:13  "Answered before the offer arrived — waiting up to 45s for SDP"
///     13:52:22  Call end                              ← never worked
///
/// Two consequences. The visible one: CallKit still offers accept/decline while the app's own UI
/// shows a running timer, because `state = .active` came from media, not from the user. The one that
/// killed the call: `handleRemoteOffer` consumes the offer without touching
/// `pendingRemoteOfferSdp`, so the real answer found it empty and armed a 45-second wait for an SDP
/// that had been applied and answered seven seconds earlier.
///
/// The same shape as the rest of this class of defect: two carriers for "the offer has been
/// applied", disagreeing in silence. `applyOfferAndAnswer` was written to be the single authority
/// and says so in its own comment — this is the implementation that was left behind it.
///
/// A renegotiation is *not* a consent question: the call is already up, and holding an ICE-restart
/// offer would strand a call the user is in the middle of.
func remoteOfferDisposition(isIncomingCall: Bool, hasAnswered: Bool) -> RemoteOfferDisposition {
    guard isIncomingCall, !hasAnswered else { return .renegotiate }
    return .holdUntilAnswered
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
