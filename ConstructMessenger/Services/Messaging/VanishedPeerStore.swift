//
//  VanishedPeerStore.swift
//  Construct Messenger
//
//  Peers the **server** says do not exist. Not the same thing as a contact the user deleted, and
//  deliberately not stored with them: `DeletedContactsStore` answers "did we delete them", this
//  answers "can they still be reached", and one carrier for two meanings is how they drift.
//
//  Why this exists at all. `getPreKeyBundle` answering `notFound` was treated as a transient
//  failure: three attempts with backoff, then `fetch_bundle_exhausted`, then the next redelivery
//  of the same message started the three attempts again. A user who no longer exists server-side
//  never stops answering that way, so the retry never ends and — worse — the pending session queue
//  for that peer never drains. A saturated queue returns `.deferred` for messages it did not
//  enqueue, those entries have no owner, and one of them sits at the head of
//  `StreamCursorTracker`'s FIFO holding the resume cursor.
//
//  Device A on 2026-08-20 had been subscribing from `1785495484579-0` — 31 July — for three weeks
//  for exactly this reason. 100 % of its replayed traffic (3612 of 3612 envelopes) was one deleted
//  user, the queue stood at 70, and deleting contacts locally did not help because none of this is
//  contact state.
//
//  Revocable on purpose: an account can be re-registered, and the peer's first real handshake is
//  the evidence that it was. See `SessionReducer.vanishedPeerAction`.
//

import Foundation

@MainActor
final class VanishedPeerStore {

    static let shared = VanishedPeerStore()

    private static let key = "construct.session.vanishedPeers"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var ids: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.key) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Self.key) }
    }

    func isVanished(_ userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return ids.contains(userId)
    }

    /// The server answered `notFound` for this peer's bundle.
    func markVanished(_ userId: String) {
        guard !userId.isEmpty else { return }
        var current = ids
        guard current.insert(userId).inserted else { return }
        ids = current
        Log.info(
            "VANISHED_PEER[marked]: \(userId.prefix(8))… — server reports no such user; discarding their replayed traffic instead of queueing it",
            category: "SessionInit"
        )
    }

    /// They are back — a real handshake arrived, or a bundle fetch succeeded.
    func clear(_ userId: String) {
        guard !userId.isEmpty else { return }
        var current = ids
        guard current.remove(userId) != nil else { return }
        ids = current
        Log.info("VANISHED_PEER[cleared]: \(userId.prefix(8))… — reachable again", category: "SessionInit")
    }

    #if DEBUG
    func removeAllForTesting() { defaults.removeObject(forKey: Self.key) }
    #endif
}
