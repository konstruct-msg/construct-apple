//
//  HealingMessage+CoreDataProperties.swift
//  Construct Messenger

import Foundation
import CoreData

extension HealingMessage {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<HealingMessage> {
        return NSFetchRequest<HealingMessage>(entityName: "HealingMessage")
    }

    @NSManaged public var messageId: String
    @NSManaged public var senderId: String
    @NSManaged public var receivedAt: Date
    @NSManaged public var messageData: Data
    @NSManaged public var healAttempts: Int32
    @NSManaged public var lastAttemptAt: Date?
}

extension HealingMessage: Identifiable {}
