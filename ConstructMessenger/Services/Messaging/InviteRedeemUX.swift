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
    static func presentPostRedeemSafety(for contactInfo: ContactInfo) {
        let name = displayLabel(for: contactInfo)
        let message = String(
            format: NSLocalizedString("invite_redeem_safety_message_fmt", comment: ""),
            name
        )
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

    private static func displayLabel(for info: ContactInfo) -> String {
        let trimmed = info.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != info.userId, UUID(uuidString: trimmed) == nil {
            return "@\(trimmed)"
        }
        return DisplayNameGenerator.generate(from: info.userId)
    }
}
