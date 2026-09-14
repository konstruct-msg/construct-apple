//
//  Reaction+CoreDataProperties.swift
//  Construct Messenger
//
//  One row per (target message, reactor). Never a transcript Message.
//  See MESSAGE_REACTIONS_SPEC / ReactionStore.
//

import Foundation
import CoreData

extension Reaction {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Reaction> {
        NSFetchRequest<Reaction>(entityName: "Reaction")
    }

    @NSManaged public var targetMessageId: String
    @NSManaged public var reactorUserId: String
    @NSManaged public var emoji: String
    @NSManaged public var timestampMs: Int64
    @NSManaged public var receivedAt: Date?
}

extension Reaction: Identifiable {}
