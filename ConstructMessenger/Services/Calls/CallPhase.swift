//
//  CallPhase.swift
//  Construct Messenger
//
//  What a call screen shows, decided from the call's state alone: one phase, and for a call that
//  is over, how it ended. The Desktop call window and call bar read it (iOS keeps its own
//  status text in `InCallView`). Pure, so the mapping is tested without a call.
//

import Foundation

/// How a call ended, for the screen: the core's `CallEndOutcome` (construct-core 0.73.0, todo 295),
/// so iOS, Android and construct-client read an ended call the same way. `ended(connectedSeconds:)`
/// carries how long the two were connected, nil if they never were.
typealias CallOutcome = CallEndOutcome

extension CallEndOutcome {
    /// An outcome the person may want to act on (call back, look at the network). A normal end
    /// needs no answer, so its window closes by itself.
    var wantsAttention: Bool { callOutcomeWantsAttention(outcome: self) }
}

enum CallPhase: Equatable, Sendable {
    case incoming
    /// Outgoing, before the other side's device rang.
    case calling
    /// Outgoing, ringing on the other side.
    case ringing
    case connecting
    case live
    /// Connected once and lost the path; WebRTC is restarting ICE.
    case reconnecting
    case over(CallOutcome)

    /// The call holds the microphone in this phase, so mute and devices apply.
    var isLive: Bool {
        switch self {
        case .calling, .ringing, .connecting, .live, .reconnecting: true
        case .incoming, .over: false
        }
    }

    /// `connectedSeconds`: how long the call has been connected, nil if it never was.
    static func of(_ state: CallState, quality: CallQuality, connectedSeconds: Int?) -> CallPhase? {
        switch state {
        case .idle: return nil
        case .incoming: return .incoming
        case .dialing: return .calling
        case .ringing: return .ringing
        case .connecting: return .connecting
        case .active: return quality == .reconnecting ? .reconnecting : .live
        case .ended(_, let reason): return .over(outcome(of: reason, connectedSeconds: connectedSeconds))
        }
    }

    static func outcome(of reason: CallEndReason, connectedSeconds: Int?) -> CallOutcome {
        callEndOutcome(cause: CallRuleWire.cause(reason),
                       connectedSeconds: connectedSeconds.map { UInt32(clamping: $0) })
    }
}
