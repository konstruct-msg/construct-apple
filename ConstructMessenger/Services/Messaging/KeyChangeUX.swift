//
//  KeyChangeUX.swift
//  Construct Messenger
//
//  Surfaces identity-key change as a first-class trust event (thread 5.4).
//

import Foundation
import CoreData

/// Coordinates key-change prominence: in-chat banner (ChatView) + global toast when
/// the affected chat is not open.
@MainActor
enum KeyChangeUX {

    /// Contact currently open in ChatView — suppresses global toast for that peer.
    private(set) static var activeChatContactId: String?

    static func setActiveChatContact(_ userId: String?) {
        activeChatContactId = userId
    }

    // MARK: - Notifications

    /// Call after `ktStatus` is set to `.keyChanged` / `.failed` and Core Data is saved.
    static func notifyKeyChange(userId: String, displayName: String?) {
        guard !userId.isEmpty else { return }
        // In-chat banner handles the open conversation.
        if activeChatContactId == userId { return }

        let name = resolvedName(userId: userId, displayName: displayName)
        let message = String(
            format: NSLocalizedString("key_change_toast_fmt", comment: ""),
            name
        )
        ErrorRouter.shared.presentNotice(
            message,
            actionTitle: NSLocalizedString("key_change_toast_open", comment: ""),
            autoDismissAfter: 10
        ) {
            // Open the chat so the full banner is available.
            NotificationCenter.default.post(
                name: .openChatForKeyChange,
                object: nil,
                userInfo: ["userId": userId]
            )
        }
    }

    // MARK: - Acknowledge

    /// User accepts the new identity key after re-verification (or risk acceptance).
    /// Clears `.keyChanged` / `.failed` → `.verified`. The key bytes were already updated
    /// when the change was detected (TOFU re-pin).
    @discardableResult
    static func acknowledgeKeyChange(
        userId: String,
        context: NSManagedObjectContext
    ) -> Bool {
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", userId)
        fetch.fetchLimit = 1
        guard let user = try? context.fetch(fetch).first else { return false }
        guard user.ktStatus == .keyChanged || user.ktStatus == .failed else { return false }

        user.ktStatus = .verified
        do {
            try context.save()
            Log.info(
                "Key change acknowledged for \(userId.prefix(8))… → verified",
                category: "KeyChangeUX"
            )
            NotificationCenter.default.post(
                name: .contactKeyChangeAcknowledged,
                object: nil,
                userInfo: ["userId": userId]
            )
            return true
        } catch {
            Log.error(
                "Failed to acknowledge key change for \(userId.prefix(8))…: \(error)",
                category: "KeyChangeUX"
            )
            return false
        }
    }

    /// Crypto device id for Safety Numbers: `SHA256(identity_public)[0..16]` hex.
    static func safetyDeviceId(for user: User) -> String? {
        guard let key = user.knownIdentityKey, !key.isEmpty else { return nil }
        return deriveDeviceId(identityPublicKey: [UInt8](key))
    }

    // MARK: - Helpers

    private static func resolvedName(userId: String, displayName: String?) -> String {
        if let displayName, !displayName.isEmpty, UUID(uuidString: displayName) == nil {
            return displayName
        }
        return DisplayNameGenerator.generate(from: userId)
    }
}

extension Notification.Name {
    /// User tapped "Open" on a global key-change toast — open chat with `userId`.
    static let openChatForKeyChange = Notification.Name("construct.openChatForKeyChange")
    /// User acknowledged a key change (banner Accept).
    static let contactKeyChangeAcknowledged = Notification.Name("construct.contactKeyChangeAcknowledged")
}
