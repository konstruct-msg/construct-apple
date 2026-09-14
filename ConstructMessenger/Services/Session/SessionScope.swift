//
//  SessionScope.swift
//  Construct Messenger
//
//  What a session phase and an init lock are keyed by.
//

import Foundation

/// The subject of one session lifecycle.
///
/// ## Why this is not a `String`
///
/// A ratchet is between two **devices**, so the phase of a session is per device and so is the
/// lock that stops two inits racing over it. Keying either by account is the defect
/// [[a-peer-is-a-set-of-devices]] describes from the other end: an init with the peer's phone
/// takes a lock that a parallel init with their Desktop then waits on, and the second device stays
/// deaf while the map says someone is already working on it.
///
/// It also produced a live mismatch. `hydrateEstablishedTimestampsForRestoredSessions` walks
/// `getAllSessionContactIds()` — the core's contact ids, which are **device** ids — and wrote them
/// into a map every other reader indexed by **account**. So after a restart it stamped entries
/// nobody read, the account-keyed lookups still answered `nil`, and `isEndSessionStale(nil, …)`
/// returns `false` — the END_SESSION is honoured. The function written to stop redelivered
/// teardowns from destroying restored sessions could not do it, and nothing said so.
///
/// ## Why the account case is not a fallback
///
/// `peer` is not "we failed to resolve a device". It is the correct scope for an operation that
/// genuinely spans the account's device set — first contact, and the RESPONDER walk — where two
/// concurrent runs would race over whichever ratchet the walk ends up opening.
///
/// That is why it is a case rather than an optional device id: the two mean different things, one
/// contains the other, and an enum makes a caller say which it holds instead of letting a bare
/// `String` carry either.
enum SessionScope: Hashable, CustomStringConvertible {

    /// A named device — `CryptoDeviceId`. The normal case, and the only one an established
    /// session is ever in.
    case device(String)

    /// Every device of one account — `ServerUserId`.
    ///
    /// Two operations are genuinely this shape and neither is a failure to resolve:
    ///
    /// - **First contact.** No device is named because none has been learned, and the bundle
    ///   fetch this guards is what learns it.
    /// - **The RESPONDER walk.** `plan_receiving_init` is handed the account's whole device set
    ///   and decides which device the carrier binds, so until it answers the operation could
    ///   open a ratchet with any of them.
    ///
    /// A peer-wide scope **contains** the device-wide ones — see `contains(_:)`. Without that,
    /// splitting one account-keyed lock into per-device locks would let a responder walk and a
    /// prewarm run at once and collide on the same ratchet, which is the race the single coarse
    /// lock used to prevent by accident.
    case peer(String)

    /// The scope a peer's session lifecycle belongs to.
    ///
    /// `deviceOrPinned()` is the seam read: the device the event named, or the one we pinned for
    /// this contact. `nil` there means we hold no identity key for them at all, which is exactly
    /// first contact.
    init(_ address: PeerAddress) {
        if let device = address.deviceOrPinned() {
            self = .device(device)
        } else {
            self = .peer(address.account)
        }
    }

    /// The scope for an operation that targets one peer's **pinned** device — every INITIATOR
    /// path, which opens a ratchet with the device we hold a key for. Falls back to peer-wide
    /// when we hold no key, because then the operation is first contact.
    static func forAccount(_ accountId: String) -> SessionScope {
        SessionScope(PeerAddress.account(accountId))
    }

    /// The scope for an operation whose subject is the account's whole device set.
    static func wholePeer(_ accountId: String) -> SessionScope {
        .peer(accountId)
    }

    /// The identifier this scope persists under.
    ///
    /// One namespace, and that is deliberate: the two cases are disjoint (32-char hex vs 36-char
    /// UUID) and a peer moves from `unnamedPeer` to `device` exactly once, at first contact, when
    /// there is nothing yet to carry over.
    var storageKey: String {
        switch self {
        case .device(let id), .peer(let id): return id
        }
    }

    /// Whether a lock held on `self` also covers `other`.
    ///
    /// Containment runs one way: a peer-wide scope covers each of that account's devices, a
    /// device-wide scope covers only itself. `resolveAccount` reads the seam backwards for a
    /// device id (`PeerAddress.resolving`); a device attributable to no contact is covered by
    /// nothing, which is the same state as "no session with them can exist".
    func contains(_ other: SessionScope, resolveAccount: (String) -> String?) -> Bool {
        if self == other { return true }
        guard case .peer(let account) = self else { return false }
        guard case .device(let deviceId) = other else { return false }
        return resolveAccount(deviceId) == account
    }

    /// The device this scope names, or `nil` when it names none.
    var deviceId: String? {
        if case .device(let id) = self { return id }
        return nil
    }

    var description: String {
        switch self {
        case .device(let id): return "dev:\(id.prefix(8))…"
        case .peer(let id): return "peer:\(id.prefix(8))…(all devices)"
        }
    }
}
