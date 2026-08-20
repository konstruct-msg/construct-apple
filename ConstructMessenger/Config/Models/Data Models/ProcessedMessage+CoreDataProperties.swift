//
//  ProcessedMessage+CoreDataProperties.swift
//  Construct Messenger

import Foundation
import CoreData

extension ProcessedMessage {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ProcessedMessage> {
        return NSFetchRequest<ProcessedMessage>(entityName: "ProcessedMessage")
    }

    @NSManaged public var messageId: String
    @NSManaged public var senderId: String
    @NSManaged public var processedAt: Date
}

extension ProcessedMessage: Identifiable {}
