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

/// Whether a stored offer SDP is something that can actually be negotiated.
///
/// Thin on purpose, and it exists because the same question was asked two different ways. Until
/// 2026-08-17 `answer()` asked `!sdp.isEmpty` while the ICE paths asked `sdp != nil`, and an empty
/// string answers those two differently: candidates buffer against an offer that is "present", and
/// the answer that would drain them arms a 45-second wait for an offer that is "absent". Build 613,
/// 2026-08-17:
///
///     Max   12:16:06  Offer (proto) sent via E2EE           ← sdp length never logged, by anyone
///     Annie 12:16:07  Incoming call via E2EE offer          ← stored
///     Annie 12:16:08  Buffered 24/24 E2EE ICE (pending SDP) ← so it is present
///     Annie 12:16:10  "Answered before the offer arrived"   ← so it is absent
///     Annie 12:16:20  Call end   state=connecting answered=false
///
/// Neither side ever applied a remote description, so ICE had nothing to check against and the
/// call died in `connecting` with both peers waiting on each other — the callee for an SDP that had
/// arrived, the caller for an answer nobody could build.
///
/// One predicate, consulted everywhere, is the fix. The empty offer that started it is refused at
/// both the send and the receive boundary; this is what keeps the two readings from parting again.
func offerSdpIsUsable(_ sdp: String?) -> Bool {
    guard let sdp else { return false }
    return !sdp.isEmpty
}

/// Whether a signal arriving on the signaling stream may be acted on.
enum SignalStreamAdmission: Equatable {
    /// The stream is the channel for this signal. Hand it to its handler.
    case accept
    /// The stream is not a channel for this signal. Drop it and say so.
    case refuseSdp
}

/// What the server-terminated signaling stream is allowed to deliver.
///
/// The stream carries presence — ringing, connected, hangup, busy, ping — plus ICE candidates,
/// which are encrypted end to end and refused by `CallSignalFrame.decode` if they are not our
/// frame. Media negotiation does not travel here: an offer or answer reaches this client only
/// through `handleCallSignalProto`, inside the Double Ratchet.
///
/// The `.offer` and `.answer` arms of `handleSignalResponse` accepted SDP from this stream until
/// 2026-08-21, and `decryptSdp` returned an unprefixed value unchanged, so an SDP arriving here
/// was applied as plaintext. No peer could reach it — signaling-service forwards no SDP in either
/// direction (`service.rs`, the Offer arm sends `IncomingCall` without the SDP and does not store
/// a pending offer; the Answer arm updates call state only). What could reach it is whatever can
/// write to the stream, and gRPC/TLS ends at the server. Applying that SDP substitutes the DTLS
/// fingerprint and the whole media path with no end-to-end check — the thing moving call
/// signalling into the encrypted channel was for.
///
/// A handler with no producer, in the direction that costs something: `AGENTS.md` states the rule
/// as "a handler no producer reaches is either wired up or deleted", and this one had been left
/// deprecated instead, which is neither.
func signalStreamAdmission(for signal: Shared_Proto_Signaling_V1_WebRTCSignal.OneOf_Signal?) -> SignalStreamAdmission {
    switch signal {
    case .offer, .answer:
        return .refuseSdp
    default:
        return .accept
    }
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
