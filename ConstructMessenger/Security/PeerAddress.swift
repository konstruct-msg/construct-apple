//
//  PeerAddress.swift
//  Construct Messenger
//
//  The seam of `SessionAddressing`, made into an object a caller cannot mistake.
//

import Foundation
import CoreData

/// A peer named in **both** identity spaces at once.
///
/// ## Why this exists
///
/// `SessionAddressing` documents the seam: above it an id names an account (`ServerUserId`),
/// below it an id names a device (`CryptoDeviceId`). What it could not do is stop a *carrier*
/// from crossing the seam unconverted, because both spaces are `String` and the parameter that
/// carries them was called `userId` on both sides.
///
/// `MessageRouterDelegate` was that parameter. Nine call sites fed it, five from the envelope
/// (an account) and four from a Rust orchestrator action (a device), and nothing distinguished
/// them — not the type, not the label, not the receiving code. Devices 2026-09-01, on a
/// single-device peer, one round of a loop that ran eight times:
///
///     ORCH_EVENT: messageReceived from=651e765c…            ← the core, device space, correct
///     SESSION_STATE[rust_end_session]: DR diverged for 651e765c…
///     SESSION_STATE[proactive_init_start]: userId=651e765c…  ← same id, now in the account slot
///     SESSION_STATE[fetch_bundle_failed]: attempt=1/3, notFound: "User or device not found"
///     SESSION_STATE[fetch_bundle_failed]: attempt=2/3, notFound: "User or device not found"
///     SESSION_STATE[fetch_bundle_failed]: attempt=3/3, notFound: "User or device not found"
///     SESSION_STATE[proactive_init_failed]: userId=651e765c…
///
/// The server is right: there is no *account* `651e765c…`. Every recovery attempt that took the
/// device-space branch died on that answer, so a diverged session had roughly even odds of never
/// being rebuilt — and the failure is silent apart from a log line nobody reads until a whole
/// conversation has stopped.
///
/// Three further mismatches sat on the same parameter and were found by drawing this type:
/// `pendingQueue` and `SessionHealingService` filed entries under a device id that only ever gets
/// drained by account; `KeychainManager.loadSessionSuiteId` is written by device and was read by
/// account, which is why every `tie_break_win` / `heal_triggered` line in every log says
/// `suiteId=0` while the session negotiated suite 3.
///
/// ## The rule
///
/// `account` is what the **network**, Core Data, the transcript and the confirmation tracker are
/// keyed by. `device` is what the **core**, the Keychain session accounts and every ratchet are
/// keyed by. A caller picks the half its callee wants, and the compiler no longer lets it pick by
/// accident, because there is no bare id left to pick.
///
/// `device` is `nil` when the event genuinely names no device — a locked Keychain, a core that
/// will not load, a message arriving mid-ratchet with no session at all. That is not a
/// degraded `PeerAddress`: it is the accurate statement that the peer, not one of its devices, is
/// what the event is about, and the teardown plan in the core is built to take exactly that.
struct PeerAddress: Equatable, Sendable, CustomStringConvertible {

    /// `ServerUserId` — 36-char account UUID. Always present: an event about a peer we cannot
    /// name as an account is an event we cannot route, store or display.
    let account: String

    /// `CryptoDeviceId` — 32-char hex. `nil` means "this peer", not one of its devices.
    let device: String?

    init(account: String, device: String? = nil) {
        self.account = account
        // An empty string is not a device id, and it reads as one at every `!isEmpty` guard
        // downstream. Normalise once, here, rather than at each of them.
        self.device = (device?.isEmpty ?? true) ? nil : device
    }

    /// The peer with no device named — the envelope's view, which is all the account space has.
    static func account(_ accountId: String) -> PeerAddress {
        PeerAddress(account: accountId, device: nil)
    }

    /// Read the seam **backwards**, for the one caller shape that holds only what the core said.
    ///
    /// Prefer the memberwise initialiser: every emission site inside `MessageRouter` already has
    /// the account in scope from the envelope, so it can state both halves exactly and for free.
    /// This exists for a caller that has a device id and nothing else, and it can fail — a device
    /// we hold no `PeerDevice` row and no pinned key for cannot be attributed to an account. `nil`
    /// is the same state as "no session can exist with this peer"; it is never an invitation to
    /// substitute the device id for the account.
    static func resolving(device deviceId: String, in context: NSManagedObjectContext) -> PeerAddress? {
        guard let peer = SessionAddressing.peer(ofDevice: deviceId, in: context) else { return nil }
        return PeerAddress(account: peer.accountId, device: deviceId)
    }

    /// The device this address names, or the peer's pinned device when it names none.
    ///
    /// For the device-keyed stores — the END_SESSION cooldown, the session suite id, the
    /// tie-break — which have no account-keyed meaning at all. `nil` when the peer has no pinned
    /// key, which is the state in which no session with them exists.
    func deviceOrPinned() -> String? {
        device ?? SessionAddressing.contactId(forPeer: account)
    }

    /// Short form for logs: `<account>…/<device>…`, or `<account>…/—` when no device is named.
    var description: String {
        "\(account.prefix(8))…/\(device.map { "\($0.prefix(8))…" } ?? "—")"
    }
}
