//
//  MessageRouterDelegate.swift
//  Construct Messenger
//
//  Typed event protocol replacing the 10 anonymous closure properties that
//  MessageRouter previously exposed (onEndSessionNeeded, onPublicKeyBundleNeeded,
//  isEndSessionStale, etc.). SessionCoordinator is the canonical conformer.
//

import Foundation
import CoreData

/// Receives session and delivery events emitted by `MessageRouter` during
/// incoming message processing. All methods are called on `@MainActor`.
///
/// Every peer is named by `PeerAddress`, never by a bare id. The events on this protocol come
/// from two sources in two identity spaces — the envelope names an account, a Rust orchestrator
/// action names a device — and while both were `String` under the label `userId` the conformer
/// had no way to tell which it had been handed. It did not: `needsEndSession` reached a bundle
/// fetch that asks the server for an *account*, with a device id in it, on every path the core
/// originated. See `PeerAddress` for the log of that failure.
@MainActor
protocol MessageRouterDelegate: AnyObject {

    // MARK: - Session control

    /// This app wants END_SESSION sent to `peer` — a guard that runs before or around the core
    /// (no session for a mid-ratchet message, a core that did not load or threw). The conformer
    /// asks the core's teardown window before sending.
    func messageRouter(_ router: MessageRouter, needsEndSession peer: PeerAddress)

    /// The core already decided: it ran the teardown through its machine, got the grant, and
    /// opened the window with it. The conformer sends without asking again.
    ///
    /// Separate from `needsEndSession` because the two differ in exactly the thing that matters.
    /// Asking the window on behalf of a grant lands inside the window the grant just opened and
    /// is refused — build 690, 2026-09-24: every divergence answered with "END_SESSION cooldown
    /// active, skipping", no teardown ever left either device, and both sides stayed on a
    /// ratchet neither could read, messages and calls alike.
    func messageRouter(_ router: MessageRouter, coreGrantedEndSession peer: PeerAddress)

    /// An END_SESSION message was successfully received and the session archived.
    func messageRouter(_ router: MessageRouter, receivedEndSession peer: PeerAddress, timestamp: UInt64)

    /// Return `true` when an END_SESSION from `peer` carrying `timestamp` is stale
    /// (pre-dates the currently established session) and should be silently discarded.
    func messageRouter(_ router: MessageRouter, isEndSessionStale peer: PeerAddress, timestamp: UInt64) -> Bool

    // MARK: - Session initialisation

    /// The core holds a message for `peer.device` that can open a session and granted the open:
    /// ask the core to open it (`open_receiving`). Nothing is fetched.
    func messageRouter(_ router: MessageRouter, canOpenReceiving peer: PeerAddress, for message: ChatMessage)

    // `isResetInitSuperseded`, `didWinTieBreak` and `needsSessionHeal` stood here until
    // 2026-09-27, with the SESSION_RESET_INIT, the tie-break and the heal they reported. A message
    // carrying the handshake header opens a new state beside the one held — `canOpenReceiving`,
    // the same as a first message (`decisions/sessions-renew-by-sending.md`).

    // MARK: - Delivery

    // `needsReceipt` was removed on 2026-08-02. It existed only to send the plaintext stream
    // receipt, whose `recipient_user_id` handed the server the sender↔recipient link that
    // sealed sender withholds. Receipts are now E2E-only and sent from `MessageRouter`
    // directly — see `sendDeliveryReceipt` there for the rule about when one is truthful.

    /// An E2E-encrypted delivery receipt was decrypted — `messageIds` are confirmed delivered.
    func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String])

    // MARK: - Contact metadata

    /// The contact's stored username looks like a UUID placeholder; a fresh bundle fetch is needed.
    func messageRouter(_ router: MessageRouter, needsUsernameUpdate peer: PeerAddress)
}
