//
//  SessionReinitHintStore.swift
//  Construct Messenger
//
//  L2 of the OTPK session-init deadlock fix (see construct-docs otpk-session-init-deadlock).
//

import Foundation

/// The "open the next session without a one-time prekey" hint, between the place it arrives and
/// the init that acts on it.
///
/// The peer's core tells ours, in a decryption error, that it does not hold the one-time prekey
/// our handshake named; the core answers with `SessionRetired(withoutOneTimePrekey: true)`, and
/// `SessionCoordinator` marks the peer here. The next `SessionInitializationService` init for that
/// peer skips the one-time prekey and does 3-DH, which the responder can always reproduce
/// (identity + signed prekey only) — breaking the loop where every re-fetched OTPK hits the same
/// unbackable state. Until 2026-09-27 the hint rode on a typed END_SESSION, and this store also
/// carried the responder's half of it; the core owns that half now.
///
/// In-memory + process-lifetime is deliberate: recovery completes within a session.
/// Thread-safe (touched from the MainActor session paths and the init path).
final class SessionReinitHintStore {
    static let shared = SessionReinitHintStore()
    private init() {}

    private let lock = NSLock()
    private var forceThreeDHInit: Set<String> = []

    // MARK: - INITIATOR side (force 3-DH on next init)

    /// Mark that the next session init for `userId` must be 3-DH (no one-time-prekey),
    /// because the peer told us it could not reproduce our 4-DH OTPK.
    func requestThreeDHReinit(for userId: String) {
        lock.lock(); defer { lock.unlock() }
        forceThreeDHInit.insert(userId)
    }

    /// Consume the initiator-side marker. Returns `true` iff the next init for this peer
    /// must skip the one-time-prekey.
    func consumeThreeDHReinit(for userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return forceThreeDHInit.remove(userId) != nil
    }
}
