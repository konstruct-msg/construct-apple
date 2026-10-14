//
//  ServerMessageId+CoreData.swift
//  Construct Messenger
//
//  The server's id of a sealed copy we sent → our message id (model 13). Read and written only
//  through `ServerMessageIdStore`; see `CoreDataServerMessageIdStore`.
//

import CoreData
import Foundation

@objc(ServerMessageId)
public class ServerMessageId: NSManagedObject {}

extension ServerMessageId {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ServerMessageId> {
        NSFetchRequest<ServerMessageId>(entityName: "ServerMessageId")
    }

    /// Lowercase.
    @NSManaged public var serverId: String
    /// Our message id, lowercase.
    @NSManaged public var localId: String
    @NSManaged public var recordedAt: Date
}
