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
