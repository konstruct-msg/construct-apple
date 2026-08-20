//
//  AppliedInitLedger.swift
//  Construct Messenger
//
//  Which X3DH inits we have already applied for a peer.
//

import Foundation

/// The SESSION_RESET_INITs already applied for one peer, identified by their X3DH ephemeral public
/// key, most recent first and bounded.
///
/// This replaces `lastAppliedResetInitAt`, a timestamp that was itself the fix for a timestamp
/// (see `SessionReducer.isResetInitSuperseded`). A redelivered init is not "an init that is not
/// newer than the last one" — it is *the same message*, and the ephemeral public key says so
/// directly. Two copies carry one key; a genuine peer retry generates a new one.
///
/// In memory only, like the timestamp it replaces: after a process restart `establishedAt` is
/// current again and covers the same duplicate, whereas a stale persisted ledger would be a way to
/// coalesce a live re-init forever — the failure this whole path exists to prevent.
struct AppliedInitLedger: Equatable {

    /// How many inits back a redelivery is still recognised. A backlog replay arrives within a
    /// reconnect, so this only has to outlast the re-inits that can happen inside one; eight is
    /// far past that and costs 256 bytes per peer.
    static let capacity = 8

    /// Most recent first.
    private(set) var keys: [Data] = []

    /// Whether this exact init has already been applied.
    ///
    /// An empty key is never a match. An init we cannot identify must not be coalesced on a guess:
    /// a redundant re-init is cheap, a dropped live one strands the peer permanently (§1d).
    func contains(_ ephemeralPublicKey: Data) -> Bool {
        guard !ephemeralPublicKey.isEmpty else { return false }
        return keys.contains(ephemeralPublicKey)
    }

    /// Record an init as applied. Re-recording an existing key moves it to the front rather than
    /// duplicating it, so a peer that retries one init cannot evict the others.
    mutating func record(_ ephemeralPublicKey: Data) {
        guard !ephemeralPublicKey.isEmpty else { return }
        keys.removeAll { $0 == ephemeralPublicKey }
        keys.insert(ephemeralPublicKey, at: 0)
        if keys.count > Self.capacity {
            keys.removeLast(keys.count - Self.capacity)
        }
    }
}
