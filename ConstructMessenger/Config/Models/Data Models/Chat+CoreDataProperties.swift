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
