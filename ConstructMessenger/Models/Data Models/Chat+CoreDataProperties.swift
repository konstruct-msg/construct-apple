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
