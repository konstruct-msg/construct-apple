//
//  SessionReinitHintStore.swift
//  Construct Messenger
//
//  L2 of the OTPK session-init deadlock fix (see construct-docs otpk-session-init-deadlock).
//

import Foundation

/// Cross-path signal that carries the OTPK-unreproducible recovery hint between the
/// components that detect it, transmit it, and act on it. Two hops:
///
///  1. **RESPONDER side (outgoing hint).** When `initReceivingSession` fails because we
///     cannot reproduce the peer's 4-DH one-time-prekey (the Rust core returns "…cannot
///     reproduce it; session healing required"), `PublicKeyBundleHandler` records it here.
///     The `SessionCoordinator` init-failure path then sends END_SESSION carrying
///     `SessionResetReason.otpkUnreproducible` instead of a bare reset.
///
///  2. **INITIATOR side (force 3-DH).** On receiving that typed END_SESSION,
///     `MessageRouter` marks the peer here. The next `SessionInitializationService` init
///     for that peer skips the one-time-prekey and does 3-DH, which the responder can
///     always reproduce (identity + signed prekey only) — breaking the 4-DH retry loop
///     where every re-fetched OTPK hits the same unbackable state.
///
/// In-memory + process-lifetime is deliberate: recovery completes within a session, and
/// if the app is killed the server re-delivers END_SESSION and the hint is re-established.
/// Thread-safe (touched from the RESPONDER decrypt path and the MainActor session paths).
final class SessionReinitHintStore {
    static let shared = SessionReinitHintStore()
    private init() {}

    private let lock = NSLock()
    private var responderOtpkUnreproducible: Set<String> = []
    private var forceThreeDHInit: Set<String> = []

    // MARK: - RESPONDER side (outgoing END_SESSION hint)

    /// Mark that our last RESPONDER init for `userId` failed because we could not reproduce
    /// the peer's one-time-prekey.
    func recordResponderOtpkUnreproducible(for userId: String) {
        lock.lock(); defer { lock.unlock() }
        responderOtpkUnreproducible.insert(userId)
    }

    /// Consume the responder-side hint. Returns `true` iff the last responder init for this
    /// peer failed on an unreproducible OTPK — i.e. the END_SESSION we are about to send
    /// should ask the peer to re-init without an OTPK.
    func consumeResponderOtpkUnreproducible(for userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return responderOtpkUnreproducible.remove(userId) != nil
    }

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
