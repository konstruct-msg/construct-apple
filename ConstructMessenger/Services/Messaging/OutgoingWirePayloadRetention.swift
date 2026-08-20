//
//  OutgoingWirePayloadRetention.swift
//  Construct Messenger
//
//  Which persisted outgoing wire-payloads are dead and may be deleted.
//
//  `OutgoingWirePayloadStore` writes one UserDefaults key per outgoing message, holding the exact
//  encrypted bytes so a retry can re-send them without advancing the Double Ratchet. It has a 24h
//  TTL — and the TTL was only ever evaluated inside `loadChunks(baseMessageId:)`, i.e. when that
//  same key is read again. A message that is never retried is never read again, so its key never
//  expired. Nothing enumerated the keyspace; nothing swept.
//
//  The happy path does clean up (`.sent`/`.delivered` removes the key). What accumulated was
//  everything else, and on the networks this app is built for that is not an edge case:
//
//    · a retryable transport failure parks the message as `.queued` and keeps the payload — correct
//      — but if the retry never lands, the key outlives the message forever;
//    · `StealthDowngradeBlocked` does the same;
//    · the process being killed between `onWirePayloadEncoded` and the server's answer leaves a key
//      with nobody left to remove it.
//
//  Device, 2026-08-11 15:21:25, right after a voice message went out:
//
//      CFPrefsPlistSource<0x116218900> (Domain: maximeliseyev.constructmessenger …): Attempting to
//      store >= 4194304 bytes of data in CFPreferences/NSUserDefaults on this platform is invalid.
//      This is a bug in Construct Messenger or a library it uses.
//
//  That message is about the whole domain, not one value — which is exactly the shape of a slow
//  accumulation. NOTE this store is a strong suspect, not a proven cause: see
//  `UserDefaultsFootprint`, which measures the domain so the next device run can name the culprit
//  instead of confirming a guess.
//

import Foundation

enum OutgoingWirePayloadRetention {

    /// Key namespace owned by `OutgoingWirePayloadStore`. Single source of truth: the store builds
    /// its keys from this, and the sweep finds them by it. Two spellings would silently sweep
    /// nothing.
    static let keyPrefix = "construct.outgoingWirePayload."

    /// Keys whose payload can no longer serve a retry and may be deleted.
    ///
    /// `createdAt` is `nil` for an entry that would not decode. Those are swept too, deliberately:
    /// an entry that cannot be read cannot be re-sent and cannot ever purge itself, so leaving it
    /// only preserves bytes nobody can use.
    ///
    /// A payload dated in the *future* is kept. That is not defensive habit — the user's clock
    /// moving backwards (timezone edit, NTP correction) would otherwise make every live queued
    /// message look ancient and delete the one thing that lets it be re-sent without breaking the
    /// peer's ratchet.
    static func expiredKeys(
        entries: [(key: String, createdAt: TimeInterval?)],
        now: TimeInterval,
        ttl: TimeInterval
    ) -> [String] {
        entries.compactMap { entry in
            guard let createdAt = entry.createdAt else { return entry.key }
            let age = now - createdAt
            guard age > ttl else { return nil }
            return entry.key
        }
    }
}
