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
}
