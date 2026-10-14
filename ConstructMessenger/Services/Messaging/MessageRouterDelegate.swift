//
//  MessageRouterDelegate.swift
//  Construct Messenger
//
//  Typed event protocol replacing the 10 anonymous closure properties that
//  MessageRouter previously exposed. SessionCoordinator is the canonical conformer.
//

import Foundation
import CoreData

/// Receives session and delivery events emitted by `MessageRouter` during
/// incoming message processing. All methods are called on `@MainActor`.
///
/// Every peer is named by `PeerAddress`, never by a bare id. The events on this protocol come
/// from two sources in two identity spaces — the envelope names an account, a Rust orchestrator
/// action names a device — and while both were `String` under the label `userId` the conformer
/// had no way to tell which it had been handed. It did not: the teardown request of the time
/// reached a bundle fetch that asks the server for an *account*, with a device id in it, on
/// every path the core originated. See `PeerAddress` for the log of that failure.
@MainActor
protocol MessageRouterDelegate: AnyObject {

    // MARK: - Session control

    // `needsEndSession`, `coreGrantedEndSession`, `receivedEndSession` and `isEndSessionStale`
    // stood here until 2026-09-27, with END_SESSION. A message nothing reads is answered by the
    // core with a decryption error to its writer, and one arriving is answered by the core too
    // (`receivedDecryptionError`) — there is no teardown to ask about, grant, date or suppress
    // (`decisions/sessions-renew-by-sending.md`, variant B).

    /// The peer could not read something we sent it: a DECRYPTION_ERROR (content type 28).
    /// `peer.device` is the device its sender certificate names — the one whose record the error
    /// is about — and `payload` the box the peer's core sealed to our identity key, or, when
    /// `opened`, the error itself out of a session envelope. The conformer hands them to the
    /// core, which decides everything.
    func messageRouter(_ router: MessageRouter, receivedDecryptionError peer: PeerAddress, payload: Data, opened: Bool)

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
