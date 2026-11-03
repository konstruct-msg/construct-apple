//
//  RetiredSessionControl.swift
//  Construct Messenger
//
//  END_SESSION (21), SESSION_RESET_INIT (24), SESSION_PING (25) and SESSION_READY (26) went on
//  2026-09-27: a session renews by sending (`decisions/sessions-renew-by-sending.md`). No current
//  iOS, Android, TUI or core build sends any of them. A build from before that date still can — a
//  TestFlight build lives 90 days, and a Desktop DMG never expires — so receiving one must still
//  end in "acknowledged, dropped": not a bubble, not an answer, not a redelivery.
//

import Foundation

/// The end date of the receive guards for the four retired session-control types, and where
/// they are. After `removeAfter` `RetiredSessionControlTests` reddens: delete the guards below,
/// this file, and — in construct-protos, in the same change for every client — mark 21/24/25/26
/// retired in `conformance/knst_content_types.json`, which today still gives them a routing kind
/// and an op (and so keeps `WireMessageKind.sessionResetInit`, `SealedEnvelopeType.sessionResetInit`
/// and `SessionControlCodec.op` alive here).
///
/// Guards, all early and silent on the wire:
///   - `MessageStreamParser` and `MessagingServiceClient.getPendingMessages` — identified 21 / 24
///     (sent unsealed by a Debug build with stealth off): made into a message the router can
///     acknowledge. Without them an END_SESSION's sentinel payload is not a wire payload, so the
///     stream parser yields nothing and the cursor never passes it.
///   - `MessageRouter` — END_SESSION (21): acknowledged before any decryption.
///   - `MessageRouter` — SESSION_RESET_INIT (24): opens like any handshake, payload discarded.
///   - `MessageRouter+ControlFrames` — ping / ready (25 / 26): logged and discarded.
///
/// `MessageContentType.sessionPing/sessionReady/sessionReset` (10/11/12) are *not* part of this:
/// they are a storage format, rows stamped with them exist and are hidden by them.
enum RetiredSessionControl {
    /// The last TestFlight build that could send them was uploaded before 2026-09-27 and expires
    /// 90 days later; ten days of margin.
    static let removeAfter: Date = {
        var components = DateComponents(year: 2027, month: 1, day: 5)
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    static let contentTypes: Set<Shared_Proto_Core_V1_ContentType> = [
        .sessionReset, .sessionResetInit, .sessionPing, .sessionReady,
    ]
}
