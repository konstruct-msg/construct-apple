//
//  MessageRouter+ControlFrames.swift
//  Construct Messenger
//
//  MessageRouter: carrying out the control frames the core names for a message.
//

import Foundation
import CoreData
import SwiftProtobuf

@MainActor
extension MessageRouter {
    /// The control frames in `actions`, as `(contentType, body)` — what the core named after
    /// reading byte 5 of the KNST frame (core 0.30).
    static func controlFrames(in actions: [CfeAction]) -> [(contentType: UInt8, body: Data)] {
        actions.compactMap { action in
            if case .controlFrameDecrypted(_, _, let contentType, let body) = action { return (contentType, body) }
            return nil
        }
    }

    /// Carry out the control frames the core named for one message from `otherUserId`, and
    /// record it processed.
    ///
    /// `otherUserId` is an **account**: the action names the peer by device, because that is what
    /// the core keeps the session under, and every handler below files by account — the receipt,
    /// the card's intake key and address, the profile. A blocked contact's frames are dropped,
    /// as its messages are (`SECURITY[block_drop]` on the body path): the ratchet has advanced,
    /// nothing is applied.
    func handleControlFrames(
        in actions: [CfeAction],
        messageId: String,
        from otherUserId: String,
        in context: NSManagedObjectContext
    ) {
        defer { PersistentACKStore.shared.markProcessed(messageId, senderId: otherUserId) }
        if BlockedContacts.isBlocked(otherUserId) {
            Log.info("SECURITY[block_drop]: suppressed control frame \(messageId.prefix(8))… from blocked \(otherUserId.prefix(8))…", category: "MessageRouter")
            return
        }
        for frame in Self.controlFrames(in: actions) {
            handleControlFrame(contentType: frame.contentType, body: frame.body, messageId: messageId, from: otherUserId, in: context)
        }
    }

    private func handleControlFrame(
        contentType: UInt8,
        body: Data,
        messageId: String,
        from otherUserId: String,
        in context: NSManagedObjectContext
    ) {
        switch ContentTypeRouting.framedSideChannel(for: contentType) {
        case .deliveryReceipt:
            handleIncomingE2EDeliveryReceipt(body, messageId: messageId, from: otherUserId, in: context)
        case .contactCard:
            // The peer's card: the intake key their account accepts, so our envelopes to them
            // carry a tag instead of buying a Privacy Pass token, and their account address.
            // Filed by ACCOUNT: `sealedTag(forRecipient:)` looks the key up by account, and the
            // tag is derived over the recipient's account id — a key filed under a device id
            // would never be found, and a missing credential is a token spent, not an error.
            if let card = ContactCardPayload.read(body) {
                // Our own account's card comes only inside SENDER_SYNC, opened by a session with
                // one of our devices (`routeOpenedSenderSync`). One that reaches this path under
                // our own id is filed nowhere: as a contact's key it would be a key for writing
                // to ourselves, and as our own it would skip the own-device check.
                if let key = card.intakeKey, otherUserId.lowercased() != AuthSessionManager.shared.currentUserId?.lowercased() {
                    IntakeCredentialService.shared.recordPeerIntakeKey(
                        IntakeKeyState(generation: card.intakeGeneration, key: key), from: otherUserId
                    )
                }
                if let address = card.accountAddress {
                    Self.pinCardAddress(address, of: otherUserId)
                }
            } else {
                Log.error("Contact card from \(otherUserId.prefix(8))… did not decode", category: "MessageRouter")
            }
        case .profile:
            // Applied only if newer than the one held — the version makes a resend or a
            // reordered queue harmless.
            if let profile = ProfileShare.read(body) {
                ProfileSharingManager.shared.apply(profile, from: otherUserId)
            } else {
                Log.error("Profile from \(otherUserId.prefix(8))… did not decode", category: "MessageRouter")
            }
        case .readSync:
            // Read markers travel only between our own devices (the SENDER_SYNC path). One from a
            // contact would clear our unread counts at its word; the rule drops it.
            if let myUserId = AuthSessionManager.shared.currentUserId {
                applyReadMarkers(body, myUserId: myUserId, fromOwnAccount: false)
            }
            Log.error("SECURITY[read_sync_from_contact]: read markers from \(otherUserId.prefix(8))… dropped", category: "MessageRouter")
        case .callSignal:
            // The core hands a call signal over as `callSignalDecrypted`, never as a control frame.
            Log.error("Call signal from \(otherUserId.prefix(8))… arrived as a control frame — dropped", category: "MessageRouter")
        case nil:
            switch contentType {
            case WireMessageKind.heartbeatContentType:
                // A liveness probe: decrypting it exercised the ratchet, which was the point.
                Log.debug("Heartbeat received from \(otherUserId.prefix(8))… — session healthy", category: "MessageRouter")
            case 25, 26:
                // Ping / ready from a build before 2026-09-27: they closed a confirm window that
                // no longer exists.
                Log.info("Session control ct=\(contentType) from \(otherUserId.prefix(8))… discarded — nothing waits for it", category: "MessageRouter")
            default:
                Log.error("Control frame ct=\(contentType) from \(otherUserId.prefix(8))… has no handler — dropped", category: "MessageRouter")
            }
        }
    }

    /// A contact's address from their card, pinned by `AccountAddressPin`. Only onto a row that
    /// exists: a sender must not be able to put a contact in our store by sending to us.
    @MainActor
    private static func pinCardAddress(_ address: Data, of accountId: String) {
        AccountAddress.pin(address, contactId: accountId, source: .card)
    }
}
