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
@MainActor
protocol MessageRouterDelegate: AnyObject {

    // MARK: - Session control

    /// The Rust orchestrator detected a session divergence and wants us to send END_SESSION.
    func messageRouter(_ router: MessageRouter, needsEndSession userId: String)

    /// An END_SESSION message was successfully received and the session archived.
    func messageRouter(_ router: MessageRouter, receivedEndSession userId: String, timestamp: UInt64)

    /// Return `true` when an END_SESSION from `userId` carrying `timestamp` is stale
    /// (pre-dates the currently established session) and should be silently discarded.
    func messageRouter(_ router: MessageRouter, isEndSessionStale userId: String, timestamp: UInt64) -> Bool

    // MARK: - Session initialisation

    /// No DR session exists yet — the caller must fetch the sender's public-key bundle
    /// and call `initReceivingSession`, then replay `message`.
    func messageRouter(_ router: MessageRouter, needsPublicKeyBundle userId: String, for message: ChatMessage)

    /// A tie-break was resolved in our favour — we are the INITIATOR.
    func messageRouter(_ router: MessageRouter, didWinTieBreak userId: String)

    // MARK: - Session healing

    /// Session decrypt failed with `messageNumber == 0` — healing should be attempted.
    func messageRouter(_ router: MessageRouter, needsSessionHeal userId: String, failedMessage: ChatMessage)

    // MARK: - Delivery

    /// Stream cursor ACK or server receipt should be sent for `messageIds` to `userId`.
    func messageRouter(
        _ router: MessageRouter,
        needsReceipt messageIds: [String],
        to userId: String,
        status: Shared_Proto_Signaling_V1_ReceiptStatus
    )

    /// An E2E-encrypted delivery receipt was decrypted — `messageIds` are confirmed delivered.
    func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String])

    // MARK: - Contact metadata

    /// The contact's stored username looks like a UUID placeholder; a fresh bundle fetch is needed.
    func messageRouter(_ router: MessageRouter, needsUsernameUpdate userId: String)
}
