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

/// Whether a silent `new_message` push may be dropped because MessageStream looks live.
///
/// The skip exists to stop a reconnect storm: every incoming message used to produce a push,
/// and the push tore the stream down and back up. That skip is wrong the moment a call is
/// waiting on an SDP that travels the same stream. Build 631, 2026-08-22:
///
///     13:20:00  Incoming VoIP push — CallKit notified (7CDE9769)
///     13:20:00  Offer (proto) sent via E2EE                    ← already on the server
///     13:20:02  Answered before the offer arrived — waiting
///     13:20:15  QUIC recv Timeout (stream had looked "connected" for 30s)
///     13:20:15  Silent push — reconnecting stream
///     13:20:15  Ignoring offer for already-ended call          ← 15 s late, after hangup
///
/// The offer sat behind a zombie QUIC stream. Foreground `isConnected` was true, so every
/// silent push that could have pulled it was ignored. `callNeedsOffer` is the fact the skip
/// cannot see on its own.
func shouldIgnoreSilentPush(foregroundLiveStream: Bool, callNeedsOffer: Bool) -> Bool {
    foregroundLiveStream && !callNeedsOffer
}

/// Whether an incoming call should pull missed messages to recover an SDP that has not arrived.
enum IncomingCallFetchDisposition: Equatable {
    /// The offer is already in hand. A fetch would only replay it.
    case skip
    /// VoIP/CallKit knows about the call; the SDP has not. Pull the backlog.
    case pullMissed
}

func incomingCallFetchDisposition(hasUsableRemoteOffer: Bool) -> IncomingCallFetchDisposition {
    hasUsableRemoteOffer ? .skip : .pullMissed
}

/// Whether the next outgoing call signal can be encrypted under the Double Ratchet.
enum OutgoingCallSessionDisposition: Equatable {
    /// A live session exists. Encrypt now.
    case encryptNow
    /// No session. Wait — and only then try to establish one. Starting INITIATOR init
    /// immediately races a SESSION_RESET_INIT that is already running as RESPONDER.
    case waitThenInit
}

func outgoingCallSessionDisposition(hasSession: Bool) -> OutgoingCallSessionDisposition {
    hasSession ? .encryptNow : .waitThenInit
}

/// What an orchestrator `notifyError` on an outgoing call signal means.
enum CallSignalEncryptDisposition: Equatable {
    /// The contact has no session. Wait/establish and send again — dropping the signal
    /// leaves the peer ringing (or the server marking us busy) with nothing to negotiate.
    case retryAfterSession
    /// Any other encrypt failure is not recovered here.
    case drop
}

func callSignalEncryptDisposition(code: String, message: String) -> CallSignalEncryptDisposition {
    guard code == "CALL_SIGNAL_ENCRYPT_FAILED" else { return .drop }
    // Same code also covers an oversized ICE batch (134KB → encrypt failed). That is
    // not a missing session and retrying it would loop the same payload.
    if message.localizedCaseInsensitiveContains("No session") { return .retryAfterSession }
    return .drop
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
    var video: CallVideoState { get }
    /// When the current call was answered; nil before that and without a call. The call screen
    /// counts its time from it (`CallDuration`).
    var answeredAt: Date? { get }

    func clearLastError()
    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool) async
    func endCall()
    func answerIncomingCall(withCamera: Bool)
    func declineIncomingCall()
    func setMuted(_ muted: Bool)
    func setCameraOn(_ on: Bool)
    func switchCamera()
}

enum CallRuntimeProvider {
    @MainActor
    static func makeUIManager() -> (any CallUIManaging)? {
        guard CallsFeature.isEnabled else { return nil }
        return CallManager.shared
    }
}
