//
//  Chat+CoreDataProperties.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData

extension Chat {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Chat> {
        return NSFetchRequest<Chat>(entityName: "Chat")
    }

    @NSManaged public var id: String
    @NSManaged public var lastMessageText: String?
    @NSManaged public var lastMessageTime: Date?
    @NSManaged public var sessionId: String?
    @NSManaged public var isPinned: Bool
    @NSManaged public var isMuted: Bool
    @NSManaged public var unreadCount: Int16
    @NSManaged public var otherUser: User?
    @NSManaged public var messages: NSSet?
}

// MARK: Generated accessors for messages
extension Chat {
    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: Message)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: Message)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)
}

extension Chat: Identifiable {

}

// MARK: - Conversation Preview

extension Chat {
    /// Advance the chat-list preview to `text` / `timestamp`.
    ///
    /// **The preview must never move backwards.** Messages do not arrive in timestamp order:
    /// a peer message that sat in the server's offline queue is stored with its *original*
    /// timestamp long after newer local sends, and background fetch commits whole batches at
    /// once. Every writer used to assign `lastMessageText` / `lastMessageTime` directly, so one
    /// late-delivered older message clobbered the preview — the row then showed the peer's stale
    /// message while the transcript ended with much newer outgoing ones, and it stayed that way
    /// until the next local send happened to be newer.
    ///
    /// `>=` rather than `>`: outgoing timestamps are truncated to whole seconds
    /// (`UInt64(Date().timeIntervalSince1970)`), so a strict comparison silently drops a message
    /// sent in the same second as the current preview.
    ///
    /// - Parameter force: bypass the ordering check. Only for recomputing the preview from the
    ///   messages that remain (deletion / clear), which legitimately moves it backwards.
    func applyPreview(text: String, timestamp: Date, force: Bool = false) {
        if !force, let current = lastMessageTime, timestamp < current {
            // Ordinary out-of-order delivery lands here (debug). A large gap means
            // `lastMessageTime` is ahead of real traffic (future freeze / missed writer)
            // and will keep the list row stuck until reconcile or wall-clock catch-up.
            let lag = Int(current.timeIntervalSince(timestamp))
            if lag >= 300 {
                Log.info(
                    "Preview not advanced for \(id.prefix(8))… — incoming ts is \(lag)s older than current preview (possible freeze)",
                    category: "Chat"
                )
            } else {
                Log.debug(
                    "Preview not advanced for \(id.prefix(8))… — incoming ts is \(lag)s older than the current preview",
                    category: "Chat"
                )
            }
            return
        }
        lastMessageText = Chat.formatPreviewText(text)
        lastMessageTime = timestamp
    }

    /// Clear the preview — no messages left in the conversation.
    func clearPreview() {
        lastMessageText = nil
        lastMessageTime = nil
    }

    /// Align denormalized list preview with the newest visible transcript message.
    ///
    /// Call when the list appears / after a context save. Covers three stuck-row classes:
    /// 1. SwiftUI observation gap (Core Data already advanced, row never repainted — still
    ///    cheap no-op when already in sync).
    /// 2. Missed `applyPreview` on a write path (message exists, stamp stale).
    /// 3. Future-timestamp freeze (`lastMessageTime` ahead of every real message).
    ///
    /// Uses the same `contentTypeRaw == 0` filter as `ChatMessageStore`'s FRC so control
    /// rows never become the list subtitle. Returns `true` when fields changed.
    @discardableResult
    func reconcilePreviewFromTranscript(in context: NSManagedObjectContext? = nil) -> Bool {
        let ctx = context ?? managedObjectContext
        guard let ctx else { return false }

        let req = Message.fetchRequest()
        req.predicate = NSPredicate(format: "chat == %@ AND contentTypeRaw == 0", self)
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        // A few candidates so a leaked service/control row at the tip does not pin us.
        req.fetchLimit = 8

        let rows = (try? ctx.fetch(req)) ?? []
        let newest = rows.first { msg in
            // Cheap type check first; displayText decrypt only for tip candidates.
            if msg.contentType.isEphemeral { return false }
            if msg.isServiceArtifact || msg.isControlArtifact { return false }
            return true
        }

        guard let newest else {
            if lastMessageText != nil || lastMessageTime != nil {
                clearPreview()
                return true
            }
            return false
        }

        let text = Chat.formatPreviewText(newest.displayText)
        if let current = lastMessageTime,
           abs(current.timeIntervalSince(newest.timestamp)) < 0.5,
           (lastMessageText ?? "") == text {
            return false
        }

        applyPreview(text: newest.displayText, timestamp: newest.timestamp, force: true)
        Log.debug(
            "Preview reconciled for \(id.prefix(8))… → '\(text.prefix(40))' ts=\(newest.timestamp)",
            category: "Chat"
        )
        return true
    }
}

// MARK: - Message Preview Helpers
extension Chat {
    /// Format message content for chat list preview
    /// Handles media messages, profile shares, and system messages
    static func formatPreviewText(_ content: String?) -> String {
        guard let content = content else { return "" }
        
        // Never show session-handshake control signals as chat preview text.
        if content.hasPrefix("__session_ready") || content.hasPrefix("session_ready_") ||
           content.hasPrefix("__session_ping") || content.hasPrefix("__END_SESSION") {
            return ""
        }
        
        // Check if it's JSON (media or profile message)
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            
            switch type {
            case "file":
                let files = json["files"] as? [[String: Any]] ?? []
                if files.count == 1, let name = files.first?["filename"] as? String {
                    return name
                } else if files.count > 1 {
                    return "\(files.count) " + NSLocalizedString("files", comment: "")
                }
                return "File"

            case "media":
                // Media message
                let caption = json["caption"] as? String ?? ""
                if caption.isEmpty {
                    return "Photo"
                } else {
                    return caption
                }
                
            case "profile":
                // Profile share message
                if let displayName = json["displayName"] as? String {
                    return "Shared profile: \(displayName)"
                } else {
                    return "Shared profile"
                }

            case "voice":
                return NSLocalizedString("voice_message", comment: "")

            default:
                // Unknown JSON type - show first 50 chars
                return String(content.prefix(50))
            }
        }
        
        // Regular text message — strip markdown markers for plain-text preview
        return String.strippingMarkdown(content)
    }
}
