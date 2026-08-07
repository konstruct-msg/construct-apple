//
//  SessionEstablishment.swift
//  Construct Messenger
//
//  When a session with a peer came into existence — the durable record, and its one invariant.
//

import Foundation

/// **A live session must have an establishment record, and the record is written when the session
/// is created — not when the handshake confirms it.**
///
/// `SessionReducer.isEndSessionStale` answers "does this END_SESSION pre-date the session I have?"
/// With no record it cannot answer, and the caller's only remaining option is to act on the
/// END_SESSION — i.e. tear down a session that may be newer than the message ending it.
///
/// Build 585, device 6bf51980, seven seconds after launch:
///
///     10:54:00  SESSION_STATE[rust_end_session]: DR diverged for 0a1c609f… — sending END_SESSION
///     10:54:07  SESSION_STATE[proactive_init_success]: userId=0a1c609f…
///     10:54:07  SESSION_STATE[sri_sent]: to 0a1c609f… (attempt 1)
///     10:54:07  SESSION_STATE[end_session_stale_check]: 0a1c609f… ts=1786100043 established=nil
///               hasLiveSession=true → not filtered — live session will be reset by a
///               possibly-stale END_SESSION (no in-memory establishedAt)
///     10:54:08  SESSION_STATE[init_receiving_failed]: … All 1 prekey(s) failed …
///
/// A session built at 10:54:07 was destroyed by an END_SESSION stamped 10:54:03 — four seconds
/// *older* than the thing it ended. The filter for exactly this case stayed silent because the
/// record was missing, and it was missing because of an asymmetry nobody could see:
///
/// - RESPONDER records establishment where the session is built (`SessionCoordinator`, via the
///   reducer's `.initSucceeded`).
/// - INITIATOR built the session in `SessionInitializationService.initializeSession` and recorded
///   nothing there. Its only writer was `markActive`, reached when the peer's `session_ready`
///   comes back — so between creating a session and being confirmed, an INITIATOR held a live
///   session it could not date. Our own teardown at 10:54:00 had cleared the previous record;
///   the re-init at 10:54:07 did not write a new one.
///
/// Two writers for one fact, one of which may never run. This type is the single channel, so the
/// asymmetry cannot come back silently: whoever creates a session records it here.
enum SessionEstablishment {

    /// Storage seam. Production writes the Keychain with `kSecAttrAccessibleAfterFirstUnlock` —
    /// this record gates a session teardown during a locked background push decrypt, so
    /// `WhenUnlocked` would make it unreadable exactly when it decides the most (see the
    /// Keychain invariant in AGENTS.md). Tests substitute an in-memory store.
    struct Store {
        var save: (UInt64, String) -> Void
        var load: (String) -> UInt64?
        var clear: (String) -> Void

        static let keychain = Store(
            save: { KeychainManager.shared.saveSessionEstablishedAt($0, for: $1) },
            load: { KeychainManager.shared.loadSessionEstablishedAt(for: $0) },
            clear: { KeychainManager.shared.deleteSessionEstablishedAt(for: $0) }
        )
    }

    nonisolated(unsafe) static var store: Store = .keychain

    /// Record that a session with `userId` exists as of `at` (Unix seconds, default now).
    static func record(for userId: String, at: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        guard !userId.isEmpty else { return }
        store.save(at, userId)
    }

    /// The establishment time, or nil when no session is on record.
    static func loadTimestamp(for userId: String) -> UInt64? {
        guard !userId.isEmpty else { return nil }
        return store.load(userId)
    }

    /// Drop the record — only on teardown. Clearing it while a session is alive re-creates the
    /// build-585 blind spot.
    static func clear(for userId: String) {
        guard !userId.isEmpty else { return }
        store.clear(userId)
    }
}
