//
//  CallDeviceRouting.swift
//  Construct Messenger
//
//  Which of the other person's devices each call signal goes to and comes from
//  (`decisions/a-call-rings-every-device.md`). Pure, so the rules are tested without a call:
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
        if let chosen { return [chosen] }
        if !offered.isEmpty { return offered }
        return pinned.map { [$0] } ?? []
    }

    /// The devices an offer goes to: those the core planned a send to that we hold a session
    /// with, in the plan's order. A device without a session would get nothing it can open; the
    /// pinned device is the fallback when none has one (the caller then waits for its session).
    static func offerDevices(planned: [String], hasSession: (String) -> Bool, pinned: String?) -> [String] {
        var seen = Set<String>()
        let usable = planned.filter { hasSession($0) && seen.insert($0).inserted }
        if !usable.isEmpty { return usable }
        return pinned.map { [$0] } ?? []
    }

    /// Whether a signal from `device` belongs to this call. Before a device is chosen, any of
    /// the peer's devices may speak (an answer, a decline); after, only the chosen one.
    static func admits(_ device: String, chosen: String?) -> Bool {
        chosen == nil || chosen == device
    }

    enum AnswerDisposition: Equatable {
        /// Take this answer: `device` becomes the call's device, and `release` are told the call
        /// was taken elsewhere.
        case accept(device: String, release: [String])
        /// Someone else answered first: tell this device the call was taken elsewhere.
        case releaseLate(String)
    }

    static func onAnswer(from device: String, chosen: String?, offered: [String]) -> AnswerDisposition {
        if let chosen, chosen != device { return .releaseLate(device) }
        return .accept(device: device, release: offered.filter { $0 != device })
    }

    enum HangupDisposition: Equatable {
        /// End the call, and tell `release` (the other offered devices) it was taken elsewhere.
        case end(release: [String])
        /// Only this device is out (it is busy); the call keeps ringing on `remaining`.
        case dropDevice(remaining: [String])
        /// Not from this call's device: ignore.
        case ignore
    }

    /// A hangup from one of the peer's devices. Declining anywhere ends the call for every device;
    /// busy on one only takes that one out until all are busy.
    static func onHangup(from device: String, reason: Shared_Proto_Signaling_V1_HangupReason,
                         chosen: String?, offered: [String]) -> HangupDisposition {
        guard admits(device, chosen: chosen) else { return .ignore }
        let others = offered.filter { $0 != device }
        if chosen == nil, reason == .busy, !others.isEmpty {
            return .dropDevice(remaining: others)
        }
        return .end(release: chosen == nil ? others : [])
    }
}
