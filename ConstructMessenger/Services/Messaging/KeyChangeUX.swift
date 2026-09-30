//
//  KeyChangeUX.swift
//  Construct Messenger
//
//  Surfaces a contact's security event as a first-class trust event (thread 5.4).
//

import Foundation
import CoreData

/// Coordinates the prominence of a security event about a contact: in-chat banner (ChatView) +
/// global toast when the affected chat is not open. The events are `SecurityNotice`s.
@MainActor
enum KeyChangeUX {

    /// Contact currently open in ChatView — suppresses global toast for that peer.
    private(set) static var activeChatContactId: String?

    static func setActiveChatContact(_ userId: String?) {
        activeChatContactId = userId
    }

    // MARK: - Raise

    /// Record `notice` on the contact and tell the user — the banner in their chat until
    /// acknowledged, and a notice here unless that chat is open.
    ///
    /// Our own account is never the subject: a row for us is residue (`SelfAddressedResidue`). No row means no contact to warn about — the
    /// event exists to protect a conversation.
    @discardableResult
    static func raise(_ notice: SecurityNotice, userId: String, context: NSManagedObjectContext) -> Bool {
        guard !userId.isEmpty else { return false }
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", userId)
        fetch.fetchLimit = 1
        guard let user = try? context.fetch(fetch).first, raise(notice, on: user) else { return false }
        do {
            try context.save()
        } catch {
            Log.error("SECURITY_NOTICE[\(notice)]: not saved for \(userId.prefix(8))…: \(error)", category: "KeyChangeUX")
        }
        return true
    }

    /// The same, on a row the caller holds and saves.
    @discardableResult
    static func raise(_ notice: SecurityNotice, on user: User) -> Bool {
        let userId = user.id
        guard notice != .none, !userId.isEmpty, !SessionAddressing.isOurOwnAccount(userId) else { return false }
        user.securityNotice = notice
        Log.error("SECURITY_NOTICE[\(notice)]: \(userId.prefix(8))…", category: "KeyChangeUX")
        NotificationCenter.default.post(name: .contactKeyChanged, object: nil, userInfo: ["userId": userId])
        announce(notice, userId: userId, displayName: user.resolvedDisplayName)
        return true
    }

    /// The notice outside the chat. The open chat shows its banner instead.
    private static func announce(_ notice: SecurityNotice, userId: String, displayName: String?) {
        if activeChatContactId == userId { return }
        let format: String
        switch notice {
        case .none: return
        case .addressChanged: format = "address_change_toast_fmt"
        }
        ErrorRouter.shared.presentNotice(
            String(format: NSLocalizedString(format, comment: ""), resolvedName(userId: userId, displayName: displayName)),
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

    /// The user has looked: the pending event is cleared, and a failed proof is accepted as a
    /// risk (`.failed` → `.verified`) — the next fetch that fails raises it again.
    @discardableResult
    static func acknowledgeKeyChange(
        userId: String,
        context: NSManagedObjectContext
    ) -> Bool {
        let fetch = User.fetchRequest()
        fetch.predicate = NSPredicate(format: "id == %@", userId)
        fetch.fetchLimit = 1
        guard let user = try? context.fetch(fetch).first, user.trustAlert != nil else { return false }

        user.securityNotice = .none
        if user.ktStatus == .failed { user.ktStatus = .verified }
        do {
            try context.save()
            Log.info("Security notice acknowledged for \(userId.prefix(8))…", category: "KeyChangeUX")
            NotificationCenter.default.post(
                name: .contactKeyChangeAcknowledged,
                object: nil,
                userInfo: ["userId": userId]
            )
            return true
        } catch {
            Log.error(
                "Failed to acknowledge security notice for \(userId.prefix(8))…: \(error)",
                category: "KeyChangeUX"
            )
            return false
        }
    }

    /// The contact's devices to compare Safety Numbers with — every one of them, since a
    /// substituted key is a device of its own. Comparing them is the only check on a device the
    /// server added, until device sets are cross-signed
    /// (`decisions/new-device-alarm-waits-for-cross-signing.md`).
    static func safetyDeviceIds(for user: User, context: NSManagedObjectContext) -> [String] {
        SessionAddressing.deviceIds(ofPeer: user.id)
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
