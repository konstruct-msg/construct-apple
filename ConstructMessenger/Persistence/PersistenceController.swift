//
//  PersistenceController.swift
//  Construct Messenger
//
//  Session persistence support
//

import CoreData

/// Simple wrapper for accessing Core Data persistent container
struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    private init() {
        self.container = Construct_MessengerApp.persistentContainer
    }
    
    /// Check if Core Data is ready to use
    var isReady: Bool {
        return container.viewContext.persistentStoreCoordinator != nil
    }
    
    /// Get the view context if Core Data is ready, otherwise nil
    var safeViewContext: NSManagedObjectContext? {
        guard isReady else { return nil }
        return container.viewContext
    }
}
