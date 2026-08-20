//
//  InviteRedeemUX.swift
//  Construct Messenger
//
//  Post-redeem safety toast + inviter notice (invite improvement complementary UX).
//

import Foundation
import CoreData

/// Lightweight UX helpers after invite redeem / invite_accepted push.
@MainActor
enum InviteRedeemUX {

    /// Redeemer just added a contact via invite — offer a short Block window.
    /// Dismissing the toast keeps the contact (no-accept-tap model is intentional).
    ///
    /// The toast names nobody, on purpose. It used to read "Connected with %@. Not who you
    /// expected?", and the `%@` was always a generated pseudonym: both mint sites pass
    /// `username: nil` (metadata minimization), so the invite carries no name and the label
    /// fell through to `DisplayNameGenerator`. A device log from 2026-08-17 shows the result —
    /// a correct pairing announced as "Connected with proud gryphon. Not who you expected?",
    /// with the real name arriving 31 seconds later in a profile message, long after the toast
    /// had gone.
    ///
    /// A safety prompt asking a question the reader cannot answer is worse than no prompt: it
    /// fires on every redeem, and the one control that does something — Block — hangs off it.
    /// So state what happened, keep Block, and leave identity to Safety Numbers, which is the
    /// surface built to be checked.
    static func presentPostRedeemSafety(for contactInfo: ContactInfo) {
        let message = NSLocalizedString("invite_redeem_safety_message", comment: "")
        let blockTitle = NSLocalizedString("invite_redeem_safety_block", comment: "")
        let peerId = contactInfo.userId

        ErrorRouter.shared.presentNotice(
            message,
            actionTitle: blockTitle,
            autoDismissAfter: InviteConfig.postRedeemSafetyToastSeconds
        ) {
            Task { await blockPeer(userId: peerId) }
        }
    }

    /// Inviter device: someone redeemed our invite (after local contact was created).
    static func presentInviterNotice(peerUserId: String) {
        let message = NSLocalizedString("invite_accepted_inviter_message", comment: "")
        ErrorRouter.shared.presentNotice(
            message,
            actionTitle: nil,
            autoDismissAfter: InviteConfig.postRedeemSafetyToastSeconds
        )
        Log.info(
            "Inviter notice: peer \(peerUserId.prefix(8))… connected via invite",
            category: "InviteRedeemUX"
        )
    }

    // MARK: - Block

    private static func blockPeer(userId: String) async {
        let context = PersistenceController.shared.container.viewContext
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", userId)
        fetch.fetchLimit = 1
        if let user = try? context.fetch(fetch).first {
            user.isBlocked = true
            try? context.save()
        }
        do {
            _ = try await UserServiceClient.shared.blockUser(userId: userId, reason: "invite_undo")
            Log.info("Post-redeem block applied for \(userId.prefix(8))…", category: "InviteRedeemUX")
        } catch {
            Log.error(
                "Post-redeem block server call failed for \(userId.prefix(8))…: \(error)",
                category: "InviteRedeemUX"
            )
            // Local isBlocked already gates messages/calls.
        }
    }

}
