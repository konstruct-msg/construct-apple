//
//  CallDeviceRouting.swift
//  Construct Messenger
//
//  Which of the other person's devices each call signal goes to and comes from
//  (`decisions/a-call-rings-every-device.md`). The rule is the core's (`construct-rules`
//  `calls`, construct-core 0.74.0, todo 295), shared with Android and construct-client; this file
//  only carries this app's values to it:
//
//  - the offer goes to every device of theirs the core plans a send to and we hold a session with;
//  - until someone answers, everything we send goes to all of them;
//  - the first answer picks the device; from then on we talk to it alone, and the others are told
//    the call was taken elsewhere (`HANGUP_REASON_ACCEPTED_ELSEWHERE`);
//  - a device is known by the session the core opened its signal under (`CallSignalDecrypted`'s
//    contact id), never by the `sender_device_id` the sender writes itself.
//
//  Device ids are `CryptoDeviceId`s throughout — below the seam.
//

import Foundation

enum CallDeviceRouting {
    /// Who a call signal is encrypted for. `chosen`: the device this call talks to — the one that
    /// sent the offer (callee side) or answered first (caller side). `offered`: the devices our
    /// offer went to. `pinned`: the single device the peer's pinned key names, for a call that
    /// knows neither (a busy refusal to a call we never took).
    static func targets(chosen: String?, offered: [String], pinned: String?) -> [String] {
        callSignalTargets(chosen: chosen, offered: offered, pinned: pinned)
    }

    /// The devices an offer goes to: those the core planned a send to that we hold a session
    /// with, in the plan's order; the pinned device when none has one.
    static func offerDevices(planned: [String], hasSession: (String) -> Bool, pinned: String?) -> [String] {
        callOfferDevices(planned: planned, withSession: planned.filter(hasSession), pinned: pinned)
    }

    /// Whether a signal from `device` belongs to this call: any of the peer's devices before one
    /// is chosen, only the chosen one after.
    static func admits(_ device: String, chosen: String?) -> Bool {
        callAdmits(device: device, chosen: chosen)
    }

    static func onAnswer(from device: String, chosen: String?, offered: [String]) -> CallAnswerDisposition {
        callOnAnswer(device: device, chosen: chosen, offered: offered)
    }

    /// A hangup from one of the peer's devices: declining anywhere ends the call for every
    /// device; busy on one only takes that one out until all are busy; taken on another of our
    /// devices ends this one's ringing and nothing else.
    static func onHangup(from device: String, reason: Shared_Proto_Signaling_V1_HangupReason,
                         chosen: String?, offered: [String]) -> CallHangupDisposition {
        callOnHangup(device: device, reason: CallRuleWire.reason(reason), chosen: chosen, offered: offered)
    }
}

/// This app's call values in the core rule's types. The wire enums map by their numbers, so an
/// unknown value reads as the rule's `unspecified`, never as a guess.
enum CallRuleWire {
    static func reason(_ r: Shared_Proto_Signaling_V1_HangupReason) -> CallHangupReason {
        callHangupReasonFromWire(value: Int32(truncatingIfNeeded: r.rawValue))
    }

    static func proto(_ r: CallHangupReason) -> Shared_Proto_Signaling_V1_HangupReason {
        Shared_Proto_Signaling_V1_HangupReason(rawValue: Int(callHangupReasonWire(reason: r))) ?? .unspecified
    }

    static func cause(_ reason: CallEndReason) -> CallEndCause {
        switch reason {
        case .hangup(let r): return .hangup(reason: Self.reason(r))
        case .error(let code): return .serverError(error: callSignalErrorFromWire(value: Int32(truncatingIfNeeded: code.rawValue)))
        // Every local reason is a setup or path failure (`endActiveCall(reason: .local(…))`); a
        // person ending the call is a hangup.
        case .local: return .local
        }
    }

    static func direction(_ d: CallSession.Direction) -> CallDirection {
        switch d {
        case .incoming: return .incoming
        case .outgoing: return .outgoing
        }
    }

    /// The call this device holds when an offer for `callId` from `offerer` arrives, as the
    /// core's offer rule reads it (`callOnOffer`). `session`: the call this app tracks, if any.
    /// A different call that no longer occupies the phone (`isBusy` false: idle, ended) holds
    /// nothing — a stale call must not refuse a real one. The offer's own call is held in any
    /// state; an ended one is caught first by `recently_ended`.
    static func held(
        callId: String, offerer: String, session: CallSession?, isBusy: Bool,
        answered: Bool, awaitingOfferAfterAnswer: Bool
    ) -> CallHeldCall? {
        guard let session, session.id == callId || isBusy else { return nil }
        return CallHeldCall(
            sameCall: session.id == callId,
            direction: direction(session.direction),
            withOfferer: session.peerUserId == offerer,
            answered: answered,
            awaitingOfferAfterAnswer: awaitingOfferAfterAnswer
        )
    }

    /// Which channels a hangup with this wire reason is written to (`call_hangup_route`).
    static func hangupRoute(side: CallHangupSide, reason r: Shared_Proto_Signaling_V1_HangupReason) -> CallHangupRoute {
        callHangupRoute(side: side, reason: reason(r))
    }

    /// The history row's status as this app stores it (`CallRecord.Status`, the same codes 0–3).
    static func record(_ s: CallHistoryStatus) -> CallRecord.Status {
        switch s {
        case .completed: return .completed
        case .missed: return .missed
        case .declined: return .declined
        case .failed: return .failed
        }
    }
}
