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

    /// The Rust orchestrator detected a session divergence and wants us to send END_SESSION.
    func messageRouter(_ router: MessageRouter, needsEndSession peer: PeerAddress)

    /// An END_SESSION message was successfully received and the session archived.
    func messageRouter(_ router: MessageRouter, receivedEndSession peer: PeerAddress, timestamp: UInt64)

    /// Return `true` when an END_SESSION from `peer` carrying `timestamp` is stale
    /// (pre-dates the currently established session) and should be silently discarded.
    func messageRouter(_ router: MessageRouter, isEndSessionStale peer: PeerAddress, timestamp: UInt64) -> Bool

    /// Return `true` when a SESSION_RESET_INIT from `peer` is *superseded* — either we have
    /// already applied this exact init (identified by `initEphemeral`, its X3DH ephemeral public
    /// key), or it pre-dates the current session's establishment (a server backlog replay). Such an
    /// init is coalesced, ACK-only. A live init returns `false` and MUST be applied, even while a
    /// session is active, or the RESPONDER strands on a stale ratchet.
    ///
    /// `initEphemeral` is what makes a redelivery recognisable at all: two copies of one init carry
    /// the same key, and they carry the same `timestamp` too — which is why the timestamp alone
    /// could not tell them apart. See `SessionReducer.isResetInitSuperseded`.
    func messageRouter(
        _ router: MessageRouter,
        isResetInitSuperseded peer: PeerAddress,
        timestamp: UInt64,
        initEphemeral: Data
    ) -> Bool

    // MARK: - Session initialisation

    /// No DR session exists yet — the caller must fetch the sender's public-key bundle
    /// and call `initReceivingSession`, then replay `message`.
    func messageRouter(_ router: MessageRouter, needsPublicKeyBundle peer: PeerAddress, for message: ChatMessage)

    /// A tie-break was resolved in our favour — we are the INITIATOR.
    func messageRouter(_ router: MessageRouter, didWinTieBreak peer: PeerAddress)

    // MARK: - Session healing

    /// Session decrypt failed with `messageNumber == 0` — healing should be attempted.
    func messageRouter(_ router: MessageRouter, needsSessionHeal peer: PeerAddress, failedMessage: ChatMessage)

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
