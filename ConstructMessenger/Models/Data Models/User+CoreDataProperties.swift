//
//  User+CoreDataProperties.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData

extension User {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<User> {
        return NSFetchRequest<User>(entityName: "User")
    }

    @NSManaged public var id: String
    @NSManaged public var username: String
    @NSManaged public var displayName: String
    @NSManaged public var publicKey: String?
    @NSManaged public var avatarData: Data?
    @NSManaged public var isSharingWithMe: Bool
    @NSManaged public var isBlocked: Bool
    @NSManaged public var sharedWithMeAt: Date?
    @NSManaged public var amISharingWith: Bool
    @NSManaged public var chats: NSSet?
}

// MARK: Generated accessors for chats
extension User {
    @objc(addChatsObject:)
    @NSManaged public func addToChats(_ value: Chat)

    @objc(removeChatsObject:)
    @NSManaged public func removeFromChats(_ value: Chat)

    @objc(addChats:)
    @NSManaged public func addToChats(_ values: NSSet)

    @objc(removeChats:)
    @NSManaged public func removeFromChats(_ values: NSSet)
}

extension User: Identifiable {

}
