//
//  CTCallRecord+CoreDataProperties.swift
//  Construct Messenger

import Foundation
import CoreData

extension CTCallRecord {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CTCallRecord> {
        return NSFetchRequest<CTCallRecord>(entityName: "CallRecord")
    }

    @NSManaged public var id: String
    @NSManaged public var peerUserId: String
    @NSManaged public var peerName: String
    @NSManaged public var directionRaw: Int16
    @NSManaged public var statusRaw: Int16
    @NSManaged public var startedAt: Date?
    @NSManaged public var endedAt: Date?
    @NSManaged public var durationSeconds: Int32
}

extension CTCallRecord: Identifiable {}
