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
//  Revocable on purpose: an account can be re-registered. What revokes it is the **server** — a
//  successful bundle fetch, or the retry window in `SessionReducer.vanishedPeerAction` lapsing and
//  letting one fetch through to ask again. Never the peer's own traffic: the first version revived
//  on a handshake, `receivingInitKind` cannot tell a classic 3-DH handshake from a classic
//  leftover, and the backlog is made of leftovers — so the mark oscillated every 20 seconds and
//  the cursor never moved.
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

    /// `userId → when the server last answered notFound`. A date rather than a flag so the mark
    /// can expire on its own; a permanent flag would strand a re-registered account forever.
    private var marks: [String: Date] {
        get { (defaults.dictionary(forKey: Self.key) as? [String: Date]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    /// When the server last said this peer does not exist, or nil.
    func markedAt(_ userId: String) -> Date? {
        guard !userId.isEmpty else { return nil }
        return marks[userId]
    }

    /// The server answered `notFound` for this peer's bundle. Refreshes an existing mark, which
    /// is what restarts the retry window after a re-test came back `notFound` again.
    func markVanished(_ userId: String, now: Date = Date()) {
        guard !userId.isEmpty else { return }
        let isNew = marks[userId] == nil
        marks[userId] = now
        if isNew {
            Log.info(
                "VANISHED_PEER[marked]: \(userId.prefix(8))… — server reports no such user; discarding their replayed traffic instead of queueing it",
                category: "SessionInit"
            )
        }
    }

    /// They are back — a bundle fetch succeeded.
    func clear(_ userId: String) {
        guard !userId.isEmpty else { return }
        var current = marks
        guard current.removeValue(forKey: userId) != nil else { return }
        marks = current
        Log.info("VANISHED_PEER[cleared]: \(userId.prefix(8))… — reachable again", category: "SessionInit")
    }

#if DEBUG
    func removeAllForTesting() { defaults.removeObject(forKey: Self.key) }
#endif
}
