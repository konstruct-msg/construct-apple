//
//  ConstructMessengerApp.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

@main
struct Construct_MessengerApp: App {
    // IMPORTANT: AppDelegate for background tasks registration
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    static let persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ConstructMessenger")

        // Enable automatic lightweight migration for Core Data model changes
        if let description = container.persistentStoreDescriptions.first {
            description.shouldInferMappingModelAutomatically = true
            description.shouldMigrateStoreAutomatically = true
        }

        // Load persistent stores asynchronously to avoid blocking app launch.
        container.loadPersistentStores { _, error in
            if let error = error {
                print("❌ Failed to load persistent stores: \(error)")
            } else {
                print("✅ Persistent stores loaded successfully")
            }
        }

        return container
    }()

    @StateObject private var authViewModel = AuthViewModel(context: Construct_MessengerApp.persistentContainer.viewContext)
    @State private var securityViewModel = SecurityViewModel()

    var body: some Scene {
        WindowGroup {
            SecurityGateView {
                ContentView()
                    .environment(\.managedObjectContext, Construct_MessengerApp.persistentContainer.viewContext)
                    .environmentObject(authViewModel)
                    .environmentObject(appDelegate.deepLinkHandler)
            }
            .environment(securityViewModel)
        }
    }
}
